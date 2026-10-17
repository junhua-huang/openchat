import Foundation
import Combine

struct BrowserRequest: Identifiable { let id = UUID(); let url: URL }

@MainActor
final class AuthManager: ObservableObject {
    @Published private var vault: CredentialVault?
    @Published private(set) var isBusy = false
    @Published var browser: BrowserRequest?
    @Published var errorText: String?
    @Published var showPlanNotice = false
    @Published private(set) var stage = "尚未连接"
    private let callback = LoopbackServer()
    private var pending: Attempt?
    private var attemptID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<String, Error>] = [:]

    private struct Attempt {
        let id: UUID
        let state: String
        let nonce: String
        let verifier: String
        let redirect: URL
        let metadata: OpenIDMetadata
        let account: Account?
    }

    var isReady: Bool { vault != nil }
    var accounts: [Account] { vault?.accounts ?? [] }
    var activeAccount: Account? { accounts.first { $0.id == vault?.activeID && $0.tokens != nil } }
    var activeID: UUID? { activeAccount?.id }

    init() {
        do {
            let saved = try SecureStore.load() ?? CredentialVault(hostID: "urn:uuid:" + UUID().uuidString.lowercased())
            try SecureStore.save(saved)
            vault = saved
            stage = saved.activeID == nil ? "尚未连接" : "已恢复本地连接"
        } catch { errorText = "无法读取登录状态，请解锁设备并重新打开 App。原有凭据没有被覆盖。" }
    }

    private func commit(_ next: CredentialVault) throws { try SecureStore.save(next); vault = next }

    func connect(accountID: UUID? = nil) async {
        guard !isBusy, let vault = vault else { return }
        let id = UUID()
        attemptID = id
        isBusy = true
        errorText = nil
        stage = "正在准备安全登录"
        do {
            let metadata = try await OpenIDMetadata.load()
            try Task.checkCancellation()
            guard attemptID == id else { return }
            let redirect = try await callback.start()
            guard attemptID == id else { callback.stop(); return }
            let account = accountID.flatMap { selected in vault.accounts.first { $0.id == selected } }
            let attempt = Attempt(id: id, state: try EncodingTools.random(), nonce: try EncodingTools.random(),
                                  verifier: try EncodingTools.random(), redirect: redirect, metadata: metadata, account: account)
            var params = ["client_id": account?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": vault.hostID,
                          "response_type": "code", "redirect_uri": redirect.absoluteString,
                          "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                          "resource": "https://api.openai.com/v1", "state": attempt.state, "nonce": attempt.nonce,
                          "code_challenge_method": "S256", "code_challenge": EncodingTools.challenge(attempt.verifier)]
            if account == nil { params["agent_name_hint"] = "OpenChat" }
            if let hint = account?.tokens?.idToken { params["id_token_hint"] = hint }
            if let email = account?.email { params["login_hint"] = email }
            var url = URLComponents(url: metadata.authorization_endpoint, resolvingAgainstBaseURL: false)!
            url.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let authorizationURL = url.url else { throw AppFailure.message("无法生成登录地址。") }
            pending = attempt
            callback.accept = { [weak self] url in self?.receiveCallback(url) ?? false }
            browser = BrowserRequest(url: authorizationURL)
            stage = "等待浏览器授权"
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
                guard let self = self, self.attemptID == id, self.pending != nil else { return }
                self.cancelSignIn()
                self.errorText = "登录等待超时。请重新连接；若一直无法返回，需要检查 iPhone 上的本地回调。"
            }
        } catch {
            guard attemptID == id else { return }
            cancelSignIn()
            errorText = error.localizedDescription
        }
    }

    func cancelSignIn() {
        guard pending != nil || browser == nil else { return }
        pending = nil
        attemptID = nil
        timeoutTask?.cancel()
        callback.stop()
        browser = nil
        isBusy = false
        stage = "连接已取消"
    }
    func browserDidDismiss() { if pending != nil { cancelSignIn() } }

    private func receiveCallback(_ url: URL) -> Bool {
        guard let attempt = pending, attempt.id == attemptID,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http", components.host == "127.0.0.1",
              components.port == attempt.redirect.port, components.path == "/auth/callback" else { return false }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return false }
        let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard params["state"] == attempt.state else { return false }
        // Consume exactly once; invalid/unrelated requests never consume a pending attempt.
        pending = nil
        timeoutTask?.cancel()
        browser = nil
        stage = "已收到设备本地回调"
        Task { await finish(attempt, params: params) }
        return true
    }

    private func finish(_ attempt: Attempt, params: [String: String]) async {
        defer {
            callback.stop()
            isBusy = false
            attemptID = nil
        }
        do {
            if let issuer = params["iss"], issuer != attempt.metadata.issuer { throw AppFailure.message("登录回调的发行者无效。") }
            if params["error"] != nil { throw AppFailure.message("没有完成授权。你可以重新连接，并选择是否允许使用 ChatGPT 套餐。") }
            guard let code = params["code"], !code.isEmpty, var next = vault else { throw AppFailure.message("登录回调不完整。") }
            let clientID: String
            if let existing = attempt.account {
                guard params["client_id"] == nil || params["client_id"] == existing.clientID else { throw AppFailure.message("回调中的账户注册与所选连接不一致。") }
                clientID = existing.clientID
            } else {
                guard let issued = params["client_id"], !issued.isEmpty, issued != "dynamic_agent_client" else {
                    throw AppFailure.message("没有收到正式的客户端编号，请重新连接。")
                }
                clientID = issued
            }
            let accountID: UUID
            if let match = next.accounts.first(where: { $0.clientID == clientID }) { accountID = match.id }
            else {
                accountID = UUID()
                next.accounts.append(Account(id: accountID, clientID: clientID, subject: "", email: nil, tokens: nil))
                // Retain the issued registration even if code exchange fails. Never trust identity yet.
                try commit(next)
            }
            stage = "正在交换授权并验证身份"
            let reply = try await tokenRequest(endpoint: attempt.metadata.token_endpoint,
                values: ["grant_type": "authorization_code", "client_id": clientID, "code": code,
                         "code_verifier": attempt.verifier, "redirect_uri": attempt.redirect.absoluteString,
                         "resource": "https://api.openai.com/v1"])
            guard let idToken = reply.id_token else { throw AppFailure.message("授权响应缺少身份令牌。") }
            let identity = try await IdentityVerifier.verify(idToken, clientID: clientID, nonce: attempt.nonce, metadata: attempt.metadata)
            guard var current = vault, let index = current.accounts.firstIndex(where: { $0.id == accountID }) else { throw CancellationError() }
            let original = current.accounts[index]
            guard original.subject.isEmpty || original.subject == identity.sub else { throw AppFailure.message("返回的身份与原连接不一致。") }
            let tokens = try Tokens(reply: reply)
            current.accounts[index] = Account(id: accountID, clientID: clientID, subject: identity.sub, email: identity.email, tokens: tokens)
            current.activeID = accountID
            try commit(current)
            stage = tokens.permitsInference ? "身份与套餐授权已验证" : "已登录，尚未授权套餐使用"
            if tokens.permitsInference {
                let noticeKey = "plan-notice-" + accountID.uuidString
                if !UserDefaults.standard.bool(forKey: noticeKey) {
                    UserDefaults.standard.set(true, forKey: noticeKey)
                    showPlanNotice = true
                }
            }
        } catch { stage = "连接未完成"; errorText = error.localizedDescription }
    }

    private func tokenRequest(endpoint: URL, values: [String: String]) async throws -> TokenReply {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = EncodingTools.form(values)
        let (data, response) = try await HTTP.session.data(for: request)
        try HTTP.check(response)
        return try JSONDecoder().decode(TokenReply.self, from: data)
    }

    func accessToken(for id: UUID) async throws -> String {
        guard let account = accounts.first(where: { $0.id == id }), let saved = account.tokens else {
            throw AppFailure.message("请先连接 ChatGPT。")
        }
        guard saved.permitsInference else { throw AppFailure.message("你已登录，但尚未允许此 App 使用 ChatGPT 套餐。请重新连接并授权。") }
        if saved.expiresAt > Date().addingTimeInterval(90) { return saved.access }
        if let inflight = refreshTasks[id] { return try await inflight.value }
        let task = Task { () async throws -> String in
            guard let refresh = saved.refresh else { throw AppFailure.message("登录已过期，请重新连接。") }
            let metadata = try await OpenIDMetadata.load()
            let reply = try await tokenRequest(endpoint: metadata.token_endpoint,
                values: ["grant_type": "refresh_token", "client_id": account.clientID,
                         "refresh_token": refresh, "resource": "https://api.openai.com/v1"])
            let updated = try Tokens(reply: reply, previous: saved)
            if let idToken = reply.id_token {
                let identity = try await IdentityVerifier.verify(idToken, clientID: account.clientID, nonce: nil, metadata: metadata)
                guard identity.sub == account.subject else { throw AppFailure.message("续期后的身份不一致，请重新连接。") }
            }
            try Task.checkCancellation()
            guard var next = vault, let index = next.accounts.firstIndex(where: { $0.id == id }),
                  next.accounts[index].tokens?.access == saved.access else { throw CancellationError() }
            next.accounts[index].tokens = updated
            try commit(next)
            guard updated.permitsInference else { throw AppFailure.message("套餐使用授权已失效，请重新连接。") }
            return updated.access
        }
        refreshTasks[id] = task
        defer { refreshTasks[id] = nil }
        return try await task.value
    }

    func select(_ id: UUID) {
        guard !isBusy, var next = vault, next.accounts.contains(where: { $0.id == id && $0.tokens != nil }) else { return }
        next.activeID = id
        do { try commit(next) } catch { errorText = error.localizedDescription }
    }

    func signOut() async {
        guard !isBusy, let account = activeAccount else { return }
        isBusy = true
        defer { isBusy = false }
        refreshTasks[account.id]?.cancel()
        var revoked = account.tokens?.refresh == nil
        if let refresh = account.tokens?.refresh {
            for attempt in 0..<3 {
                do {
                    let metadata = try await OpenIDMetadata.load()
                    guard let endpoint = metadata.revocation_endpoint else { break }
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 12
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    request.httpBody = EncodingTools.form(["token": refresh, "token_type_hint": "refresh_token", "client_id": account.clientID])
                    let (_, response) = try await HTTP.session.data(for: request)
                    if (response as? HTTPURLResponse)?.statusCode == 200 { revoked = true; break }
                    if let status = (response as? HTTPURLResponse)?.statusCode, status < 500 { break }
                } catch { }
                if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000) }
            }
        }
        guard var next = vault, let index = next.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        next.accounts[index].tokens = nil
        next.activeID = nil
        do {
            try commit(next)
            stage = "已退出，重新连接时会复用原注册"
            if !revoked { errorText = "已清除本机凭据，但未能确认远程会话撤销。你可以在 ChatGPT 设置中断开此 App。" }
        } catch { errorText = error.localizedDescription }
    }
}

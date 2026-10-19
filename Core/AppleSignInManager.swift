import AuthenticationServices
import Combine
import Foundation

@MainActor
final class AppleSignInManager: NSObject, ObservableObject {
    enum SessionState { case signedOut, checking, signedIn, unavailable }

    @Published private(set) var account: AppleAccount?
    @Published private(set) var sessionState = SessionState.signedOut
    @Published private(set) var isBusy = false
    @Published private(set) var storageReady = false
    @Published private(set) var notice: String?

    private let load: () throws -> AppleAccount?
    private let save: (AppleAccount) throws -> Void
    private let remove: () throws -> Void
    private let credentialState: (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState
    private let verify: (String, String) async throws -> Identity
    private var pending: AppleSignInAttempt?
    private var operationID: UUID?
    private var credentialCheckID: UUID?
    private var controller: ASAuthorizationController?
    private var anchor: ASPresentationAnchor?
    private var verificationTask: Task<Void, Never>?

    init(load: @escaping () throws -> AppleAccount? = AppleAccountStore.load,
         save: @escaping (AppleAccount) throws -> Void = AppleAccountStore.save,
         remove: @escaping () throws -> Void = AppleAccountStore.remove,
         credentialState: @escaping (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState = { userID in
             try await withCheckedThrowingContinuation { continuation in
                 ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, error in
                     if let error = error { continuation.resume(throwing: error) }
                     else { continuation.resume(returning: state) }
                 }
             }
         },
         verify: @escaping (String, String) async throws -> Identity = AppleSignInManager.verifyIdentity) {
        self.load = load; self.save = save; self.remove = remove
        self.credentialState = credentialState; self.verify = verify
        super.init()
        restore()
    }

    func restore() {
        guard !isBusy else { return }
        credentialCheckID = nil
        do {
            account = try load()
            storageReady = true
            sessionState = account == nil ? .signedOut : .checking
            notice = nil
        } catch {
            account = nil; storageReady = false; sessionState = .unavailable
            notice = "无法读取 Apple 登录资料，请解锁设备后重试。原有资料没有被覆盖。"
        }
    }

    func startSignIn(presentationAnchor: ASPresentationAnchor) {
        do {
            let attempt = try beginSignIn()
            anchor = presentationAnchor
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.state = attempt.state
            request.nonce = attempt.nonce
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        } catch { notice = error.localizedDescription }
    }

    // Separate from presentation so host-side checks can exercise the flow without
    // displaying Apple UI or contacting Apple's authorization service.
    func beginSignIn() throws -> AppleSignInAttempt {
        guard storageReady else { throw AppFailure.message("请先重试读取 Apple 登录资料。") }
        guard !isBusy else { throw AppFailure.message("正在完成 Apple 登录，请稍候。") }
        let attempt = AppleSignInAttempt(id: UUID(), state: try EncodingTools.random(), nonce: try EncodingTools.random())
        credentialCheckID = nil
        pending = attempt; operationID = attempt.id
        isBusy = true; notice = nil
        return attempt
    }

    func complete(_ result: AppleSignInResult, attemptID: UUID) async {
        guard let attempt = pending, attempt.id == attemptID, operationID == attemptID else { return }
        pending = nil // Consume once, before any suspension.
        defer { finishOperation(attemptID) }
        do {
            guard result.state == attempt.state, !result.userID.isEmpty, !result.identityToken.isEmpty else {
                throw AppFailure.message("Apple 登录响应不匹配，请重新登录。")
            }
            let identity = try await verify(result.identityToken, attempt.nonce)
            try Task.checkCancellation()
            guard operationID == attemptID else { return }
            guard identity.sub == result.userID else { throw AppFailure.message("Apple 返回的身份不一致，请重新登录。") }
            let updated = try AppleAccount.updated(userID: result.userID, fullName: result.fullName,
                                                   email: identity.email ?? result.email, previous: account)
            try save(updated)
            account = updated; sessionState = .signedIn
            notice = nil
        } catch {
            guard operationID == attemptID else { return }
            notice = error.localizedDescription
        }
    }

    func cancelSignIn(attemptID: UUID, error: Error? = nil) {
        guard operationID == attemptID else { return }
        finishOperation(attemptID)
        if let error = error {
            let nsError = error as NSError
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue { notice = nil }
            else { notice = "Apple 登录未完成。请检查网络和 Apple 账户后重试。" }
        }
    }

    func cancelCurrentSignIn() {
        guard let id = operationID else { return }
        let activeController = controller
        verificationTask?.cancel()
        cancelSignIn(attemptID: id)
        activeController?.cancel()
    }

    func refreshCredentialState() async {
        guard !isBusy, let saved = account else { return }
        let checkID = UUID()
        credentialCheckID = checkID
        sessionState = .checking
        do {
            let state = try await credentialState(saved.userID)
            guard credentialCheckID == checkID, account?.userID == saved.userID, !isBusy else { return }
            switch state {
            case .authorized: sessionState = .signedIn; notice = nil
            case .revoked, .notFound, .transferred:
                clearIdentity(notice: "Apple 登录已失效，请重新登录。")
            @unknown default:
                sessionState = .unavailable; notice = "暂时无法确认 Apple 登录状态，请重试。"
            }
        } catch {
            guard credentialCheckID == checkID, account?.userID == saved.userID, !isBusy else { return }
            // A temporary failure is not revocation. Preserve the saved identity.
            sessionState = .unavailable; notice = "暂时无法确认 Apple 登录状态，请检查网络后重试。"
        }
    }

    func signOut() { clearIdentity(notice: nil) }

    func credentialWasRevoked() {
        clearIdentity(notice: "Apple 授权发生变化，请重新登录。")
    }

    private func clearIdentity(notice: String?) {
        credentialCheckID = nil; operationID = nil; pending = nil
        verificationTask?.cancel(); verificationTask = nil
        controller?.cancel(); controller = nil; anchor = nil; isBusy = false
        // Invalidate in-memory identity even if Keychain is temporarily locked.
        account = nil; sessionState = .signedOut
        do { try remove(); self.notice = notice }
        catch { storageReady = false; self.notice = error.localizedDescription }
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        pending = nil; operationID = nil; controller = nil; anchor = nil
        verificationTask = nil; isBusy = false
        if sessionState == .checking, account != nil { sessionState = .unavailable }
    }

    nonisolated private static func verifyIdentity(_ token: String, nonce: String) async throws -> Identity {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            throw AppFailure.message("App 缺少 Apple 登录配置。")
        }
        let metadata = OpenIDMetadata(issuer: "https://appleid.apple.com",
            authorization_endpoint: URL(string: "https://appleid.apple.com/auth/authorize")!,
            token_endpoint: URL(string: "https://appleid.apple.com/auth/token")!,
            jwks_uri: URL(string: "https://appleid.apple.com/auth/keys")!, revocation_endpoint: nil)
        do {
            var request = URLRequest(url: metadata.jwks_uri)
            request.timeoutInterval = 15
            let (keys, response) = try await HTTP.session.data(for: request)
            try HTTP.check(response)
            return try IdentityVerifier.verify(token, clientID: bundleID, nonce: nonce, metadata: metadata, jwks: keys)
        } catch {
            throw AppFailure.message("无法验证 Apple 登录，请检查网络后重试。")
        }
    }
}

extension AppleSignInManager: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Retained from the actual button's window before starting the request.
        anchor ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard controller === self.controller, let attempt = pending else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
            cancelSignIn(attemptID: attempt.id, error: AppFailure.message("Apple 登录响应不完整。")); return
        }
        let fullName = credential.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
        let result = AppleSignInResult(userID: credential.user, state: credential.state, identityToken: token,
                                       fullName: fullName, email: credential.email)
        verificationTask = Task { await complete(result, attemptID: attempt.id) }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === self.controller, let id = operationID else { return }
        cancelSignIn(attemptID: id, error: error)
    }
}

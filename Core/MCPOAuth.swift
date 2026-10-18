import Foundation

/// Credentials belong to one MCP resource, never to the ChatGPT account.
struct MCPOAuthCredentials: Codable, Equatable {
    var resource: String
    var issuer: String
    var tokenEndpoint: String
    var clientID: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

struct MCPOAuthDiscovery {
    var resource: String
    var issuer: String
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL?
    var scope: String?
}

struct MCPOAuthAttempt {
    var discovery: MCPOAuthDiscovery
    var clientID: String
    var redirect: URL
    var state: String
    var verifier: String
    var authorizationURL: URL
}

@MainActor final class MCPOAuthClient {
    private let session: URLSession
    init(session: URLSession = BoundedHTTP.session) { self.session = session }
    static func canonical(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased()
        if c.path == "/" { c.path = "" }
        return c.string!
    }
    static func parameter(_ name: String, in header: String?) -> String? {
        guard let header = header, header.count < 16000,
              let regex = try? NSRegularExpression(pattern: "(?:^|[,\\s])" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(?:\"([^\"\\r\\n]*)\"|([^,\\s]+))", options: .caseInsensitive),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        for i in 1...2 { if let range = Range(match.range(at: i), in: header) { return String(header[range]) } }
        return nil
    }
    static func metadataURLs(issuer: URL) -> [URL] {
        var root = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        let path = root.path == "/" ? "" : root.path
        return ["/.well-known/oauth-authorization-server" + path, "/.well-known/openid-configuration" + path,
                path + "/.well-known/openid-configuration"].compactMap { value in root.path = value; return root.url }
    }
    private func json(_ url: URL) async throws -> [String: Any] {
        _ = try BoundedHTTP.endpoint(url.absoluteString)
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await BoundedHTTP.read(request, limit: 256_000, using: session)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppFailure.message("OAuth 服务元数据不是有效 JSON。") }
        return object
    }
    func discover(endpoint: String) async throws -> MCPOAuthDiscovery {
        let resourceURL = try BoundedHTTP.endpoint(endpoint)
        var probe = URLRequest(url: resourceURL); probe.httpMethod = "POST"; probe.timeoutInterval = 20
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "oauth-discovery", "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "OpenChat OAuth discovery", "version": "2.2.0"]]])
        // An unauthenticated initialize has no tool side effects. Never send a saved token during discovery.
        let (_, response) = try await BoundedHTTP.read(probe, limit: 256_000, using: session, acceptedStatus: 200..<500)
        let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate")
        var candidates: [URL] = []
        if let advertised = Self.parameter("resource_metadata", in: challenge) {
            candidates = [try BoundedHTTP.endpoint(advertised)]
        } else {
            var root = URLComponents(url: resourceURL, resolvingAgainstBaseURL: false)!
            let path = root.path == "/" ? "" : root.path
            root.path = "/.well-known/oauth-protected-resource" + path
            if let url = root.url { candidates.append(url) }
            root.path = "/.well-known/oauth-protected-resource"
            if let url = root.url, !candidates.contains(url) { candidates.append(url) }
        }
        var resourceMetadata: [String: Any]?
        for url in candidates {
            do { resourceMetadata = try await json(url); break }
            catch { if Task.isCancelled { throw CancellationError() } }
        }
        guard let metadata = resourceMetadata, let resource = metadata["resource"] as? String,
              Self.canonical(try BoundedHTTP.endpoint(resource)) == Self.canonical(resourceURL),
              let issuers = metadata["authorization_servers"] as? [String], !issuers.isEmpty else {
            throw AppFailure.message("此端点没有提供有效的 MCP OAuth 资源元数据，请检查地址或改用 Token。")
        }
        let issuerURL = try BoundedHTTP.endpoint(issuers[0])
        var authority: [String: Any]?
        for url in Self.metadataURLs(issuer: issuerURL) {
            do { authority = try await json(url); break }
            catch { if Task.isCancelled { throw CancellationError() } }
        }
        guard let authority = authority, let issuer = authority["issuer"] as? String,
              Self.canonical(try BoundedHTTP.endpoint(issuer)) == Self.canonical(issuerURL),
              let authorization = authority["authorization_endpoint"] as? String,
              let token = authority["token_endpoint"] as? String else { throw AppFailure.message("OAuth 授权服务器发现失败或发行者不匹配。") }
        guard (authority["code_challenge_methods_supported"] as? [String])?.contains("S256") == true else {
            throw AppFailure.message("此 OAuth 服务未声明 PKCE S256 支持，无法安全地在 iPhone 上登录。请使用 Token 或让服务支持 PKCE。")
        }
        if let methods = authority["token_endpoint_auth_methods_supported"] as? [String], !methods.contains("none") {
            throw AppFailure.message("此服务要求保密客户端，不能把 Client Secret 内置到 iOS App。请使用可信后端完成授权，或使用 Token。")
        }
        return MCPOAuthDiscovery(resource: Self.canonical(resourceURL), issuer: issuer,
            authorizationEndpoint: try BoundedHTTP.endpoint(authorization), tokenEndpoint: try BoundedHTTP.endpoint(token),
            registrationEndpoint: try (authority["registration_endpoint"] as? String).map { try BoundedHTTP.endpoint($0) },
            scope: Self.parameter("scope", in: challenge) ?? (metadata["scopes_supported"] as? [String])?.joined(separator: " "))
    }
    func prepare(_ discovery: MCPOAuthDiscovery, clientID supplied: String, redirect: URL) async throws -> MCPOAuthAttempt {
        var clientID = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        if clientID.isEmpty {
            guard let registration = discovery.registrationEndpoint else {
                throw AppFailure.message("此服务不支持动态注册。请先在服务提供方注册公开 OAuth 客户端，填写 Client ID，并登记下方回调地址；需要 Client Secret 的服务须通过可信后端接入。")
            }
            var request = URLRequest(url: registration); request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["client_name": "OpenChat iOS", "redirect_uris": [redirect.absoluteString], "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"])
            let (data, _) = try await BoundedHTTP.read(request, limit: 256_000, using: session)
            let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let issued = reply?["client_id"] as? String, !issued.isEmpty,
                  (reply?["token_endpoint_auth_method"] as? String ?? "none") == "none" else { throw AppFailure.message("OAuth 客户端注册失败；此 App 需要公开客户端（无需 Client Secret）。") }
            clientID = issued
        }
        guard clientID.count <= 2048, !clientID.contains(where: { $0.isNewline }) else { throw AppFailure.message("Client ID 无效。") }
        let state = try EncodingTools.random(), verifier = try EncodingTools.random()
        var url = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var params = ["response_type": "code", "client_id": clientID, "redirect_uri": redirect.absoluteString,
            "state": state, "code_challenge": EncodingTools.challenge(verifier), "code_challenge_method": "S256", "resource": discovery.resource]
        if let scope = discovery.scope, !scope.isEmpty { params["scope"] = scope }
        url.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let authorizationURL = url.url else { throw AppFailure.message("无法生成 OAuth 登录地址。") }
        return MCPOAuthAttempt(discovery: discovery, clientID: clientID, redirect: redirect, state: state, verifier: verifier, authorizationURL: authorizationURL)
    }
    static func matchesCallback(_ callback: URL, attempt: MCPOAuthAttempt) -> Bool {
        let expected = attempt.redirect
        guard callback.scheme == expected.scheme, callback.host == expected.host, callback.port == expected.port,
              callback.path == expected.path, callback.fragment == nil,
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { return false }
        let items = parts.queryItems ?? []
        return Set(items.map(\.name)).count == items.count && items.first(where: { $0.name == "state" })?.value == attempt.state
    }
    static func code(from callback: URL, attempt: MCPOAuthAttempt) throws -> String {
        let expected = attempt.redirect
        guard callback.scheme == expected.scheme, callback.host == expected.host, callback.port == expected.port,
              callback.path == expected.path, callback.fragment == nil,
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw AppFailure.message("OAuth 回调地址不匹配。") }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { throw AppFailure.message("OAuth 回调参数重复。") }
        let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard params["state"] == attempt.state else { throw AppFailure.message("OAuth 回调 state 无效。") }
        guard params["iss"] == nil || params["iss"] == attempt.discovery.issuer else { throw AppFailure.message("OAuth 回调发行者不匹配。") }
        guard params["error"] == nil else { throw AppFailure.message("授权未完成或已被取消，请重新登录。") }
        guard let code = params["code"], !code.isEmpty, code.count < 8192 else { throw AppFailure.message("OAuth 回调缺少授权码。") }
        return code
    }
    func exchange(_ attempt: MCPOAuthAttempt, code: String) async throws -> MCPOAuthCredentials {
        try await token(attempt.discovery.tokenEndpoint, values: ["grant_type": "authorization_code", "client_id": attempt.clientID,
            "redirect_uri": attempt.redirect.absoluteString, "code": code, "code_verifier": attempt.verifier, "resource": attempt.discovery.resource],
            previous: MCPOAuthCredentials(resource: attempt.discovery.resource, issuer: attempt.discovery.issuer, tokenEndpoint: attempt.discovery.tokenEndpoint.absoluteString, clientID: attempt.clientID, accessToken: ""))
    }
    func refreshed(_ server: MCPServer) async throws -> MCPServer {
        guard let saved = server.oauth else { return server }
        guard saved.resource == Self.canonical(try BoundedHTTP.endpoint(server.endpoint)) else { throw AppFailure.message("MCP 地址已改变，请重新 OAuth 登录。") }
        guard let expiry = saved.expiresAt, expiry <= Date().addingTimeInterval(60) else { return server }
        guard let refresh = saved.refreshToken else { throw AppFailure.message("MCP 登录已过期，请在工具设置中重新登录。") }
        var result = server
        result.oauth = try await token(try BoundedHTTP.endpoint(saved.tokenEndpoint), values: ["grant_type": "refresh_token", "client_id": saved.clientID, "refresh_token": refresh, "resource": saved.resource], previous: saved)
        return result
    }
    private func token(_ endpoint: URL, values: [String: String], previous: MCPOAuthCredentials) async throws -> MCPOAuthCredentials {
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.httpBody = EncodingTools.form(values)
        let (data, response) = try await BoundedHTTP.read(request, limit: 256_000, using: session, acceptedStatus: 200..<500)
        guard (200..<300).contains(response.statusCode) else { throw AppFailure.message("OAuth 令牌交换失败（HTTP \(response.statusCode)），请检查客户端配置或重新登录。未重放工具调用。") }
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let access = reply?["access_token"] as? String, !access.isEmpty, access.count <= 8192,
              !access.contains(where: { $0.isWhitespace }), (reply?["token_type"] as? String)?.lowercased() == "bearer" else { throw AppFailure.message("OAuth 返回的 Bearer Token 无效。") }
        var updated = previous; updated.accessToken = access
        if let refresh = reply?["refresh_token"] as? String {
            guard !refresh.isEmpty, refresh.count <= 16384 else { throw AppFailure.message("OAuth 刷新令牌无效。") }
            updated.refreshToken = refresh
        }
        if let lifetime = reply?["expires_in"] as? Double {
            guard lifetime.isFinite, lifetime > 0, lifetime <= 315_360_000 else { throw AppFailure.message("OAuth 令牌有效期无效。") }
            updated.expiresAt = Date().addingTimeInterval(lifetime)
        } else { updated.expiresAt = nil }
        return updated
    }
}

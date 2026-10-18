import XCTest
@testable import LiaoChat

private final class OAuthMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], [String: Any]))?
    static func body(_ request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        return String(decoding: data, as: UTF8.self)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, headers, object) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class MCPOAuthTests: XCTestCase {
    private let resource = "https://mcp.example.com/mcp"
    private let issuer = "https://auth.example.com/tenant"
    private var discovery: MCPOAuthDiscovery { MCPOAuthDiscovery(resource: resource, issuer: issuer,
        authorizationEndpoint: URL(string: issuer + "/authorize")!, tokenEndpoint: URL(string: issuer + "/token")!,
        registrationEndpoint: URL(string: issuer + "/register")!, scope: "files:read") }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OAuthMockProtocol.self]
        return URLSession(configuration: config)
    }
    func testDiscoveryDynamicRegistrationPKCEExchangeAndRotatingRefresh() async throws {
        let session = session(); defer { session.invalidateAndCancel(); OAuthMockProtocol.handler = nil }
        var registration = 0, exchanges = 0, refreshes = 0
        OAuthMockProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            switch request.url!.path {
            case "/mcp":
                return (401, ["WWW-Authenticate": "Bearer resource_metadata=\"https://mcp.example.com/metadata\", scope=\"files:read\""], [:])
            case "/metadata": return (200, [:], ["resource": self.resource, "authorization_servers": [self.issuer], "scopes_supported": ["unused"]])
            case "/.well-known/oauth-authorization-server/tenant":
                return (200, [:], ["issuer": self.issuer, "authorization_endpoint": self.issuer + "/authorize", "token_endpoint": self.issuer + "/token", "registration_endpoint": self.issuer + "/register", "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"]])
            case "/tenant/register":
                registration += 1
                let object = try JSONSerialization.jsonObject(with: Data(OAuthMockProtocol.body(request).utf8)) as! [String: Any]
                XCTAssertEqual(object["token_endpoint_auth_method"] as? String, "none")
                XCTAssertEqual(object["redirect_uris"] as? [String], [MCPOAuthSignIn.callbackAddress])
                return (201, [:], ["client_id": "registered-public-client", "token_endpoint_auth_method": "none"])
            case "/tenant/token":
                let body = OAuthMockProtocol.body(request)
                XCTAssertTrue(body.contains("resource=https%3A%2F%2Fmcp.example.com%2Fmcp"))
                XCTAssertFalse(body.contains("client_secret"))
                if body.contains("grant_type=authorization_code") {
                    exchanges += 1; XCTAssertTrue(body.contains("code_verifier=")); XCTAssertTrue(body.contains("code=synthetic-code"))
                    return (200, [:], ["access_token": "synthetic-access", "refresh_token": "refresh-one", "token_type": "Bearer", "expires_in": 3600])
                }
                refreshes += 1; XCTAssertTrue(body.contains("refresh_token=refresh-one"))
                return (200, [:], ["access_token": "rotated-access", "refresh_token": "refresh-two", "token_type": "bearer", "expires_in": 3600])
            default: XCTFail("Unexpected URL: \(request.url!)"); return (404, [:], [:])
            }
        }
        let client = MCPOAuthClient(session: session)
        let found = try await client.discover(endpoint: resource)
        XCTAssertEqual(found.scope, "files:read")
        let attempt = try await client.prepare(found, clientID: "", redirect: URL(string: MCPOAuthSignIn.callbackAddress)!)
        let query = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "code_challenge" }?.value, EncodingTools.challenge(attempt.verifier))
        XCTAssertEqual(query.first { $0.name == "resource" }?.value, resource)
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        let callback = URL(string: MCPOAuthSignIn.callbackAddress + "?state=" + attempt.state + "&code=synthetic-code")!
        let code = try MCPOAuthClient.code(from: callback, attempt: attempt)
        var credentials = try await client.exchange(attempt, code: code)
        var server = MCPServer(name: "OAuth", endpoint: resource, enabled: true, oauth: credentials)
        let unchanged = try await client.refreshed(server); XCTAssertEqual(unchanged, server); XCTAssertEqual(refreshes, 0)
        credentials.expiresAt = .distantPast; server.oauth = credentials
        let updated = try await client.refreshed(server)
        XCTAssertEqual(updated.oauth?.accessToken, "rotated-access"); XCTAssertEqual(updated.oauth?.refreshToken, "refresh-two")
        XCTAssertEqual(registration, 1); XCTAssertEqual(exchanges, 1); XCTAssertEqual(refreshes, 1)
    }
    func testPreRegisteredClientSkipsRegistrationAndRejectsInvalidCallbacks() async throws {
        let session = session(); defer { session.invalidateAndCancel(); OAuthMockProtocol.handler = nil }
        OAuthMockProtocol.handler = { _ in XCTFail("Pre-registration should not use the network"); return (500, [:], [:]) }
        let client = MCPOAuthClient(session: session)
        let attempt = try await client.prepare(discovery, clientID: "own-client", redirect: URL(string: MCPOAuthSignIn.callbackAddress)!)
        for callback in [MCPOAuthSignIn.callbackAddress + "?state=wrong&code=code", MCPOAuthSignIn.callbackAddress + "?state=\(attempt.state)&state=\(attempt.state)&code=code", "http://127.0.0.1:51220/auth/callback?state=\(attempt.state)&code=code", MCPOAuthSignIn.callbackAddress + "?state=\(attempt.state)&code=code&iss=https://wrong.example.com", MCPOAuthSignIn.callbackAddress + "?state=\(attempt.state)&error=access_denied"] {
            XCTAssertThrowsError(try MCPOAuthClient.code(from: URL(string: callback)!, attempt: attempt))
        }
    }
    func testMissingClientRegistrationGivesSetupInstructions() async throws {
        var found = discovery; found.registrationEndpoint = nil
        do { _ = try await MCPOAuthClient().prepare(found, clientID: "", redirect: URL(string: MCPOAuthSignIn.callbackAddress)!); XCTFail("Requires client ID") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Client ID")); XCTAssertTrue(error.localizedDescription.contains("可信后端")) }
    }
    func testResourceBindingStopsRefreshBeforeSendingAnyToken() async throws {
        let session = session(); defer { session.invalidateAndCancel(); OAuthMockProtocol.handler = nil }
        OAuthMockProtocol.handler = { _ in XCTFail("Must not send credentials to a changed resource"); return (200, [:], [:]) }
        let credentials = MCPOAuthCredentials(resource: resource, issuer: issuer, tokenEndpoint: issuer + "/token", clientID: "public", accessToken: "access", refreshToken: "secret", expiresAt: .distantPast)
        let server = MCPServer(name: "Changed", endpoint: "https://other.example.com/mcp", oauth: credentials)
        do { _ = try await MCPOAuthClient(session: session).refreshed(server); XCTFail("Resource mismatch") }
        catch { XCTAssertTrue(error.localizedDescription.contains("地址已改变")) }
    }
    func testWellKnownFallbackOIDCAndMissingPKCEAreHandled() async throws {
        let session = session(); defer { session.invalidateAndCancel(); OAuthMockProtocol.handler = nil }
        var pkce = false; var paths: [String] = []
        OAuthMockProtocol.handler = { request in
            let path = request.url!.path; paths.append(path)
            if path == "/mcp" { return (401, [:], [:]) }
            if path == "/.well-known/oauth-protected-resource/mcp" { return (404, [:], [:]) }
            if path == "/.well-known/oauth-protected-resource" { return (200, [:], ["resource": self.resource, "authorization_servers": [self.issuer]]) }
            if path == "/.well-known/oauth-authorization-server/tenant" { return (404, [:], [:]) }
            var metadata: [String: Any] = ["issuer": self.issuer, "authorization_endpoint": self.issuer + "/authorize", "token_endpoint": self.issuer + "/token"]
            if pkce { metadata["code_challenge_methods_supported"] = ["S256"] }
            return (200, [:], metadata)
        }
        do { _ = try await MCPOAuthClient(session: session).discover(endpoint: resource); XCTFail("Missing PKCE") }
        catch { XCTAssertTrue(error.localizedDescription.contains("PKCE S256")) }
        pkce = true
        let found = try await MCPOAuthClient(session: session).discover(endpoint: resource)
        XCTAssertEqual(found.issuer, issuer)
        XCTAssertTrue(paths.contains("/.well-known/openid-configuration/tenant"))
    }
    func testOldTokenConnectionsDecodeWithoutOAuthAndCredentialsRoundTrip() throws {
        let old = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Old\",\"endpoint\":\"https://example.com/mcp\",\"token\":\"existing-token\",\"enabled\":true,\"tools\":[]}".utf8)
        let server = try JSONDecoder().decode(MCPServer.self, from: old)
        XCTAssertNil(server.oauth); XCTAssertEqual(server.token, "existing-token")
        let connections = MCPConnections(memoryOnly: true)
        var updated = server
        updated.oauth = MCPOAuthCredentials(resource: server.endpoint, issuer: issuer, tokenEndpoint: issuer + "/token", clientID: "own-client", accessToken: "synthetic")
        try connections.save(updated)
        XCTAssertEqual(try JSONDecoder().decode([MCPServer].self, from: JSONEncoder().encode(connections.servers)), [updated])
    }
}

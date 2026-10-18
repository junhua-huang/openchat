import Foundation

enum MCPAuthorizationMode: String, CaseIterable {
    case automatic, token, oauth
    var title: String {
        switch self { case .automatic: return "自动"; case .token: return "访问令牌"; case .oauth: return "OAuth 登录" }
    }
}

/// Only the connection handshake may open an authorization flow, never a tool call.
@MainActor enum MCPConnectionFlow {
    static func displayName(_ name: String, endpoint: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if MCPServer.isGitHubEndpoint(endpoint) { return "GitHub" }
        return URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "MCP"
    }
    static func connect(_ initial: MCPServer, mode: MCPAuthorizationMode,
                        login: (String, String) async throws -> MCPOAuthCredentials,
                        catalog: ((MCPServer) async throws -> MCPServer)? = nil) async throws -> MCPServer {
        let loadCatalog = catalog ?? { try await Self.catalog($0) }
        var server = try initial.validated()
        try Task.checkCancellation()
        guard server.enabled else { return server }
        if mode == .token || !server.token.isEmpty { server.oauth = nil; server.usesOAuth = false }
        if mode == .oauth, server.oauth == nil {
            server = try await authorized(server, login: login)
        }
        // GitHub's registration is not configured in this build. Do not launch
        // a browser flow that cannot complete or ask regular users to register apps.
        if MCPServer.isGitHubEndpoint(server.endpoint), server.token.isEmpty, server.oauth == nil {
            throw AppFailure.message(MCPServer.gitHubTokenRequired)
        }
        do { return try await loadCatalog(server) }
        catch is MCPAuthorizationRequired where mode == .automatic && server.token.isEmpty && server.oauth == nil {
            let signedIn = try await authorized(server, login: login)
            try Task.checkCancellation()
            // One authorization attempt only; 403/network errors and rejected
            // saved credentials never trigger a silent sign-in loop.
            return try await loadCatalog(signedIn)
        }
    }
    private static func authorized(_ server: MCPServer, login: (String, String) async throws -> MCPOAuthCredentials) async throws -> MCPServer {
        var result = server
        let credentials = try await login(server.endpoint, server.oauthClientID ?? "")
        try Task.checkCancellation()
        guard (credentials.boundEndpoint ?? credentials.resource) == MCPOAuthClient.canonical(try BoundedHTTP.endpoint(server.endpoint)) else {
            throw AppFailure.message("返回的授权与此服务不匹配，请重新连接。")
        }
        result.oauth = credentials; result.token = ""; result.usesOAuth = true; result.oauthClientID = credentials.clientID
        return result
    }
    static func catalog(_ server: MCPServer) async throws -> MCPServer {
        let client = MCPClient(server: server)
        defer { Task { await client.disconnect() } }
        let tools = try await client.listTools()
        try Task.checkCancellation()
        var result = client.server; result.tools = tools
        return result
    }
}

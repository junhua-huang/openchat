import Foundation
import Combine
import Security

struct MCPAuthorizationRequired: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct MCPTool: Codable, Identifiable, Equatable {
    var name: String
    var description: String?
    var inputSchema: JSONValue
    var id: String { name }
}

struct MCPServer: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var endpoint: String
    var token: String = ""
    var enabled = false
    var tools: [MCPTool] = []
    var oauth: MCPOAuthCredentials? = nil
    var oauthClientID: String? = nil
    var usesOAuth: Bool? = nil
    static let gitHubTokenRequired = "GitHub MCP 需要访问令牌。请创建 GitHub Personal Access Token，填入 Token 栏后重试。"
    static func isGitHubEndpoint(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.githubcopilot.com" else { return false }
        return url.path == "/mcp" || url.path.hasPrefix("/mcp/")
    }
    func validated() throws -> MCPServer {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.endpoint = try BoundedHTTP.endpoint(endpoint).absoluteString
        value.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= 80, value.token.count <= 8192,
              !value.token.contains(where: { $0.isWhitespace }) else { throw AppFailure.message("请检查连接名称和 Bearer Token。") }
        return value
    }
}

@MainActor final class MCPConnections: ObservableObject {
    @Published private(set) var servers: [MCPServer] = []
    @Published private(set) var ready = false
    @Published var problem: String?
    private var refreshes: [UUID: Task<MCPServer, Error>] = [:]
    private let memoryOnly: Bool
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "LiaoChat") + ".mcp",
         kSecAttrAccount as String: "servers-v1"]
    }
    init(memoryOnly: Bool = false, servers: [MCPServer] = []) {
        self.memoryOnly = memoryOnly
        if memoryOnly { self.servers = servers; ready = true } else { reload() }
    }
    func reload() {
        if memoryOnly { ready = true; return }
        do {
            var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item)
            if status == errSecItemNotFound { servers = []; ready = true; problem = nil; return }
            guard status == errSecSuccess, let data = item as? Data else { throw AppFailure.message("无法读取 MCP 钥匙串，请解锁设备后重试。") }
            servers = try JSONDecoder().decode([MCPServer].self, from: data); ready = true; problem = nil
        } catch { ready = false; problem = error.localizedDescription }
    }
    func save(_ server: MCPServer) throws {
        let value = try server.validated(); var next = servers
        if let i = next.firstIndex(where: { $0.id == value.id }) { next[i] = value } else { next.append(value) }
        try persist(next)
    }
    func authorized(_ server: MCPServer) async throws -> MCPServer {
        guard let current = servers.first(where: { $0.id == server.id }), current.enabled,
              current.endpoint == server.endpoint, current.oauth != nil else { throw AppFailure.message("MCP 连接已改变，请重新连接。") }
        if let task = refreshes[server.id] { return try await task.value }
        let task = Task { @MainActor in
            let updated = try await MCPOAuthClient().refreshed(current)
            try Task.checkCancellation()
            guard servers.first(where: { $0.id == current.id }) == current else { throw CancellationError() }
            if updated != current { try save(updated) }
            return updated
        }
        refreshes[server.id] = task
        defer { refreshes[server.id] = nil }
        return try await task.value
    }
    func delete(_ id: UUID) throws { refreshes[id]?.cancel(); try persist(servers.filter { $0.id != id }) }
    private func persist(_ next: [MCPServer]) throws {
        guard ready else { throw AppFailure.message("MCP 安全存储尚未就绪。") }
        if memoryOnly { servers = next; problem = nil; return }
        let data = try JSONEncoder().encode(next)
        guard data.count < 1_000_000 else { throw AppFailure.message("MCP 配置和工具目录过大，请减少连接或工具。") }
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if result == errSecItemNotFound {
            var q = query; attrs.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw AppFailure.message("MCP 配置保存失败。") }
        } else if result != errSecSuccess { throw AppFailure.message("MCP 配置保存失败。") }
        servers = next; problem = nil
    }
}

@MainActor final class MCPClient {
    private(set) var server: MCPServer
    private let authorize: ((MCPServer) async throws -> MCPServer)?
    private let session: URLSession
    private var sessionID: String?
    private var version = "2025-06-18"
    private var initialized = false
    init(server: MCPServer, session: URLSession = BoundedHTTP.session, authorize: ((MCPServer) async throws -> MCPServer)? = nil) { self.server = server; self.session = session; self.authorize = authorize }

    nonisolated static func rpcResult(_ data: Data, id: String) throws -> [String: Any]? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["jsonrpc"] as? String == "2.0" else { throw AppFailure.message("MCP 返回了无效的 JSON-RPC 消息。") }
        // Notifications are optional; do not claim support for server sampling/elicitation.
        if object["method"] != nil {
            if object["id"] != nil { throw AppFailure.message("该 MCP 服务要求客户端回调，当前版本不支持此能力。") }
            return nil
        }
        guard object["id"] as? String == id else { return nil }
        if object["error"] != nil { throw AppFailure.message("MCP 调用失败，请检查服务端工具和访问权限。") }
        guard let result = object["result"] as? [String: Any] else { throw AppFailure.message("MCP 返回缺少 result。") }
        return result
    }
    private func request(method: String, params: [String: Any], id: String? = nil) throws -> URLRequest {
        guard server.token.count <= 8192, !server.token.contains(where: { $0.isWhitespace }) else { throw AppFailure.message("MCP Token 无效。") }
        var request = URLRequest(url: try BoundedHTTP.endpoint(server.endpoint)); request.httpMethod = "POST"
        if server.usesOAuth == true, server.oauth == nil { throw AppFailure.message("请先在工具设置中完成 MCP OAuth 登录。") }
        if MCPServer.isGitHubEndpoint(server.endpoint), server.token.isEmpty, server.oauth == nil { throw AppFailure.message(MCPServer.gitHubTokenRequired) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let bearer = server.oauth?.accessToken ?? server.token
        if !bearer.isEmpty { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        if let sessionID = sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if initialized { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id = id { body["id"] = id }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    nonisolated static func validateResponse(_ response: URLResponse, server: MCPServer, hasSession: Bool) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw AppFailure.message("MCP 服务没有返回 HTTP 响应。") }
        let status = http.statusCode
        guard !(200..<300).contains(status) else { return http }
        let github = MCPServer.isGitHubEndpoint(server.endpoint)
        let detail: String
        switch status {
        case 401:
            detail = github && server.oauth != nil ? "GitHub OAuth 访问令牌已失效或未被接受，请在工具设置中重新登录并检查应用授权。" : github ? "GitHub 未接受此访问令牌。请检查 PAT 是否正确、过期或已撤销，再更新 Token。" : "此 MCP 服务需要授权，或当前 Token 已失效。请填写有效 Token；或在工具设置中重新 OAuth 登录。"
        case 403:
            detail = github ? "GitHub 拒绝访问。请检查 PAT 的仓库访问权限，以及组织的 SSO 授权或访问策略。" : "此 MCP 服务拒绝访问，请检查 Token 权限和服务端访问策略。"
        case 404:
            detail = hasSession ? "MCP 会话或端点已失效，请重新连接。未自动重放工具调用。" : "找不到此 MCP 端点，请检查完整地址。"
        case 405: detail = "该地址不接受 MCP POST 请求，请使用 Streamable HTTP 端点。"
        case 429: detail = "MCP 服务请求过于频繁，请稍后重试。"
        case 300..<400: detail = "MCP 地址发生重定向，请填写最终 HTTPS 端点；Token 未转发给新地址。"
        case 500..<600: detail = "MCP 服务暂时不可用，请稍后重试。"
        default: detail = "MCP 请求被服务端拒绝，请检查端点或访问设置。"
        }
        // Do not surface response bodies, authorization headers or challenge URLs.
        if status == 401 { throw MCPAuthorizationRequired(message: detail + "（HTTP \(status)）") }
        throw AppFailure.message(detail + "（HTTP \(status)）")
    }
    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if server.oauth != nil {
            if let authorize = authorize { server = try await authorize(server) }
            else { server = try await MCPOAuthClient(session: session).refreshed(server) }
        }
        try Task.checkCancellation()
        let id = UUID().uuidString; let request = try request(method: method, params: params, id: id)
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let http = try Self.validateResponse(response, server: server, hasSession: sessionID != nil)
        if method == "initialize", let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            guard session.count <= 512, session.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
                throw AppFailure.message("MCP 会话 ID 无效。")
            }
            sessionID = session
        }
        var parser = SSEParser(); var text = ""; var count = 0
        let sse = http.mimeType?.lowercased() == "text/event-stream"
        for try await line in SSEByteLines(base: bytes) {
            try Task.checkCancellation(); count += line.utf8.count + 1
            guard count <= 12_000_000 else { throw AppFailure.message("MCP 返回数据过大。") }
            if sse {
                if let payload = try parser.push(line), let result = try Self.rpcResult(Data(payload.utf8), id: id) { return result }
            } else { text += line + "\n" }
        }
        if sse, let payload = parser.finish(), let result = try Self.rpcResult(Data(payload.utf8), id: id) { return result }
        if !sse, let result = try Self.rpcResult(Data(text.utf8), id: id) { return result }
        throw AppFailure.message("MCP 连接提前结束，未收到对应请求的结果。")
    }
    func connect() async throws {
        if initialized { return }
        let result = try await rpc("initialize", ["protocolVersion": version, "capabilities": [:],
            "clientInfo": ["name": "OpenChat iOS", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.2.2"]])
        guard let negotiated = result["protocolVersion"] as? String,
              ["2025-03-26", "2025-06-18", "2025-11-25"].contains(negotiated) else {
            throw AppFailure.message("MCP 服务协商的协议版本暂不支持。")
        }
        version = negotiated; initialized = true
        let notification = try request(method: "notifications/initialized", params: [:])
        do { _ = try await BoundedHTTP.read(notification, limit: 4096, using: session) }
        catch { initialized = false; throw error }
    }
    func listTools() async throws -> [MCPTool] {
        try await connect()
        var result: [MCPTool] = []; var cursor: String?; var seen = Set<String>()
        for _ in 0..<8 {
            let page = try await rpc("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            guard let items = page["tools"] as? [[String: Any]] else { throw AppFailure.message("MCP 没有返回工具目录。") }
            let decoded = try JSONDecoder().decode([MCPTool].self, from: JSONSerialization.data(withJSONObject: items))
            for tool in decoded where seen.insert(tool.name).inserted {
                guard !tool.name.isEmpty, tool.name.count <= 128, case .object = tool.inputSchema else { throw AppFailure.message("MCP 工具定义无效。") }
                result.append(tool)
            }
            guard result.count <= 64 else { throw AppFailure.message("每个 MCP 服务最多启用 64 个工具。") }
            cursor = page["nextCursor"] as? String
            if cursor == nil { return result }
        }
        throw AppFailure.message("MCP 工具分页过多。")
    }
    func call(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await connect()
        return try await rpc("tools/call", ["name": name, "arguments": arguments])
    }
    func disconnect() async {
        defer { self.sessionID = nil; initialized = false }
        guard let sessionID = sessionID, var request = try? request(method: "", params: [:]) else { return }
        request.httpMethod = "DELETE"; request.httpBody = nil
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        _ = try? await BoundedHTTP.read(request, limit: 4096, using: session)
    }
}

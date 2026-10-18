import Foundation

struct MCPListing: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let endpoint: String?
    let website: String?
    let authorization: String
    var limitation: String? = nil
    var canConnect: Bool { endpoint != nil && limitation == nil }
    var server: MCPServer? {
        guard canConnect, let endpoint = endpoint else { return nil }
        return MCPServer(name: String(title.prefix(80)), endpoint: endpoint, enabled: true)
    }
}

struct MCPRegistryPage {
    let entries: [MCPListing]
    let nextCursor: String?
}

struct MCPRegistryClient {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    var transport: Transport? = nil
    static let recommendations: [MCPListing] = [
        MCPListing(id: "recommended-deepwiki", title: "DeepWiki", summary: "查询公开 GitHub 仓库的文档，理解代码与项目结构。",
            endpoint: "https://mcp.deepwiki.com/mcp", website: "https://docs.devin.ai/work-with-devin/deepwiki-mcp", authorization: "公开仓库 · 无需密钥"),
        MCPListing(id: "recommended-microsoft", title: "Microsoft Learn", summary: "搜索微软官方技术文档和代码示例。",
            endpoint: "https://learn.microsoft.com/api/mcp", website: "https://learn.microsoft.com/en-us/training/support/mcp", authorization: "公开文档 · 无需密钥"),
        MCPListing(id: "recommended-context7", title: "Context7", summary: "查找开发库的最新文档和用法，适合编程问题。",
            endpoint: "https://mcp.context7.com/mcp", website: "https://context7.com/docs", authorization: "支持 Bearer API Key · 配额由服务商决定")
    ]
    static func searchTerm(_ query: String) -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["搜索": "search", "文档": "docs", "开发文档": "docs", "代码仓库": "github", "网页": "fetch", "数据库": "database"][query] ?? query
    }
    func search(_ query: String, cursor: String? = nil) async throws -> MCPRegistryPage {
        let term = Self.searchTerm(query)
        guard term.count <= 200, (cursor?.utf8.count ?? 0) <= 4096 else { throw AppFailure.message("搜索词过长，请简化后重试。") }
        var url = URLComponents(string: "https://registry.modelcontextprotocol.io/v0.1/servers")!
        url.queryItems = [URLQueryItem(name: "version", value: "latest"), URLQueryItem(name: "limit", value: "30")]
        if !term.isEmpty { url.queryItems?.append(URLQueryItem(name: "search", value: term)) }
        if let cursor = cursor, !cursor.isEmpty { url.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        var request = URLRequest(url: url.url!); request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // No model key, MCP token, attachment or chat history is sent here.
        let data: Data; let response: HTTPURLResponse
        if let transport = transport { (data, response) = try await transport(request) }
        else { (data, response) = try await BoundedHTTP.read(request, limit: 2_000_000) }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode), data.count <= 2_000_000 else { throw AppFailure.message("MCP 目录暂时不可用，请稍后重试。推荐服务和手动添加仍可使用。") }
        return try Self.decode(data)
    }
    static func decode(_ data: Data) throws -> MCPRegistryPage {
        guard data.count <= 2_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["servers"] as? [[String: Any]], records.count <= 100 else { throw AppFailure.message("MCP 目录返回的数据格式无效。") }
        var entries: [MCPListing] = []; var seen = Set<String>()
        for record in records {
            let official = (record["_meta"] as? [String: Any])?["io.modelcontextprotocol.registry/official"] as? [String: Any]
            if let status = official?["status"] as? String, status != "active" { continue }
            if official?["isLatest"] as? Bool == false { continue }
            guard let server = record["server"] as? [String: Any], let name = server["name"] as? String,
                  !name.isEmpty, name.count <= 200 else { continue }
            let title = String((server["title"] as? String ?? name).prefix(120))
            let summary = String((server["description"] as? String ?? "发布者未提供说明。").prefix(1500))
            let repository = (server["repository"] as? [String: Any])?["url"] as? String
            let website = safeWebsite(server["websiteUrl"] as? String ?? repository)
            let remotes = Array((server["remotes"] as? [[String: Any]] ?? []).prefix(8))
            if remotes.isEmpty {
                if seen.insert(name).inserted { entries.append(MCPListing(id: name, title: title, summary: summary, endpoint: nil,
                    website: website, authorization: "本机程序", limitation: "需要在电脑或服务器部署，不能在 iPhone 直接运行。")) }
            }
            for remote in remotes {
                let raw = remote["url"] as? String ?? ""
                let id = name + ":" + raw
                guard seen.insert(id).inserted else { continue }
                var limitation: String?
                if remote["type"] as? String != "streamable-http" { limitation = "当前仅支持 Streamable HTTP 连接。" }
                let valid = raw.count <= 2000 && !raw.contains("{") && !raw.contains("}") && (try? BoundedHTTP.endpoint(raw)) != nil
                if !valid { limitation = "需要专属地址或额外配置，请查看服务商文档后手动添加。" }
                let headers = remote["headers"] as? [[String: Any]] ?? []
                var bearer = false
                for header in headers {
                    let field = (header["name"] as? String ?? "").lowercased()
                    if field == "authorization" {
                        bearer = true
                        if let value = header["value"] as? String, !value.isEmpty, !value.lowercased().hasPrefix("bearer ") {
                            limitation = "该服务需要当前尚未支持的授权方式。"
                        }
                    } else if !["accept", "content-type"].contains(field), header["isRequired"] as? Bool != false {
                        limitation = "需要自定义请求头，当前版本暂不支持。"
                    }
                }
                entries.append(MCPListing(id: id, title: title, summary: summary, endpoint: valid ? raw : nil, website: website,
                    authorization: bearer ? "可能需要 Bearer Token" : "连接时检查授权要求", limitation: limitation))
            }
        }
        let rawCursor = (root["metadata"] as? [String: Any])?["nextCursor"] as? String
        let cursor = rawCursor.flatMap { !$0.isEmpty && $0.utf8.count <= 4096 ? $0 : nil }
        return MCPRegistryPage(entries: Array(entries.prefix(200)), nextCursor: cursor)
    }
    private static func safeWebsite(_ raw: String?) -> String? {
        guard let raw = raw, raw.count <= 2000, let url = URLComponents(string: raw), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url.url?.absoluteString
    }
}

import XCTest
@testable import LiaoChat

private final class MCPMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw AppFailure.message("Missing synthetic request body") }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0, data.count + count <= 1_000_000 else { throw AppFailure.message("Invalid synthetic body stream") }
            if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw AppFailure.message("Missing synthetic MCP transport") }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for start in stride(from: 0, to: data.count, by: 7) { client?.urlProtocol(self, didLoad: data.subdata(in: start..<min(start + 7, data.count))) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MCPTests: XCTestCase {
    func testEndpointAndCredentialValidation() throws {
        for url in ["http://example.com/mcp", "https://user:password@example.com/mcp", "https://example.com/mcp?key=secret", "invalid"] {
            XCTAssertThrowsError(try MCPServer(name: "test", endpoint: url).validated())
        }
        XCTAssertThrowsError(try MCPServer(name: "test", endpoint: "https://example.com/mcp", token: "key\r\nInjected: value").validated())
        XCTAssertEqual(try MCPServer(name: "Test", endpoint: " https://example.com/mcp ").validated().endpoint, "https://example.com/mcp")
    }
    func testRPCMatchesIDAndRejectsErrorsWithoutExposingServerMessages() throws {
        let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{}}"#.utf8)
        XCTAssertNil(try MCPClient.rpcResult(notification, id: "wanted"))
        XCTAssertNil(try MCPClient.rpcResult(Data(#"{"jsonrpc":"2.0","id":"other","result":{}}"#.utf8), id: "wanted"))
        let error = Data(#"{"jsonrpc":"2.0","id":"wanted","error":{"code":-32000,"message":"secret-token"}}"#.utf8)
        XCTAssertThrowsError(try MCPClient.rpcResult(error, id: "wanted")) { XCTAssertFalse($0.localizedDescription.contains("secret-token")) }
        XCTAssertThrowsError(try MCPClient.rpcResult(Data(#"{"jsonrpc":"2.0","id":"callback","method":"sampling/createMessage"}"#.utf8), id: "wanted"))
    }
    @MainActor func testStreamableHTTPHandshakeSessionHeadersPaginationAndToolCall() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MCPMockProtocol.self]
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); MCPMockProtocol.handler = nil }
        var requests: [URLRequest] = []
        MCPMockProtocol.handler = { request in
            requests.append(request)
            let body = try JSONSerialization.jsonObject(with: MCPMockProtocol.body(request)) as! [String: Any]
            let method = body["method"] as? String; let id = body["id"] as? String ?? ""
            if method == "notifications/initialized" { return (202, [:], Data()) }
            var result: [String: Any] = [:]
            if method == "initialize" { result = ["protocolVersion": "2025-06-18", "capabilities": ["tools": [:]], "serverInfo": ["name": "Synthetic", "version": "1"]] }
            if method == "tools/list" {
                let cursor = (body["params"] as? [String: Any])?["cursor"] as? String
                result = ["tools": [["name": cursor == nil ? "first" : "second", "description": "合成工具", "inputSchema": ["type": "object", "properties": [:]]]]]
                if cursor == nil { result["nextCursor"] = "page2" }
            }
            if method == "tools/call" { result = ["content": [["type": "text", "text": "你好🙂"]]] }
            let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
            let encoded = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
            if method == "tools/call" { return (200, ["Content-Type": "application/json"], Data(encoded.utf8)) }
            let sse = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\r\n\r\ndata: \(encoded)\r\n\r\n"
            return (200, ["Content-Type": "text/event-stream", "Mcp-Session-Id": "synthetic-session"], Data(sse.utf8))
        }
        let client = MCPClient(server: MCPServer(name: "Synthetic", endpoint: "https://synthetic.invalid/mcp", token: "synthetic-token"), session: session)
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["first", "second"])
        let result = try await client.call(name: "second", arguments: ["value": "你好"])
        XCTAssertEqual((result["content"] as? [[String: String]])?.first?["text"], "你好🙂")
        XCTAssertEqual(requests.count, 5)
        for request in requests.dropFirst() {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "synthetic-session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        }
        XCTAssertTrue(requests.first?.value(forHTTPHeaderField: "Accept")?.contains("application/json") == true)
        XCTAssertTrue(requests.first?.value(forHTTPHeaderField: "Accept")?.contains("text/event-stream") == true)
    }
    @MainActor func testRemoteMCPDenialDoesNotSendHTTPRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = JSONValue.object(["type": .string("object"), "properties": .object([:])])
        let server = MCPServer(name: "Synthetic", endpoint: "https://synthetic.invalid/mcp", enabled: true,
            tools: [MCPTool(name: "external_write", description: "Synthetic action", inputSchema: schema)])
        var approvals = 0
        let runtime = ToolRuntime(vault: try FileVault(accountID: UUID(), root: root), files: [], servers: [server],
            approve: { _, _ in approvals += 1; return false }, event: { _ in })
        let tool = try XCTUnwrap(runtime.definitions().first { $0.name.hasPrefix("mcp_") })
        let result = try await runtime.execute(ToolCall(id: "denied", name: tool.name, arguments: "{}"))
        XCTAssertEqual(approvals, 1); XCTAssertTrue(result.contains("用户拒绝"))
    }
}

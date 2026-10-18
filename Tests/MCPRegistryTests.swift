import XCTest
@testable import LiaoChat

final class MCPRegistryTests: XCTestCase {
    private func data(_ servers: [[String: Any]], cursor: String? = nil) throws -> Data {
        var root: [String: Any] = ["servers": servers]
        if let cursor = cursor { root["metadata"] = ["nextCursor": cursor] }
        return try JSONSerialization.data(withJSONObject: root)
    }
    private func record(_ name: String, remote: [String: Any]? = nil, status: String = "active") -> [String: Any] {
        var server: [String: Any] = ["name": name, "description": "服务描述🙂", "title": name]
        if let remote = remote { server["remotes"] = [remote] }
        return ["server": server, "_meta": ["io.modelcontextprotocol.registry/official": ["status": status, "isLatest": true]]]
    }
    private func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }
    func testRegistryKeepsCompatibleRemotesAndExplainsLocalOrUnsupportedServers() throws {
        let raw = try data([
            record("remote", remote: ["type": "streamable-http", "url": "https://example.com/mcp"]),
            record("local"), record("old-sse", remote: ["type": "sse", "url": "https://example.com/sse"]),
            record("custom-header", remote: ["type": "streamable-http", "url": "https://other.example/mcp", "headers": [["name": "X-API-Key", "isRequired": true]]]),
            record("deleted", status: "deleted")])
        let page = try MCPRegistryClient.decode(raw)
        XCTAssertEqual(page.entries.count, 4); XCTAssertEqual(page.entries.filter(\.canConnect).count, 1)
        XCTAssertNotNil(page.entries.first?.server); XCTAssertNil(page.entries[1].server)
        XCTAssertTrue(page.entries[1].limitation?.contains("电脑") == true)
        XCTAssertTrue(page.entries[3].limitation?.contains("请求头") == true)
    }
    func testBearerEndpointsDoNotCopyPublisherCredentialsIntoNewConnections() throws {
        let page = try MCPRegistryClient.decode(data([record("bearer", remote: ["type": "streamable-http", "url": "https://example.com/mcp",
            "headers": [["name": "Authorization", "value": "Bearer {YOUR_KEY}"]]])]))
        XCTAssertTrue(page.entries.first?.canConnect == true)
        XCTAssertEqual(page.entries.first?.server?.token, "")
        XCTAssertTrue(page.entries.first?.authorization.contains("Bearer") == true)
    }
    func testUnsafeOrTemplatedEndpointsCannotBecomeConnections() throws {
        let invalid = ["http://example.com/mcp", "https://user:secret@example.com/mcp", "https://example.com/{key}/mcp", "https://example.com/mcp?key=secret", "file:///tmp/mcp"]
        let page = try MCPRegistryClient.decode(data(invalid.enumerated().map { record("server\($0.offset)", remote: ["type": "streamable-http", "url": $0.element]) }))
        XCTAssertEqual(page.entries.count, invalid.count); XCTAssertTrue(page.entries.allSatisfy { !$0.canConnect && $0.server == nil })
    }
    func testInactiveAndDuplicateRegistryRecordsAreFiltered() throws {
        let remote: [String: Any] = ["type": "streamable-http", "url": "https://example.com/mcp"]
        let page = try MCPRegistryClient.decode(data([record("same", remote: remote), record("same", remote: remote), record("inactive", remote: remote, status: "deprecated")], cursor: "next+page/🙂"))
        XCTAssertEqual(page.entries.count, 1); XCTAssertEqual(page.nextCursor, "next+page/🙂")
    }
    func testMalformedAndOversizedRegistryResponsesFailClearly() throws {
        XCTAssertThrowsError(try MCPRegistryClient.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try MCPRegistryClient.decode(Data(repeating: 32, count: 2_000_001)))
    }
    func testSearchEncodesQueryAndCursorWithoutSendingCredentials() async throws {
        let client = MCPRegistryClient(transport: { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.host, "registry.modelcontextprotocol.io")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "search" }?.value, "搜索 & 文档🙂")
            XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "a+b/c?🙂")
            XCTAssertEqual(items.first { $0.name == "version" }?.value, "latest")
            return (try self.data([]), self.response(request))
        })
        _ = try await client.search("搜索 & 文档🙂", cursor: "a+b/c?🙂")
        XCTAssertEqual(MCPRegistryClient.searchTerm("开发文档"), "docs")
        XCTAssertEqual(MCPRegistryClient.searchTerm("天气"), "weather")
    }
    @MainActor func testLateSearchResultCannotOverwriteNewQuery() async throws {
        var release: CheckedContinuation<Void, Never>?
        let client = MCPRegistryClient(transport: { request in
            let term = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "search" }?.value ?? ""
            if term == "old" { await withCheckedContinuation { release = $0 } }
            return (try self.data([self.record(term)]), self.response(request))
        })
        let store = MCPDiscoveryStore(client: client)
        let old = Task { await store.search("old", debounce: false) }
        for _ in 0..<100 { if release != nil { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(release)
        await store.search("new", debounce: false)
        release?.resume(); await old.value
        XCTAssertEqual(store.entries.first?.title, "new"); XCTAssertFalse(store.loading)
    }
    @MainActor func testPaginationDeduplicatesAndStopsRepeatedCursor() async throws {
        var count = 0
        let client = MCPRegistryClient(transport: { request in
            count += 1
            return (try self.data(count == 1 ? [self.record("one")] : [self.record("one"), self.record("two")], cursor: "page1"), self.response(request))
        })
        let store = MCPDiscoveryStore(client: client)
        await store.search("test", debounce: false); await store.more(); await store.more()
        XCTAssertEqual(store.entries.map(\.title), ["one", "two"]); XCTAssertEqual(count, 2); XCTAssertNil(store.nextCursor)
    }
    func testRecommendationsHaveValidatedEndpointsAndNoEmbeddedSecrets() throws {
        XCTAssertEqual(MCPRegistryClient.recommendations.count, 3)
        for listing in MCPRegistryClient.recommendations {
            let server = try XCTUnwrap(listing.server).validated()
            XCTAssertEqual(server.token, ""); XCTAssertNotNil(URL(string: try XCTUnwrap(listing.website)))
        }
    }
}

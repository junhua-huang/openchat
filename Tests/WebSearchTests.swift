import XCTest
@testable import LiaoChat

final class WebSearchTests: XCTestCase {
    private let html = """
    <html><body>
    <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fnews%3Fid%3D1%26lang%3Dzh&amp;rut=ignored"><b>合成 AI 新闻</b> &amp; &#x1F642;</a>
    <a class="result__snippet">今天的合成摘要。<b>不是实际新闻</b> &quot;测试&quot;</a>
    <a href='https://example.org/article' class='result__a'>Second synthetic source</a>
    <div class='result__snippet'>Another synthetic summary</div>
    <a class="result__a" href="https://example.org/article">Duplicate</a>
    <a class="result__a" href="javascript:alert(1)">Unsafe</a>
    </body></html>
    """
    private let rss = """
    <?xml version="1.0"?><rss version="2.0"><channel><title>Search</title>
    <item><title>Fallback &amp; test</title><link>https://example.net/item</link><description><![CDATA[<b>合成 RSS</b>]]></description></item>
    </channel></rss>
    """
    private func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
    }
    func testSearchRequestPreservesChineseSpecialCharactersAndContainsNoCredentials() throws {
        let query = "今日 AI & iOS + 2026-10-18 #测试"
        let request = try WebSearchClient.request(query: query, freshness: .day)
        let parts = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "html.duckduckgo.com")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "q" }?.value, query)
        XCTAssertEqual(parts.queryItems?.first { $0.name == "df" }?.value, "d")
        XCTAssertTrue(request.url!.absoluteString.contains("%2B"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.httpBody)
        for invalid in ["", "  ", String(repeating: "x", count: 501)] {
            XCTAssertThrowsError(try WebSearchClient.request(query: invalid, freshness: .any))
        }
    }
    func testSearchHTMLDecodesWrappedURLsUnicodeAndSnippetsWithoutDuplicateOrUnsafeLinks() throws {
        let results = try WebSearchClient.duckDuckGo(Data(html.utf8), count: 6)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "合成 AI 新闻 & 🙂")
        XCTAssertEqual(results[0].url, "https://example.com/news?id=1&lang=zh")
        XCTAssertEqual(results[0].snippet, "今天的合成摘要。 不是实际新闻 \"测试\"")
        XCTAssertEqual(results[1].snippet, "Another synthetic summary")
        XCTAssertEqual(try WebSearchClient.duckDuckGo(Data(html.utf8), count: 1).count, 1)
        for raw in ["javascript:alert(1)", "file:///private/test", "https://user:secret@example.com/", "//duckduckgo.com/?q=not-a-result"] {
            XCTAssertNil(WebSearchClient.resultURL(raw))
        }
    }
    func testRSSFallbackAndMalformedPagesCannotFabricateSearchResults() throws {
        let results = try WebSearchClient.bingRSS(Data(rss.utf8), count: 6)
        XCTAssertEqual(results, [WebSearchResult(title: "Fallback & test", url: "https://example.net/item", snippet: "合成 RSS")])
        for value in ["<html>Sign in or challenge</html>", "<html>anomaly.js</html>", "not HTML"] {
            XCTAssertThrowsError(try WebSearchClient.duckDuckGo(Data(value.utf8), count: 6))
        }
        XCTAssertThrowsError(try WebSearchClient.bingRSS(Data("<html>Sign in</html>".utf8), count: 6))
        XCTAssertThrowsError(try WebSearchClient.bingRSS(Data("<!DOCTYPE rss [<!ENTITY x SYSTEM 'https://example.invalid/secret'>]><rss/>".utf8), count: 6))
        XCTAssertEqual(try WebSearchClient.duckDuckGo(Data("<div class='no-results'>No results found</div>".utf8), count: 6), [])
    }
    func testSearchUsesPrimaryAndFallsBackWithExplicitDateFilterBoundary() async throws {
        var requests: [URLRequest] = []
        let client = WebSearchClient(transport: { request in
            requests.append(request)
            if requests.count == 1 { return (Data("<html>anomaly.js</html>".utf8), self.response(request)) }
            return (Data(self.rss.utf8), self.response(request))
        })
        let result = try await client.search(query: "今日 AI", freshness: .day, count: 4)
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(result.provider, "Bing")
        XCTAssertFalse(result.filteredByDate); XCTAssertEqual(result.results.count, 1)
        XCTAssertEqual(requests.last?.url?.host, "www.bing.com")
        let primary = WebSearchClient(transport: { request in (Data(self.html.utf8), self.response(request)) })
        let primaryResult = try await primary.search(query: "AI", freshness: .week, count: 2)
        XCTAssertEqual(primaryResult.provider, "DuckDuckGo"); XCTAssertTrue(primaryResult.filteredByDate)
    }
    func testCancellationAndProviderFailureDoNotReturnStaleOrInventedResults() async throws {
        var attempts = 0
        let client = WebSearchClient(transport: { _ in attempts += 1; throw CancellationError() })
        do { _ = try await client.search(query: "AI", freshness: .day, count: 3); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts, 1)
        let failure = WebSearchClient(transport: { _ in throw URLError(.cannotConnectToHost) })
        do { _ = try await failure.search(query: "AI", freshness: .day, count: 3); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("没有取得")) }
        do { _ = try await client.search(query: "AI", freshness: .any, count: 9); XCTFail("Expected count validation") }
        catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(attempts, 1)
    }
    func testOldSettingsAndReplyVersionsKeepSearchPreferencesAndSources() throws {
        let old = Data(#"{"enabled":true,"webSearch":false,"codeInterpreter":false,"imageGeneration":false}"#.utf8)
        var settings = try JSONDecoder().decode(ToolSettings.self, from: old)
        XCTAssertTrue(settings.allowsPublicSearch); settings.allowsPublicSearch = false
        XCTAssertFalse(try JSONDecoder().decode(ToolSettings.self, from: JSONEncoder().encode(settings)).allowsPublicSearch)
        let source = WebSearchResult(title: "合成来源", url: "https://example.com", snippet: "test")
        var message = ChatMessage(role: .assistant, text: "摘要", toolActivities: [ToolActivity(id: "s1", name: "search_web", state: "complete", sources: [source])])
        message.beginRegeneration(model: "m"); message.status = .complete; message.text = "新版"
        XCTAssertTrue(message.chooseVersion(0))
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.toolActivities?.first?.sources, [source])
    }
    @MainActor func testPlanSearchToolRoundTripReturnsRealSourcesAndOverridesOldCapabilityClaim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [ToolActivity] = []; var searches = 0; var requests: [[String: Any]] = []
        let client = WebSearchClient(transport: { request in
            searches += 1; XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (Data(self.html.utf8), self.response(request))
        })
        let runtime = ToolRuntime(vault: try FileVault(accountID: UUID(), root: root), files: [], servers: [],
            approve: { _, _ in false }, event: { if case .activity(let activity) = $0 { events.append(activity) } }, searchClient: client)
        try await ChatAgentClient.run(endpoint: AgentEndpoint(token: "synthetic-ai-token", connection: nil), model: "gpt-6.1-sol",
            history: [ChatMessage(role: .assistant, text: "我不能按关键词搜索"), ChatMessage(role: .user, text: "今日 AI 新闻")],
            effort: .automatic, settings: ToolSettings(), runtime: runtime, delta: { _ in }, responseTransport: { request in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]); requests.append(body)
                return requests.count == 1 ? [["type": "function_call", "call_id": "search1", "name": "search_web", "arguments": #"{"query":"今日 AI 2026-10-18","freshness":"day"}"#]] : [["type": "message", "content": [["type": "output_text", "text": "已找到以下来源。"]]]]
            })
        XCTAssertEqual(searches, 1); XCTAssertEqual(requests.count, 2)
        let tools = try XCTUnwrap(requests.first?["tools"] as? [[String: Any]])
        XCTAssertNotNil(tools.first { $0["name"] as? String == "search_web" })
        let input = try XCTUnwrap(requests.last?["input"] as? [[String: Any]])
        XCTAssertTrue((input.first?["content"] as? String ?? "").contains("无需用户先提供链接"))
        let output = try XCTUnwrap(input.first { $0["type"] as? String == "function_call_output" })
        XCTAssertEqual(output["call_id"] as? String, "search1")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((output["output"] as! String).utf8)) as? [String: Any])
        XCTAssertEqual((result["results"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(events.last?.sources?.count, 2); XCTAssertEqual(events.last?.state, "complete")
        var disabled = ToolSettings(); disabled.allowsPublicSearch = false
        XCTAssertNil(try runtime.definitions(settings: disabled).first { $0.name == "search_web" })
        let rejected = try await runtime.execute(ToolCall(id: "disabled", name: "search_web", arguments: #"{"query":"AI"}"#))
        XCTAssertTrue(rejected.contains("关闭")); XCTAssertEqual(searches, 1)
        var hosted = ToolSettings(); hosted.webSearch = true
        XCTAssertNil(try runtime.definitions(settings: hosted, hostedSearch: true).first { $0.name == "search_web" })
    }
}

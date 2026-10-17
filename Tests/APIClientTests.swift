import XCTest
@testable import LiaoChat

final class APIClientTests: XCTestCase {
    private func connection(base: String = "https://example.com/compatible/v1/") -> APIConnection {
        APIConnection(name: "Test service", baseURL: base, apiKey: "synthetic-test-key", modelIDs: ["text-model"])
    }

    func testBaseURLNormalizesFullEndpointAndPreservesVersionPath() throws {
        XCTAssertEqual(try APIConnection.normalizedURL(" https://example.com/compatible/v1/chat/completions/ ").absoluteString,
                       "https://example.com/compatible/v1")
        XCTAssertEqual(try APIConnection.normalizedURL("https://example.com/v1/models").absoluteString, "https://example.com/v1")
        XCTAssertEqual(try APIConnection.normalizedURL("https://example.com/").absoluteString, "https://example.com")
    }

    func testRejectsUnencryptedOrCredentialBearingBaseURLs() {
        for input in ["http://example.com/v1", "ftp://example.com", "https://user:password@example.com/v1",
                      "https://example.com/v1?api_key=test", "https://example.com/v1#fragment", "not a url"] {
            XCTAssertThrowsError(try APIConnection.normalizedURL(input), input)
        }
    }

    func testModelIDsAcceptChineseSeparatorsAndRemoveDuplicates() {
        XCTAssertEqual(APIConnection.parseModels(" first,second，first\r\n第三个\n  \n"), ["first", "second", "第三个"])
    }

    func testValidationRequiresKeyAndModelsAndRejectsHeaderInjection() throws {
        var value = connection()
        value.apiKey = "test\r\nHeader: value"
        XCTAssertThrowsError(try value.validated())
        value.apiKey = ""
        XCTAssertThrowsError(try value.validated())
        value.apiKey = "synthetic-test-key"
        value.modelIDs = []
        XCTAssertThrowsError(try value.validated())
        value.modelIDs = ["text-model", "text-model"]
        XCTAssertEqual(try value.validated().modelIDs, ["text-model"])
    }

    func testRequestUsesConfiguredEndpointAndBearerHeader() throws {
        let request = try APIChatClient.request(connection: connection(), path: "models")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/compatible/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-key")
        XCTAssertNil(request.url?.query)
    }

    func testChatRequestKeepsUnicodeContextAndOmitsInterruptedResponses() throws {
        let history = [ChatMessage(role: .user, text: "你好🙂"), ChatMessage(role: .assistant, text: "半条回复", status: .cancelled),
                       ChatMessage(role: .user, text: "重新解释")]
        let request = try APIChatClient.chatRequest(connection: connection(), model: "text-model", history: history)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/compatible/v1/chat/completions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "text-model")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "你好🙂"], ["role": "user", "content": "重新解释"]])
        XCTAssertNil(body["api_key"])
    }

    func testCatalogDeduplicatesIDsAndAllowsEmptyCatalog() throws {
        let data = Data(#"{"data":[{"id":"b"},{"id":"a"},{"id":"b"},{"id":""}]}"#.utf8)
        XCTAssertEqual(try APIChatClient.decodeModels(data).map(\.slug), ["a", "b"])
        XCTAssertTrue(try APIChatClient.decodeModels(Data(#"{"data":[]}"#.utf8)).isEmpty)
        XCTAssertThrowsError(try APIChatClient.decodeModels(Data(#"{"unexpected":[]}"#.utf8)))
    }

    func testStreamingContentRequiresNormalFinish() throws {
        var state = ChatCompletionStreamState()
        var text = ""
        XCTAssertFalse(try state.consume(#"{"choices":[{"index":0,"delta":{"content":"你好🙂"},"finish_reason":null}]}"#, onDelta: { text += $0 }))
        XCTAssertFalse(try state.consume(#"{"choices":[],"usage":{"total_tokens":4}}"#, onDelta: { text += $0 }))
        XCTAssertTrue(try state.consume(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, onDelta: { text += $0 }))
        XCTAssertEqual(text, "你好🙂")
        XCTAssertTrue(state.completed)
        XCTAssertTrue(try state.consume("[DONE]", onDelta: { _ in XCTFail("No text after completion") }))
    }

    func testPrematureDoneAndErrorAreNotSuccessfulReplies() {
        var state = ChatCompletionStreamState()
        for payload in ["[DONE]", #"{"error":{"message":"do not echo server errors"}}"#, #"{"wrong_protocol":true}"#] {
            XCTAssertThrowsError(try state.consume(payload, onDelta: { _ in }))
        }
    }

    func testTruncationFilteringAndToolCallsRemainIncomplete() {
        var state = ChatCompletionStreamState()
        for reason in ["length", "content_filter", "tool_calls", "function_call", "unknown"] {
            let payload = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"" + reason + "\"}]}"
            XCTAssertThrowsError(try state.consume(payload, onDelta: { _ in }), reason)
        }
    }
}

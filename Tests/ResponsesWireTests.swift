import XCTest
@testable import LiaoChat

final class ResponsesWireTests: XCTestCase {
    private func bytes(_ text: String) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in text.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
    }

    func testByteLinesPreserveEmptyLinesAndUnicodeForEverySSEDelimiter() async throws {
        for separator in ["\n", "\r\n", "\r"] {
            let input = ["\u{FEFF}: 注释", "", "你好🙂\u{0085}\u{2028}\u{2029}", "", "末行"].joined(separator: separator)
            var actual: [String] = []
            for try await line in SSEByteLines(base: bytes(input)) { actual.append(line) }
            XCTAssertEqual(actual, ["\u{FEFF}: 注释", "", "你好🙂\u{0085}\u{2028}\u{2029}", "", "末行"])
            if separator == "\n" {
                var nativeEmptyLines = 0
                for try await line in bytes(input).lines where line.isEmpty { nativeEmptyLines += 1 }
                print("SSE framing probe: Foundation empty lines=\(nativeEmptyLines), preserved empty lines=\(actual.filter { $0.isEmpty }.count)")
            }
        }
    }

    @MainActor func testRawByteStreamReachesCompletionWithMissingMIMEAndMultilineEvents() async throws {
        for separator in ["\n", "\r\n", "\r"] {
            let lines = ["\u{FEFF}: heartbeat", "", "event: response.created",
                #"data: {"type":"response.created"}"#, "", "event: response.output_text.delta",
                #"data: {"type":"response.output_text.delta","delta":"你好🙂"}"#, "",
                "data: {", #"data: "type":"response.completed","response":{"status":"completed"}}"#]
            var text = ""
            try await ResponsesClient.consume(bytes(lines.joined(separator: separator)), response: http()) { text += $0 }
            XCTAssertEqual(text, "你好🙂")
        }
    }

    @MainActor func testLostEventSeparatorsReproduceInvalidJSONInsteadOfCompleting() throws {
        var decoder = ResponsesWireDecoder(response: http())
        XCTAssertFalse(try decoder.push(#"data: {"type":"response.created"}"#) { _ in })
        XCTAssertFalse(try decoder.push(#"data: {"type":"response.completed","response":{"status":"completed"}}"#) { _ in })
        XCTAssertThrowsError(try decoder.finish { _ in }) { error in
            XCTAssertTrue((error as? ResponseFailure)?.diagnostic.contains("Body: invalid_event_json") == true)
        }
        XCTAssertFalse(decoder.completed)
    }

    @MainActor func testEmptyDataHeartbeatDoesNotRejectNextCompletedEvent() async throws {
        let input = "data:\n\n: keepalive\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
        try await ResponsesClient.consume(bytes(input), response: http()) { _ in }
    }

    @MainActor func testMalformedEventsHaveDistinctSafeDiagnostics() throws {
        for (payload, shape) in [("private content", "invalid_event_json"), ("[]", "event_not_object"),
                                  (#"{"private":"secret-content"}"#, "event_missing_type")] {
            XCTAssertThrowsError(try ResponsesClient.handle(payload, response: http()) { _ in }) { error in
                let diagnostic = (error as? ResponseFailure)?.diagnostic ?? ""
                XCTAssertTrue(diagnostic.contains("Body: " + shape))
                XCTAssertFalse(diagnostic.contains("private"))
                XCTAssertFalse(diagnostic.contains("secret-content"))
            }
        }
        XCTAssertThrowsError(try ResponsesClient.handle(#"{"error":{"code":"subscription_sharing_usage_unavailable"}}"#, response: http()) { _ in }) { error in
            XCTAssertTrue((error as? ResponseFailure)?.diagnostic.contains("Code: subscription_sharing_usage_unavailable") == true)
        }
    }

    private func http(_ status: Int = 200, type: String? = nil) -> HTTPURLResponse {
        var headers = ["x-request-id": "req_synthetic123"]
        if let type = type { headers["Content-Type"] = type }
        return HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!, statusCode: status,
                               httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func testPlanRequestKeepsRequiredFlagsAndMinimalInput() throws {
        let request = try ResponsesClient.request(token: "synthetic-token", model: "account-model",
            history: [ChatMessage(role: .user, text: "你好🙂")])
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let data = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["model", "input", "store", "stream"]))
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["input"] as? [[String: String]])?.first?["content"], "你好🙂")
    }

    @MainActor func testSSEWithoutContentTypeStillStreamsAndCompletes() throws {
        var decoder = ResponsesWireDecoder(response: http())
        var text = ""
        for line in ["\u{FEFF}: heartbeat", "data: {\"type\":\"response.output_text.delta\",\"delta\":\"你好🙂\"}", ""] {
            XCTAssertFalse(try decoder.push(line) { text += $0 })
        }
        XCTAssertFalse(try decoder.push(#"data: {"type":"response.completed","response":{"status":"completed"}}"#) { text += $0 })
        XCTAssertTrue(try decoder.finish { text += $0 })
        XCTAssertEqual(text, "你好🙂")
    }

    @MainActor func testIncorrectJSONHeaderDoesNotRejectRealSSE() throws {
        var decoder = ResponsesWireDecoder(response: http(type: "application/json"))
        XCTAssertFalse(try decoder.push(#"event: response.completed"#) { _ in })
        XCTAssertFalse(try decoder.push(#"data: {"type":"response.completed","response":{"status":"completed"}}"#) { _ in })
        XCTAssertTrue(try decoder.push("") { _ in })
    }

    @MainActor func testJSONErrorPreservesCodeParameterAndRequestID() throws {
        var decoder = ResponsesWireDecoder(response: http(type: "application/json"))
        let payload = #"{"error":{"code":"subscription_sharing_unsupported_capability","param":"instructions","message":"private server text"}}"#
        XCTAssertThrowsError(try decoder.push(payload) { _ in }) { error in
            let failure = error as? ResponseFailure
            XCTAssertTrue(failure?.diagnostic.contains("HTTP: 200") == true)
            XCTAssertTrue(failure?.diagnostic.contains("Code: subscription_sharing_unsupported_capability") == true)
            XCTAssertTrue(failure?.diagnostic.contains("Parameter: instructions") == true)
            XCTAssertTrue(failure?.diagnostic.contains("Request ID: req_synthetic123") == true)
            XCTAssertFalse(failure?.diagnostic.contains("private server text") == true)
        }
    }

    @MainActor func testPrettyPrintedAdmissionErrorKeepsStatusWithoutLeakingDetail() throws {
        var decoder = ResponsesWireDecoder(response: http(503, type: "application/json"))
        XCTAssertFalse(try decoder.push("{") { _ in })
        XCTAssertFalse(try decoder.push(#"  "detail": "SECRET-TOKEN private diagnostic body""#) { _ in })
        XCTAssertThrowsError(try decoder.push("}") { _ in }) { error in
            let failure = error as? ResponseFailure
            XCTAssertTrue(failure?.diagnostic.contains("HTTP: 503") == true)
            XCTAssertTrue(failure?.diagnostic.contains("json_detail") == true)
            XCTAssertFalse(failure?.diagnostic.contains("SECRET-TOKEN") == true)
            XCTAssertFalse(error.localizedDescription.contains("SECRET-TOKEN"))
        }
    }

    @MainActor func testHTMLAndEmptyResponsesCannotCountAsSuccess() throws {
        var html = ResponsesWireDecoder(response: http(type: "text/html"))
        XCTAssertThrowsError(try html.push("<!doctype html><p>private content</p>") { _ in }) { error in
            let failure = error as? ResponseFailure
            XCTAssertTrue(failure?.diagnostic.contains("Body: html") == true)
            XCTAssertFalse(failure?.diagnostic.contains("private content") == true)
        }
        var empty = ResponsesWireDecoder(response: http())
        XCTAssertThrowsError(try empty.finish { _ in })
    }

    @MainActor func testJSONResponseWithoutCompletedEventIsNotSuccess() throws {
        var decoder = ResponsesWireDecoder(response: http(type: "application/json"))
        XCTAssertThrowsError(try decoder.push(#"{"object":"response","status":"completed","output":[]}"#) { _ in })
        XCTAssertFalse(decoder.completed)
    }

    @MainActor func testTypedJSONEventsAndCompletedOnlyText() throws {
        var decoder = ResponsesWireDecoder(response: http(type: "application/json"))
        var text = ""
        XCTAssertTrue(try decoder.push(#"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"完整回复🙂"}]}]}}"#) { text += $0 })
        XCTAssertEqual(text, "完整回复🙂")
    }

    @MainActor func testCompletedOutputDoesNotDuplicateDeltas() throws {
        var decoder = ResponsesWireDecoder(response: http(type: "application/json"))
        var text = ""
        XCTAssertFalse(try decoder.push(#"{"type":"response.output_text.delta","delta":"回复"}"#) { text += $0 })
        XCTAssertTrue(try decoder.push(#"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"回复"}]}]}}"#) { text += $0 })
        XCTAssertEqual(text, "回复")
    }

    @MainActor func testStreamErrorAndPrematureDoneRemainFailures() throws {
        var decoder = ResponsesWireDecoder(response: http(type: "text/event-stream"))
        XCTAssertFalse(try decoder.push(#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#) { _ in })
        XCTAssertThrowsError(try decoder.push("") { _ in }) { error in
            XCTAssertTrue((error as? ResponseFailure)?.diagnostic.contains("subscription_sharing_usage_limit_exceeded") == true)
        }
        var interrupted = ResponsesWireDecoder(response: http())
        XCTAssertFalse(try interrupted.push("data: [DONE]") { _ in })
        XCTAssertFalse(try interrupted.push("") { _ in })
        XCTAssertThrowsError(try interrupted.finish { _ in })
    }

    func testUnsafeMetadataCannotLeakTokensIntoDiagnostics() {
        let response = HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "secret/private-token", "x-request-id": "Bearer private-token"])!
        let failure = ResponseFailure.make(response: response, shape: "json_error", object: [
            "error": ["code": "sk-private-token", "param": "Bearer private-token", "message": "secret prompt"],
            "access_token": "secret-access-token", "detail": "secret-detail"
        ])
        for secret in ["private-token", "secret prompt", "secret-access-token", "secret-detail"] {
            XCTAssertFalse(failure.diagnostic.contains(secret))
            XCTAssertFalse(failure.message.contains(secret))
        }
    }

    func testExistingChatMessagesDecodeWithoutDiagnosticField() throws {
        let data = Data(#"{"id":"D66C9EA0-640F-4C63-B5AA-73A21587F8A0","role":"assistant","text":"旧消息","status":"complete"}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertNil(message.diagnostic)
        XCTAssertEqual(message.text, "旧消息")
    }
}

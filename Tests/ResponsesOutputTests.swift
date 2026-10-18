import XCTest
@testable import LiaoChat

final class ResponsesOutputTests: XCTestCase {
    private func http() -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!, statusCode: 200, httpVersion: nil, headerFields: [:])!
    }
    private func event(_ type: String, _ fields: [String: Any]) -> [String: Any] { fields.merging(["type": type]) { _, new in new } }
    private var call: [String: Any] {
        ["id": "fc_test", "type": "function_call", "call_id": "call_test", "name": "create_file",
         "arguments": #"{"name":"小说.docx","format":"docx","content":"星空🙂"}"#]
    }
    @MainActor private func decode(_ events: [[String: Any]], delta: (String) -> Void = { _ in }) throws -> [[String: Any]] {
        var decoder = ResponsesWireDecoder(response: http())
        for event in events {
            let data = try JSONSerialization.data(withJSONObject: event)
            _ = try decoder.push("data: " + String(decoding: data, as: UTF8.self), onDelta: delta)
            _ = try decoder.push("", onDelta: delta)
        }
        _ = try decoder.finish(onDelta: delta)
        return decoder.output
    }
    private var completed: [String: Any] { event("response.completed", ["response": ["status": "completed", "output": []]]) }

    @MainActor func testSparseTerminalPreservesCompletedToolCallAndFinalReasoning() throws {
        let output = try decode([
            event("response.output_item.added", ["output_index": 0, "item": ["id": "rs_test", "type": "reasoning", "encrypted_content": "partial"]]),
            event("response.output_item.done", ["output_index": 0, "item": ["id": "rs_test", "type": "reasoning", "encrypted_content": "final-opaque", "summary": []]]),
            event("response.output_item.done", ["output_index": 1, "item": call]), completed])
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output.first?["encrypted_content"] as? String, "final-opaque")
        XCTAssertEqual(output.last?["call_id"] as? String, "call_test")
        XCTAssertEqual(output.last?["arguments"] as? String, call["arguments"] as? String)
    }
    @MainActor func testArgumentFragmentsAreReplacedByDoneInsteadOfDuplicated() throws {
        var added = call; added["arguments"] = ""; added["status"] = "in_progress"
        let args = call["arguments"] as! String
        let split = args.index(args.startIndex, offsetBy: 17)
        let output = try decode([
            event("response.output_item.added", ["output_index": 0, "item": added]),
            event("response.function_call_arguments.delta", ["output_index": 0, "item_id": "fc_test", "delta": String(args[..<split])]),
            event("response.function_call_arguments.delta", ["output_index": 0, "item_id": "fc_test", "delta": String(args[split...])]),
            event("response.function_call_arguments.done", ["output_index": 0, "item_id": "fc_test", "arguments": args]),
            event("response.output_item.done", ["output_index": 0, "item": call]),
            event("response.completed", ["response": ["status": "completed", "output": [call]]])])
        XCTAssertEqual(output.count, 1); XCTAssertEqual(output.first?["arguments"] as? String, args)
    }
    @MainActor func testArgumentsDoneCanFinalizeCallWhenItemDoneIsOmitted() throws {
        var added = call; added["arguments"] = ""
        let output = try decode([
            event("response.output_item.added", ["output_index": 0, "item": added]),
            event("response.function_call_arguments.done", ["output_index": 0, "item_id": "fc_test", "arguments": call["arguments"]!]), completed])
        XCTAssertEqual(output.first?["name"] as? String, "create_file")
        XCTAssertEqual(output.first?["arguments"] as? String, call["arguments"] as? String)
    }
    @MainActor func testUnfinishedOrConflictingCallsCannotExecute() throws {
        var added = call; added["arguments"] = "{"
        XCTAssertThrowsError(try decode([event("response.output_item.added", ["output_index": 0, "item": added]), completed]))
        var other = call; other["id"] = "fc_other"
        XCTAssertThrowsError(try decode([
            event("response.output_item.added", ["output_index": 0, "item": call]),
            event("response.output_item.done", ["output_index": 0, "item": other]), completed]))
        var changed = call; changed["arguments"] = "{}"
        XCTAssertThrowsError(try decode([
            event("response.output_item.done", ["output_index": 0, "item": call]),
            event("response.completed", ["response": ["status": "completed", "output": [changed]]])]))
    }
    @MainActor func testDoneOnlyMessageAndCitationsSurviveSparseTerminal() throws {
        var text = ""
        let output = try decode([
            event("response.output_item.done", ["output_index": 0, "item": ["id": "msg_test", "type": "message", "role": "assistant", "content": [
                ["type": "output_text", "text": "生成成功🙂", "annotations": [["type": "container_file_citation", "file_id": "file_test", "container_id": "cntr_test", "filename": "小说.docx"]]]]]]), completed], delta: { text += $0 })
        XCTAssertEqual(text, "生成成功🙂")
        let content = output.first?["content"] as? [[String: Any]]
        XCTAssertEqual((content?.first?["annotations"] as? [[String: Any]])?.first?["file_id"] as? String, "file_test")
    }
    @MainActor func testToolStreamMustStillReachRealResponseCompletion() throws {
        XCTAssertThrowsError(try decode([event("response.output_item.done", ["output_index": 0, "item": call])]))
        XCTAssertThrowsError(try decode([event("response.output_item.done", ["output_index": 256, "item": call]), completed]))
        var huge = call; huge["arguments"] = String(repeating: "x", count: 256_001)
        XCTAssertThrowsError(try decode([event("response.output_item.done", ["output_index": 0, "item": huge]), completed]))
    }
    @MainActor func testStreamedWordToolActuallyCreatesDownloadableDocumentAndContinues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        var cards: [ChatAttachment] = []; var requests = 0; var text = ""
        let runtime = ToolRuntime(vault: vault, files: [], servers: [], approve: { _, _ in false }, event: { if case .file(let file) = $0 { cards.append(file) } })
        try await ChatAgentClient.run(endpoint: AgentEndpoint(token: "synthetic", connection: nil), model: "gpt-6.1-sol", history: [], effort: .automatic,
            settings: ToolSettings(), runtime: runtime, delta: { text += $0 }, responseTransport: { request in
                requests += 1
                if requests == 1 { return try self.decode([self.event("response.output_item.done", ["output_index": 0, "item": self.call]), self.completed]) }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let input = try XCTUnwrap(body["input"] as? [[String: Any]])
                XCTAssertEqual(input.last?["call_id"] as? String, "call_test")
                XCTAssertTrue((input.last?["output"] as? String ?? "").contains(cards.first?.id.uuidString ?? "missing"))
                return [["type": "message", "content": [["type": "output_text", "text": "文档已生成。"]]]]
            })
        XCTAssertEqual(requests, 2); XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.name, "小说.docx")
        XCTAssertTrue(try FileFormats.extract(vault.data(XCTUnwrap(cards.first)), ext: "docx").contains("星空🙂"))
        XCTAssertTrue(text.contains("文档已生成。"))
    }
    @MainActor func testReasoningOnlyAndEmptyModelOutputsAreFailuresWithoutAutomaticRetry() async throws {
        let outputs: [[[String: Any]]] = [[], [["type": "reasoning", "id": "rs_only", "summary": []]]]
        for output in outputs {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let runtime = ToolRuntime(vault: try FileVault(accountID: UUID(), root: root), files: [], servers: [], approve: { _, _ in false }, event: { _ in })
            var requests = 0
            do {
                try await ChatAgentClient.run(endpoint: AgentEndpoint(token: "synthetic", connection: nil), model: "gpt-6.1-sol", history: [], effort: .automatic,
                    settings: ToolSettings(), runtime: runtime, delta: { _ in }, responseTransport: { _ in requests += 1; return output })
                XCTFail("Empty output must not be successful")
            } catch { XCTAssertTrue((error as? ResponseFailure)?.diagnostic.contains("empty_model_output") == true) }
            XCTAssertEqual(requests, 1); XCTAssertTrue(runtime.files.isEmpty)
        }
    }
}

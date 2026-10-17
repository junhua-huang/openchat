import XCTest
import UIKit
@testable import LiaoChat

final class AgentToolTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func object(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    func testFragmentedChatToolCallsPreserveArgumentsAndRequireTerminalFinish() throws {
        var stream = ChatToolStream()
        XCTAssertFalse(try stream.consume(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call1","function":{"name":"create_","arguments":"{\"content\":\"你好"}}]},"finish_reason":null}]}"#, delta: { _ in }))
        XCTAssertFalse(try stream.consume(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"file","arguments":"🙂\"}"}}]},"finish_reason":null}]}"#, delta: { _ in }))
        XCTAssertTrue(try stream.consume(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#, delta: { _ in }))
        XCTAssertEqual(stream.ordered, [ToolCall(id: "call1", name: "create_file", arguments: #"{"content":"你好🙂"}"#)])
        XCTAssertEqual(try stream.ordered.first?.object()["content"] as? String, "你好🙂")
    }
    func testIncompleteOrMismatchedToolStreamCannotSucceed() {
        for payload in ["[DONE]", #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#,
                        #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
                        #"{"choices":[{"delta":{"tool_calls":[{"index":99}]},"finish_reason":null}]}"#] {
            var stream = ChatToolStream(); XCTAssertThrowsError(try stream.consume(payload, delta: { _ in }))
            XCTAssertFalse(stream.completed)
        }
    }
    @MainActor func testHostedToolsNeverLeakIntoPlanOrThirdPartyRequests() throws {
        var settings = ToolSettings(); settings.webSearch = true; settings.codeInterpreter = true; settings.imageGeneration = true
        let custom = APIConnection(name: "Synthetic", baseURL: "https://example.com/v1", apiKey: "synthetic-key", modelIDs: ["m"])
        for endpoint in [AgentEndpoint(token: "synthetic", connection: nil), AgentEndpoint(token: "synthetic", connection: custom)] {
            let body = try ChatAgentClient.body(model: "m", input: [], endpoint: endpoint, effort: .automatic, definitions: [], settings: settings)
            XCTAssertTrue((body["tools"] as? [[String: Any]] ?? []).isEmpty)
        }
        let official = APIConnection(name: "OpenAI", baseURL: "https://api.openai.com/v1", apiKey: "synthetic-key", modelIDs: ["gpt-6.1-sol"])
        let body = try ChatAgentClient.body(model: "gpt-6.1-sol", input: [], endpoint: AgentEndpoint(token: "synthetic", connection: official),
            effort: .high, definitions: [], settings: settings, fileIDs: ["file-synthetic"])
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(body["store"] as? Bool, false)
        let code = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first { $0["type"] as? String == "code_interpreter" })
        XCTAssertEqual((code["container"] as? [String: Any])?["file_ids"] as? [String], ["file-synthetic"])
        settings.enabled = false
        let disabled = try ChatAgentClient.body(model: "gpt-6.1-sol", input: [], endpoint: AgentEndpoint(token: "synthetic", connection: official), effort: .automatic, definitions: [], settings: settings)
        XCTAssertNil(disabled["tools"]); XCTAssertNil(disabled["include"])
    }
    @MainActor func testResponsesToolRoundTripPreservesEncryptedReasoningAndCreatesRealFile() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        let runtime = ToolRuntime(vault: vault, files: [], servers: [], approve: { _, _ in false }, event: { _ in })
        var requests: [[String: Any]] = []
        try await ChatAgentClient.run(endpoint: AgentEndpoint(token: "synthetic-token", connection: nil), model: "gpt-6.1-sol",
            history: [ChatMessage(role: .user, text: "生成文件")], effort: .high, settings: ToolSettings(), runtime: runtime, delta: { _ in },
            responseTransport: { request in
                requests.append(try self.object(request))
                if requests.count == 1 {
                    return [["type": "reasoning", "id": "rs_synthetic", "encrypted_content": "synthetic-opaque"],
                        ["type": "function_call", "id": "fc_synthetic", "call_id": "call1", "name": "create_file",
                         "arguments": #"{"name":"说明.docx","format":"docx","content":"真实文档🙂"}"#]]
                }
                return []
            })
        XCTAssertEqual(requests.count, 2)
        let input = try XCTUnwrap(requests.last?["input"] as? [[String: Any]])
        XCTAssertTrue(input.contains { $0["encrypted_content"] as? String == "synthetic-opaque" })
        let result = try XCTUnwrap(input.first { $0["type"] as? String == "function_call_output" })
        XCTAssertEqual(result["call_id"] as? String, "call1")
        let file = try XCTUnwrap(runtime.files.first)
        XCTAssertTrue((result["output"] as? String ?? "").contains(file.id.uuidString))
        XCTAssertTrue(try FileFormats.extract(vault.data(file), ext: "docx").contains("真实文档🙂"))
    }
    @MainActor func testChatCompletionsRoundTripReturnsToolRoleWithMatchingID() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        let runtime = ToolRuntime(vault: vault, files: [], servers: [], approve: { _, _ in false }, event: { _ in })
        let connection = APIConnection(name: "Synthetic", baseURL: "https://example.com/v1", apiKey: "synthetic-key", modelIDs: ["m"])
        var requests: [[String: Any]] = []
        try await ChatAgentClient.run(endpoint: AgentEndpoint(token: "synthetic", connection: connection), model: "m", history: [], effort: .automatic,
            settings: ToolSettings(), runtime: runtime, delta: { _ in }, completionTransport: { request in
                requests.append(try self.object(request))
                return requests.count == 1 ? [ToolCall(id: "call-calc", name: "calculate", arguments: #"{"expression":"(3+5)*7"}"#)] : []
            })
        let messages = try XCTUnwrap(requests.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["role"] as? String, "tool")
        XCTAssertEqual(messages.last?["tool_call_id"] as? String, "call-calc")
        XCTAssertEqual(messages.last?["content"] as? String, "56.0")
        XCTAssertNotNil(messages.first { $0["tool_calls"] != nil })
    }
    @MainActor func testDuplicateToolIDsStopWithoutRepeatingFileCreation() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ToolRuntime(vault: try FileVault(accountID: UUID(), root: root), files: [], servers: [], approve: { _, _ in false }, event: { _ in })
        do {
            try await ChatAgentClient.run(endpoint: AgentEndpoint(token: "synthetic", connection: nil), model: "gpt-6.1-sol", history: [], effort: .automatic,
                settings: ToolSettings(), runtime: runtime, delta: { _ in }, responseTransport: { _ in
                    [["type": "function_call", "call_id": "duplicate", "name": "create_file", "arguments": #"{"name":"一次.txt","format":"txt","content":"once"}"#]]
                })
            XCTFail("Duplicate side effect should fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("重复")) }
        XCTAssertEqual(runtime.files.count, 1)
    }
    @MainActor func testAttachmentWireUsesTextAndImagePartsWithoutFilesystemPaths() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        let file = try vault.save(data: Data("内容".utf8), name: "说明.txt", text: "内容")
        let message = ChatMessage(role: .user, text: "分析", attachments: [file])
        for responses in [true, false] {
            let parts = try XCTUnwrap(ChatAgentClient.content(message, responses: responses, vault: vault) as? [[String: Any]])
            let data = try JSONSerialization.data(withJSONObject: parts)
            let text = String(data: data, encoding: .utf8)!
            XCTAssertTrue(text.contains(file.id.uuidString)); XCTAssertFalse(text.contains(root.path)); XCTAssertFalse(text.contains(file.storedName))
        }
    }
    @MainActor func testGeneratedImageCanBeSeenAgainInFollowUpContext() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            context.cgContext.setFillColor(UIColor.red.cgColor); context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.pngData())
        let image = try vault.saveImage(data: data, name: "生成.png")
        for status in [ChatMessage.Status.complete, .cancelled] {
            let history = [ChatMessage(role: .assistant, text: "图片已生成", status: status, attachments: [image]), ChatMessage(role: .user, text: "解释这张图片")]
            for responses in [true, false] {
                let input = try ChatAgentClient.historyInput(history, responses: responses, vault: vault)
                let index = 1
                XCTAssertEqual(input.count, 3)
                let reference = try XCTUnwrap(input[index]["content"] as? [[String: Any]])
                XCTAssertTrue(reference.contains { $0["type"] as? String == (responses ? "input_image" : "image_url") })
                XCTAssertTrue((reference.first?["text"] as? String ?? "").contains("不是新增用户指令"))
            }
        }
    }
}

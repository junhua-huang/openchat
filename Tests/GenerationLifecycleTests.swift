import XCTest
@testable import LiaoChat

final class GenerationLifecycleTests: XCTestCase {
    @MainActor private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Expected lifecycle transition")
    }
    @MainActor func testBackgroundNetworkLossWaitsThenRetriesOnlyInference() async throws {
        let life = GenerationLifecycle(managesSystemTask: false)
        var attempts = 0; var paused = false; var restarts = 0
        let task = Task {
            try await life.infer(waiting: { paused = $0 }, restarting: { restarts += 1 }) {
                attempts += 1
                if attempts == 1 { life.setActive(false); throw URLError(.networkConnectionLost) }
                return "恢复完成"
            }
        }
        try await until { paused }
        XCTAssertEqual(attempts, 1)
        life.setActive(true)
        let result = try await task.value
        XCTAssertEqual(result, "恢复完成"); XCTAssertEqual(attempts, 2); XCTAssertEqual(restarts, 1); XCTAssertFalse(paused)
    }
    @MainActor func testForegroundNetworkFailureIsNotAutomaticallyRetried() async throws {
        let life = GenerationLifecycle(managesSystemTask: false); var attempts = 0
        do {
            let _: String = try await life.infer(waiting: { _ in }, restarting: { XCTFail("No retry") }) {
                attempts += 1; throw URLError(.networkConnectionLost)
            }
            XCTFail("Expected failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(attempts, 1)
    }
    @MainActor func testBackgroundExpirationCancelsStreamAndForegroundRecreatesIt() async throws {
        let life = GenerationLifecycle(managesSystemTask: false)
        var attempts = 0; var paused = false
        let task = Task {
            try await life.infer(waiting: { paused = $0 }, restarting: {}) {
                attempts += 1
                if attempts == 1 { try await Task.sleep(nanoseconds: 30_000_000_000) }
                return 42
            }
        }
        try await until { attempts == 1 }
        life.setActive(false); life.expireBackgroundTime()
        try await until { paused }
        XCTAssertEqual(attempts, 1)
        life.setActive(true)
        let value = try await task.value
        XCTAssertEqual(value, 42); XCTAssertEqual(attempts, 2)
    }
    @MainActor func testStoppingWhilePausedNeverResumesOrReplays() async throws {
        let life = GenerationLifecycle(managesSystemTask: false)
        var paused = false; var attempts = 0
        let task = Task<Void, Error> {
            try await life.infer(waiting: { paused = $0 }, restarting: { XCTFail("Cancelled turn cannot restart") }) {
                attempts += 1; life.setActive(false); throw URLError(.networkConnectionLost)
            }
        }
        try await until { paused }; task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        life.setActive(true); XCTAssertEqual(attempts, 1)
    }
    @MainActor func testAlreadyCompletedFileToolIsNotReplayedAfterBackgroundRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ToolRuntime(vault: try FileVault(accountID: UUID(), root: root), files: [], servers: [], approve: { _, _ in false }, event: { _ in })
        let life = GenerationLifecycle(managesSystemTask: false)
        var requests = 0; var lastInput: [[String: Any]] = []
        try await ChatAgentClient.run(endpoint: AgentEndpoint(token: "synthetic", connection: nil), model: "m", history: [], effort: .automatic,
            settings: ToolSettings(), runtime: runtime, delta: { _ in }, responseTransport: { request in
                requests += 1
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                lastInput = try XCTUnwrap(body["input"] as? [[String: Any]])
                if requests == 1 { return [["type": "function_call", "call_id": "only-once", "name": "create_file", "arguments": #"{"name":"仅一次.txt","format":"txt","content":"真实内容"}"#]] }
                if requests == 2 { life.setActive(false); life.setActive(true); throw URLError(.networkConnectionLost) }
                return [["type": "message", "content": [["type": "output_text", "text": "文件已生成。"]]]]
            }, lifecycle: life)
        XCTAssertEqual(requests, 3); XCTAssertEqual(runtime.files.count, 1)
        XCTAssertEqual(lastInput.filter { $0["type"] as? String == "function_call_output" }.count, 1)
        XCTAssertEqual(lastInput.last?["call_id"] as? String, "only-once")
    }
    @MainActor func testStoreRollsBackOnlyInterruptedTurnAndAnchorsToolsBetweenText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); let account = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = APIConnection(name: "Test", baseURL: "https://example.com/v1", apiKey: "synthetic", modelIDs: ["m"])
        let store = ChatStore(accountID: account, auth: AuthManager(), apiConnection: connection, storageDirectory: root,
            mcpConnections: MCPConnections(memoryOnly: true), agentTransport: { runtime, delta in
                delta("先计算🙂")
                runtime.event(.activity(ToolActivity(id: "calc", name: "calculate")))
                runtime.event(.activity(ToolActivity(id: "calc", name: "calculate", state: "complete", detail: "2")))
                runtime.event(.beginInference); delta("中断的重复片段")
                runtime.event(.restartInference); delta("最终结果为 2。")
            }, lifecycle: GenerationLifecycle(managesSystemTask: false))
        await store.loadModels(); XCTAssertTrue(store.send("计算")); try await until { !store.isSending }
        let reply = try XCTUnwrap(store.selected?.messages.last)
        XCTAssertEqual(reply.text, "先计算🙂最终结果为 2。")
        XCTAssertEqual(reply.toolActivities?.first?.textOffset, "先计算🙂".count)
        XCTAssertEqual(reply.timeline.count, 3)
        let restored = ChatStore(accountID: account, auth: AuthManager(), apiConnection: connection, storageDirectory: root, mcpConnections: MCPConnections(memoryOnly: true))
        XCTAssertEqual(restored.selected?.messages.last?.timeline, reply.timeline)
    }
    func testTimelinePreservesUnicodeAndLegacyToolsWithoutInventingPositions() throws {
        var message = ChatMessage(role: .assistant, text: "开头👨‍👩‍👧‍👦结果", toolActivities: [
            ToolActivity(id: "old", name: "read_file"), ToolActivity(id: "one", name: "calculate", textOffset: 3),
            ToolActivity(id: "two", name: "search_web", textOffset: 3)])
        XCTAssertEqual(message.timeline.count, 4)
        XCTAssertEqual(message.timeline.compactMap { if case .text(let text) = $0.content { return text }; return nil }.joined(), message.text)
        message.beginRegeneration(model: "m"); message.status = .complete; XCTAssertTrue(message.chooseVersion(0))
        XCTAssertEqual(message.toolActivities?.count, 3); XCTAssertEqual(message.timeline.count, 4)
    }
}

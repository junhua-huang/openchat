import XCTest
@testable import LiaoChat

@MainActor private final class ControlledChat {
    var streams: [AsyncThrowingStream<String, Error>] = []
    var histories: [[ChatMessage]] = []
    var efforts: [ReasoningEffort] = []
    var delivered = 0
    func channel() -> AsyncThrowingStream<String, Error>.Continuation {
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        streams.append(AsyncThrowingStream { continuation = $0 })
        return continuation
    }
    func run(_ model: String, _ history: [ChatMessage], _ effort: ReasoningEffort, _ delta: @escaping (String) -> Void) async throws {
        guard !streams.isEmpty else { throw AppFailure.message("Missing synthetic stream") }
        let stream = streams.removeFirst(); histories.append(history); efforts.append(effort)
        for try await text in stream { delta(text); delivered += 1 }
    }
}

final class ChatStoreTests: XCTestCase {
    @MainActor private func fixture(_ control: ControlledChat, id: UUID = UUID(), directory: URL,
                                   models: [String] = ["test-model"]) async -> ChatStore {
        let connection = APIConnection(name: "Synthetic", baseURL: "https://api.openai.com/v1",
                                       apiKey: "synthetic-key", modelIDs: models)
        let store = ChatStore(accountID: id, auth: AuthManager(), apiConnection: connection,
            storageDirectory: directory, transport: { model, history, effort, delta in try await control.run(model, history, effort, delta) })
        await store.loadModels()
        return store
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    @MainActor private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Synthetic stream did not reach the expected state", file: file, line: line)
    }
    @MainActor func testStopFlushesPartialTextAndLateCallbacksCannotReplaceNextReply() async throws {
        let control = ControlledChat(); let first = control.channel(); let second = control.channel()
        let directory = directory(); let store = await fixture(control, directory: directory)
        defer { store.stopAll(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(store.send("第一问"))
        first.yield("已收到的内容")
        try await waitFor { control.delivered == 1 }
        store.stop()
        XCTAssertFalse(store.isSending)
        XCTAssertEqual(store.selected?.messages.last?.text, "已收到的内容")
        XCTAssertEqual(store.selected?.messages.last?.status, .cancelled)
        XCTAssertTrue(store.send("第二问"))
        first.yield("过期内容"); first.finish()
        second.yield("新回复"); second.finish()
        try await waitFor { !store.isSending }
        XCTAssertEqual(store.selected?.messages.last?.text, "新回复")
        XCTAssertEqual(store.selected?.messages.last?.status, .complete)
        XCTAssertFalse(store.selected?.messages.contains(where: { $0.text.contains("过期内容") }) == true)
    }
    @MainActor func testSwitchingThreadsKeepsIndependentRequestsAndStoppingIsLocal() async throws {
        let control = ControlledChat(); let first = control.channel(); let second = control.channel()
        let directory = directory(); let store = await fixture(control, directory: directory)
        defer { store.stopAll(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(store.send("对话 A")); let a = try XCTUnwrap(store.selected)
        try await waitFor { control.histories.count == 1 }
        store.newThread(); XCTAssertTrue(store.send("对话 B")); let b = try XCTUnwrap(store.selected)
        try await waitFor { control.histories.count == 2 }
        XCTAssertEqual(store.generatingThreadIDs.count, 2)
        first.yield("A 的内容"); second.yield("B 的内容"); second.finish()
        try await waitFor { !store.generatingThreadIDs.contains(b.id) && control.delivered == 2 }
        store.select(a); XCTAssertTrue(store.isSending); store.stop()
        XCTAssertEqual(store.selected?.messages.last?.text, "A 的内容")
        XCTAssertEqual(store.threads.first(where: { $0.id == b.id })?.messages.last?.text, "B 的内容")
        XCTAssertEqual(store.threads.first(where: { $0.id == b.id })?.messages.last?.status, .complete)
    }
    @MainActor func testSuccessfulReplyCanRegenerateAndSelectedVersionIsUsedForFollowUp() async throws {
        let control = ControlledChat(); let first = control.channel(); let second = control.channel(); let third = control.channel()
        let directory = directory(); let store = await fixture(control, directory: directory)
        defer { store.stopAll(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(store.send("问题")); first.yield("第一版"); first.finish()
        try await waitFor { !store.isSending }
        store.retry(); XCTAssertTrue(store.isSending); second.yield("第二版"); second.finish()
        try await waitFor { !store.isSending }
        let response = try XCTUnwrap(store.selected?.messages.last)
        XCTAssertEqual(response.versionCount, 2)
        store.chooseVersion(messageID: response.id, index: 0)
        XCTAssertEqual(store.selected?.messages.last?.text, "第一版")
        XCTAssertTrue(store.send("继续"))
        third.finish()
        try await waitFor { control.histories.count == 3 && !store.isSending }
        XCTAssertEqual(control.histories.last?.filter { $0.role == .assistant }.map(\.text), ["第一版"])
    }
    @MainActor func testIndependentDraftsPinAndSelectionRestoreFromArchive() async throws {
        let control = ControlledChat(); let id = UUID(); let directory = directory()
        let store = await fixture(control, id: id, directory: directory)
        defer { store.stopAll(); try? FileManager.default.removeItem(at: directory) }
        store.updateDraft("草稿 A"); let a = try XCTUnwrap(store.selectedID)
        store.newThread(); store.updateDraft("草稿 B"); let b = try XCTUnwrap(store.selectedID)
        XCTAssertNotEqual(a, b)
        store.togglePin(a); store.flushDrafts()
        let restored = await fixture(control, id: id, directory: directory)
        defer { restored.stopAll() }
        XCTAssertEqual(restored.selectedID, b)
        XCTAssertEqual(restored.selected?.draft, "草稿 B")
        XCTAssertEqual(restored.threads.first(where: { $0.id == a })?.draft, "草稿 A")
        XCTAssertEqual(restored.threads.first(where: { $0.id == a })?.isPinned, true)
    }

    @MainActor func testEffortIsCapturedForEachRequestAndCannotChangeDuringGeneration() async throws {
        let control = ControlledChat(); let first = control.channel(); let second = control.channel()
        let directory = directory()
        let store = await fixture(control, directory: directory, models: ["gpt-6.1-sol"])
        defer { store.stopAll(); try? FileManager.default.removeItem(at: directory) }
        store.selectEffort(.high)
        XCTAssertTrue(store.send("对话 A")); let a = try XCTUnwrap(store.selected)
        store.selectEffort(.low)
        XCTAssertEqual(store.selectedEffort, .high)
        // Switch before the first request task runs: it must retain A's effort.
        store.newThread(); store.selectEffort(.max)
        XCTAssertTrue(store.send("对话 B"))
        try await waitFor { control.efforts.count == 2 }
        let aRequest = try XCTUnwrap(control.histories.firstIndex(where: { $0.last?.text == "对话 A" }))
        let bRequest = try XCTUnwrap(control.histories.firstIndex(where: { $0.last?.text == "对话 B" }))
        XCTAssertEqual(control.efforts[aRequest], .high)
        XCTAssertEqual(control.efforts[bRequest], .max)
        XCTAssertEqual(store.selected?.messages.last?.reasoningEffort, "max")
        first.finish(); second.finish()
        try await waitFor { store.generatingThreadIDs.isEmpty }
        store.select(a)
        XCTAssertEqual(store.selectedEffort, .high)
        XCTAssertEqual(store.selected?.messages.last?.reasoningEffort, "high")
    }

    @MainActor func testEffortChoicesRestorePerModelAndThreadAndUnsupportedValuesStayDefault() async throws {
        let control = ControlledChat(); let id = UUID(); let directory = directory()
        let models = ["gpt-6.1-sol", "gpt-6-luna", "test-model"]
        let store = await fixture(control, id: id, directory: directory, models: models)
        defer { store.stopAll(); try? FileManager.default.removeItem(at: directory) }
        store.selectEffort(.none); XCTAssertEqual(store.selectedEffort, .automatic)
        store.selectEffort(.high); store.updateDraft("保留 A"); let a = try XCTUnwrap(store.selected)
        store.selectModel("gpt-6-luna"); store.selectEffort(.none)
        store.selectModel("gpt-6.1-sol"); XCTAssertEqual(store.selectedEffort, .high)
        store.selectModel("test-model"); XCTAssertEqual(store.selectedEffort, .automatic)
        store.selectEffort(.max); XCTAssertEqual(store.selectedEffort, .automatic)
        store.selectModel("gpt-6-luna"); XCTAssertEqual(store.selectedEffort, ReasoningEffort.none)
        store.newThread(); store.selectEffort(.low); store.updateDraft("保留 B"); store.flushDrafts()
        let restored = await fixture(control, id: id, directory: directory, models: models)
        defer { restored.stopAll() }
        XCTAssertEqual(restored.selectedEffort, .low)
        restored.select(a)
        XCTAssertEqual(restored.selectedModel, "gpt-6-luna")
        XCTAssertEqual(restored.selectedEffort, ReasoningEffort.none)
        restored.selectEffort(.automatic); restored.selectModel("gpt-6.1-sol")
        XCTAssertEqual(restored.selectedEffort, .high)
        restored.selectModel("gpt-6-luna"); XCTAssertEqual(restored.selectedEffort, .automatic)
    }

    @MainActor func testRegenerationAndEditedBranchSendNewEffortWithoutRewritingOldVersions() async throws {
        let control = ControlledChat(); let first = control.channel(); let second = control.channel(); let third = control.channel()
        let directory = directory(); let store = await fixture(control, directory: directory, models: ["gpt-6.1-sol"])
        defer { store.stopAll(); try? FileManager.default.removeItem(at: directory) }
        store.selectEffort(.low); XCTAssertTrue(store.send("原问题")); first.yield("第一版"); first.finish()
        try await waitFor { !store.isSending }
        let userID = try XCTUnwrap(store.selected?.messages.first?.id)
        let originalID = try XCTUnwrap(store.selectedID)
        store.selectEffort(.high); store.retry(); second.yield("第二版"); second.finish()
        try await waitFor { !store.isSending }
        let reply = try XCTUnwrap(store.selected?.messages.last)
        XCTAssertEqual(reply.versions?.map(\.reasoningEffort), ["low", "high"])
        store.chooseVersion(messageID: reply.id, index: 0)
        XCTAssertEqual(store.selected?.messages.last?.reasoningEffort, "low")
        XCTAssertEqual(store.selectedEffort, .high)
        store.selectEffort(.max); XCTAssertTrue(store.editAndSend(userID, text: "修改后的问题")); third.finish()
        try await waitFor { !store.isSending }
        XCTAssertEqual(control.efforts, [.low, .high, .max])
        XCTAssertEqual(store.selected?.parentID, originalID)
        XCTAssertEqual(store.selected?.messages.last?.reasoningEffort, "max")
        XCTAssertEqual(store.threads.first(where: { $0.id == originalID })?.messages.last?.text, "第一版")
    }
}

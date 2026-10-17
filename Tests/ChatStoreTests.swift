import XCTest
@testable import LiaoChat

@MainActor private final class ControlledChat {
    var streams: [AsyncThrowingStream<String, Error>] = []
    var histories: [[ChatMessage]] = []
    var delivered = 0
    func channel() -> AsyncThrowingStream<String, Error>.Continuation {
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        streams.append(AsyncThrowingStream { continuation = $0 })
        return continuation
    }
    func run(_ model: String, _ history: [ChatMessage], _ delta: @escaping (String) -> Void) async throws {
        guard !streams.isEmpty else { throw AppFailure.message("Missing synthetic stream") }
        let stream = streams.removeFirst(); histories.append(history)
        for try await text in stream { delta(text); delivered += 1 }
    }
}

final class ChatStoreTests: XCTestCase {
    @MainActor private func fixture(_ control: ControlledChat, id: UUID = UUID(), directory: URL) async -> ChatStore {
        let connection = APIConnection(name: "Synthetic", baseURL: "https://example.com/v1",
                                       apiKey: "synthetic-key", modelIDs: ["test-model"])
        let store = ChatStore(accountID: id, auth: AuthManager(), apiConnection: connection,
            storageDirectory: directory, transport: { model, history, delta in try await control.run(model, history, delta) })
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
}

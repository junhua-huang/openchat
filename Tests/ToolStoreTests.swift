import XCTest
@testable import LiaoChat

final class ToolStoreTests: XCTestCase {
    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Synthetic agent did not reach expected state")
    }
    @MainActor func testStopDismissesPendingApprovalAndCannotResumeRemoteCall() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let connection = APIConnection(name: "Synthetic", baseURL: "https://example.com/v1", apiKey: "synthetic", modelIDs: ["m"])
        var finished = false
        let store = ChatStore(accountID: UUID(), auth: AuthManager(), apiConnection: connection, storageDirectory: directory,
            mcpConnections: MCPConnections(memoryOnly: true), agentTransport: { runtime, _ in
                _ = try await runtime.execute(ToolCall(id: "pending", name: "read_webpage", arguments: #"{"url":"https://synthetic.invalid/article"}"#))
                finished = true
            })
        defer { store.stopAll(); try? FileManager.default.removeItem(at: directory) }
        await store.loadModels(); XCTAssertTrue(store.send("读取网页"))
        try await waitFor { store.selectedApproval != nil }
        let id = try XCTUnwrap(store.selectedApproval?.id)
        store.stop(); store.resolveApproval(id, allow: true)
        XCTAssertTrue(store.approvals.isEmpty); XCTAssertFalse(store.isSending)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(finished)
        XCTAssertEqual(store.selected?.messages.last?.status, .cancelled)
        XCTAssertEqual(store.selected?.messages.last?.toolActivities?.last?.state, "cancelled")
    }
    @MainActor func testGeneratedFileSurvivesArchiveAndReplyRegenerationVersions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); let id = UUID()
        let connection = APIConnection(name: "Synthetic", baseURL: "https://example.com/v1", apiKey: "synthetic", modelIDs: ["m"])
        let store = ChatStore(accountID: id, auth: AuthManager(), apiConnection: connection, storageDirectory: directory,
            mcpConnections: MCPConnections(memoryOnly: true), agentTransport: { runtime, delta in
                _ = try await runtime.execute(ToolCall(id: UUID().uuidString, name: "create_file", arguments: #"{"name":"生成.txt","format":"txt","content":"真实附件🙂"}"#))
                delta("文件已生成。")
            })
        defer { store.stopAll(); try? FileManager.default.removeItem(at: directory) }
        await store.loadModels(); XCTAssertTrue(store.send("生成文件")); try await waitFor { !store.isSending }
        let first = try XCTUnwrap(store.selected?.messages.last?.attachments?.first)
        store.retry(); try await waitFor { !store.isSending }
        let reply = try XCTUnwrap(store.selected?.messages.last)
        XCTAssertEqual(reply.versionCount, 2)
        XCTAssertEqual(reply.versions?.first?.attachments?.first?.id, first.id)
        store.chooseVersion(messageID: reply.id, index: 0); store.flushDrafts()
        let restored = ChatStore(accountID: id, auth: AuthManager(), apiConnection: connection, storageDirectory: directory,
                                 mcpConnections: MCPConnections(memoryOnly: true))
        XCTAssertEqual(restored.selected?.messages.last?.attachments?.first?.id, first.id)
        XCTAssertEqual(try restored.fileVault?.data(first), Data("真实附件🙂".utf8))
    }
    @MainActor func testDraftFileBranchesRetainSharedFilesUntilLastReferenceIsDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let connection = APIConnection(name: "Synthetic", baseURL: "https://example.com/v1", apiKey: "synthetic", modelIDs: ["m"])
        let store = ChatStore(accountID: UUID(), auth: AuthManager(), apiConnection: connection, storageDirectory: directory,
            transport: { _, _, _, delta in delta("合成回复") }, mcpConnections: MCPConnections(memoryOnly: true))
        defer { store.stopAll(); try? FileManager.default.removeItem(at: directory) }
        await store.loadModels()
        let source = directory.appendingPathComponent("草稿.txt"); try Data("共享附件".utf8).write(to: source)
        await store.importFiles([source])
        let file = try XCTUnwrap(store.selected?.draftAttachments?.first)
        let original = try XCTUnwrap(store.selectedID)
        store.newThread(); XCTAssertNotEqual(store.selectedID, original)
        store.select(try XCTUnwrap(store.threads.first { $0.id == original }))
        XCTAssertTrue(store.send("")); try await waitFor { !store.isSending }
        let messageID = try XCTUnwrap(store.selected?.messages.first?.id)
        XCTAssertTrue(store.editAndSend(messageID, text: "换个问题")); try await waitFor { !store.isSending }
        let branchID = try XCTUnwrap(store.selectedID)
        XCTAssertEqual(store.selected?.messages.first?.attachments?.first?.id, file.id)
        store.delete([original]); XCTAssertEqual(try store.fileVault?.data(file), Data("共享附件".utf8))
        store.delete([branchID]); XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.fileVault?.url(file)).path))
    }
}

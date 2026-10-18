import XCTest
@testable import LiaoChat

final class WorkingMemoryTests: XCTestCase {
    @MainActor func testPersistenceDisableAndClear() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = WorkingMemoryStore(directory: folder)
        try first.replace("目标：完成国考复习计划", expectedRevision: 0)
        let second = WorkingMemoryStore(directory: folder)
        XCTAssertEqual(second.content.text, first.content.text)
        XCTAssertNotNil(second.context)
        try second.setEnabled(false)
        XCTAssertNil(second.context)
        let disabled = WorkingMemoryStore(directory: folder)
        XCTAssertFalse(disabled.content.enabled)
        try disabled.replace("", expectedRevision: disabled.content.revision)
        XCTAssertNil(disabled.context)
    }

    @MainActor func testConcurrentModelUpdatesCannotOverwriteEachOther() throws {
        let memory = WorkingMemoryStore(memoryOnly: true)
        let captured = memory.content.revision
        try memory.replace("模型 A 的进展", expectedRevision: captured)
        XCTAssertThrowsError(try memory.replace("模型 B 的旧进展", expectedRevision: captured))
        XCTAssertEqual(memory.content.text, "模型 A 的进展")
    }

    @MainActor func testAllChatStoresUseInjectedSharedMemory() throws {
        let memory = WorkingMemoryStore(memoryOnly: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let auth = AuthManager()
        let a = ChatStore(accountID: UUID(), auth: auth, storageDirectory: folder, workingMemory: memory)
        let b = ChatStore(accountID: UUID(), auth: auth, storageDirectory: folder, workingMemory: memory)
        try a.workingMemory.replace("跨模型共享的任务状态", expectedRevision: 0)
        XCTAssertEqual(b.workingMemory.content.text, "跨模型共享的任务状态")
    }

    @MainActor func testMemoryToolsReadUpdateAndRespectDisable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = WorkingMemoryStore(memoryOnly: true)
        let runtime = ToolRuntime(vault: try FileVault(accountID: UUID(), root: root), files: [], servers: [],
            approve: { _, _ in false }, event: { _ in }, workingMemory: memory)
        XCTAssertTrue(try runtime.definitions().contains { $0.name == "update_working_memory" })
        _ = try await runtime.execute(ToolCall(id: "1", name: "update_working_memory",
            arguments: #"{"content":"已完成第一步","expected_revision":0}"#))
        XCTAssertEqual(memory.content.text, "已完成第一步")
        _ = try await runtime.execute(ToolCall(id: "2", name: "update_working_memory",
            arguments: #"{"content":"旧版本覆盖","expected_revision":0}"#))
        XCTAssertEqual(memory.content.text, "已完成第一步")
        try memory.setEnabled(false)
        let disabled = try await runtime.execute(ToolCall(id: "3", name: "read_working_memory", arguments: "{}"))
        XCTAssertTrue(disabled.contains("已关闭"))
        XCTAssertFalse(try runtime.definitions().contains { $0.name == "read_working_memory" })
    }

    @MainActor func testCorruptMemoryIsNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("working-memory.json")
        let original = Data("corrupt fixture".utf8)
        try original.write(to: file)
        let memory = WorkingMemoryStore(directory: folder)
        XCTAssertFalse(memory.ready); XCTAssertNil(memory.context)
        XCTAssertThrowsError(try memory.replace("overwrite", expectedRevision: 0))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}

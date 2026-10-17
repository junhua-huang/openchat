import XCTest
@testable import LiaoChat

final class ConversationTests: XCTestCase {
    func testEditCreatesBranchWithoutChangingOriginalOrKeepingFutureContext() throws {
        let question = ChatMessage(role: .user, text: "旧问题")
        let original = ChatThread(title: "原对话", model: "model-a", messages: [
            question, ChatMessage(role: .assistant, text: "旧答案"), ChatMessage(role: .user, text: "后续问题")
        ], draft: "未发送草稿", isPinned: true)
        let branch = try XCTUnwrap(original.editing(question.id, text: "  新问题🙂  "))
        XCTAssertNotEqual(branch.id, original.id)
        XCTAssertEqual(branch.parentID, original.id)
        XCTAssertEqual(branch.messages.map(\.text), ["新问题🙂"])
        XCTAssertEqual(original.messages.count, 3)
        XCTAssertEqual(original.draft, "未发送草稿")
        XCTAssertNil(branch.draft)
        XCTAssertNil(branch.isPinned)
    }
    func testEditingRejectsEmptyAssistantAndUnknownMessages() {
        let assistant = ChatMessage(role: .assistant, text: "回答")
        let user = ChatMessage(role: .user, text: "问题")
        let thread = ChatThread(messages: [user, assistant])
        XCTAssertNil(thread.editing(assistant.id, text: "修改"))
        XCTAssertNil(thread.editing(user.id, text: " \n "))
        XCTAssertNil(thread.editing(UUID(), text: "修改"))
    }
    func testReplyVersionsSurviveSwitchingRegenerationAndCodableRoundTrip() throws {
        var message = ChatMessage(role: .assistant, text: "第一版", model: "a")
        message.beginRegeneration(model: "b")
        message.text = "第二版"; message.status = .complete; message.recordVersion()
        XCTAssertTrue(message.chooseVersion(0))
        XCTAssertEqual(message.text, "第一版")
        message.beginRegeneration(model: "c")
        message.text = "部分内容"; message.status = .failed; message.problem = "中断"; message.recordVersion()
        var restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.versionCount, 3)
        XCTAssertTrue(restored.chooseVersion(1))
        XCTAssertEqual(restored.text, "第二版")
        XCTAssertEqual(restored.model, "b")
        XCTAssertEqual(restored.status, .complete)
        XCTAssertNil(restored.problem)
        XCTAssertFalse(restored.chooseVersion(99))
        XCTAssertTrue(restored.chooseVersion(2))
        XCTAssertEqual(restored.problem, "中断")
    }
    func testLegacyArchiveMigratesAndExportExcludesDraftAndDiagnostics() throws {
        let thread = ChatThread(title: "历史", messages: [
            ChatMessage(role: .user, text: "问题"), ChatMessage(role: .assistant, text: "答案", diagnostic: "private diagnostic")
        ], draft: "private draft")
        let legacy = try JSONEncoder().encode([thread])
        let archive = try ChatArchive.decode(legacy)
        XCTAssertEqual(archive.selectedID, thread.id)
        XCTAssertEqual(archive.threads.first?.messages.map(\.text), ["问题", "答案"])
        XCTAssertFalse(thread.markdown.contains("private"))
        XCTAssertTrue(thread.markdown.contains("## 你"))
        let modern = try ChatArchive.decode(JSONEncoder().encode(archive))
        XCTAssertEqual(modern.threads.first?.draft, "private draft")
    }
    func testCorruptArchiveDoesNotBecomeAnEmptyConversation() {
        for input in ["", "not json", #"{"threads":"wrong"}"#, #"{"messages":[]}"#] {
            XCTAssertThrowsError(try ChatArchive.decode(Data(input.utf8)))
        }
    }
}

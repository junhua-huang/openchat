import XCTest
@testable import LiaoChat

final class MarkdownTests: XCTestCase {
    func testHeadingsParagraphsAndSetext() {
        XCTAssertEqual(MessageContent.blocks("# 标题\n\n正文 **重点**\n\n二级标题\n---\n下一段"), [
            .heading(level: 1, text: "标题"), .prose("正文 **重点**"),
            .heading(level: 2, text: "二级标题"), .prose("下一段")
        ])
        XCTAssertEqual(MessageContent.blocks("hello#world\n#not-heading"), [.prose("hello#world\n#not-heading")])
    }
    func testNestedOrderedAndTaskListsWithContinuation() {
        XCTAssertEqual(MessageContent.blocks("- 第一项\n  - 子项\n1. 顺序\n   补充说明\n- [x] 已完成\n- [ ] 待办"), [
            .listItem(depth: 0, marker: "•", text: "第一项", checked: nil),
            .listItem(depth: 1, marker: "•", text: "子项", checked: nil),
            .listItem(depth: 0, marker: "1.", text: "顺序\n补充说明", checked: nil),
            .listItem(depth: 0, marker: "•", text: "已完成", checked: true),
            .listItem(depth: 0, marker: "•", text: "待办", checked: false)
        ])
    }
    func testQuotesRulesAndParagraphsStaySeparate() {
        XCTAssertEqual(MessageContent.blocks("> 引用 **重点**\n> 第二行\n\n* * *\n\n结尾"), [
            .quote("引用 **重点**\n第二行"), .divider, .prose("结尾")
        ])
    }
    func testTablesAlignAndNormalizeUnevenRows() {
        XCTAssertEqual(MessageContent.blocks("| 项目 | 数量 | 备注 |\n| :--- | ---: | :---: |\n| A | 2 |\n| B | 3 | 好 | 多余 |"), [
            .table(headers: ["项目", "数量", "备注"], alignment: [.leading, .trailing, .center],
                   rows: [["A", "2", ""], ["B", "3", "好"]])
        ])
    }
    func testTablePipesInsideCodeOrEscapesDoNotCreateColumns() {
        XCTAssertEqual(MessageContent.tableCells("| A\\|B | \u{0060}x|y\u{0060} | 中文🙂 |"), ["A|B", "\u{0060}x|y\u{0060}", "中文🙂"])
        XCTAssertEqual(MessageContent.blocks("A | B\n-- | ---\n1 | 2"), [.prose("A | B\n-- | ---\n1 | 2")])
    }
    func testCodeFencesProtectMarkdownAndStayReadableWhileStreaming() {
        let ticks = String(repeating: "\u{0060}", count: 3)
        XCTAssertEqual(MessageContent.blocks(ticks + "swift\n# 标题\n- 项目\n| a | b |"), [
            .code(language: "swift", text: "# 标题\n- 项目\n| a | b |")
        ])
    }
}

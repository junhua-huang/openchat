import XCTest
import PDFKit
@testable import LiaoChat

final class FileToolTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    @MainActor func testWordRoundTripPreservesUnicodeParagraphsAndEscapesXML() throws {
        let text = "你好🙂 <标题> & 引号\n第二段"
        let data = try FileFormats.generate(format: "docx", content: text)
        let archive = try DocumentArchive(data)
        XCTAssertNotNil(archive.entries.first { $0.name == "[Content_Types].xml" })
        XCTAssertEqual(try FileFormats.extract(data, ext: "docx").trimmingCharacters(in: .newlines), text)
    }
    @MainActor func testExcelRoundTripKeepsNumbersAndTreatsFormulaLikeStringsAsText() throws {
        let content = #"[["名称","数值"],["中文🙂",3.5],["公式文本","=SUM(A1:A2)"],["空",null]]"#
        let data = try FileFormats.generate(format: "xlsx", content: content)
        let xml = String(data: try DocumentArchive(data).content("xl/worksheets/sheet1.xml"), encoding: .utf8)!
        XCTAssertTrue(xml.contains("t=\"n\"><v>3.5</v>"))
        XCTAssertFalse(xml.contains("<f>"))
        let text = try FileFormats.extract(data, ext: "xlsx")
        XCTAssertTrue(text.contains("[A2] 中文🙂")); XCTAssertTrue(text.contains("[B2] 3.5"))
        XCTAssertTrue(text.contains("=SUM(A1:A2)"))
    }
    @MainActor func testPDFPaginationIncludesLastParagraphInsteadOfClipping() throws {
        let text = (1...250).map { "Line \($0): 原生 PDF document" }.joined(separator: "\n")
        let data = try FileFormats.generate(format: "pdf", content: text)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue((pdf.page(at: pdf.pageCount - 1)?.string ?? "").contains("Line 250"))
    }
    func testDeflatedOfficeArchiveAndCRCValidation() throws {
        let base64 = "UEsDBBQAAAAIABIvUl2WnhIUSwAAAF4AAAARAAAAd29yZC9kb2N1bWVudC54bWyzKbdKyU8uzU3NK1GoyM3JK7Yqt1UqLcqzKleysym3KgARRSCixO7J3gVPl+79MH9mk4JaYm6BtUKUZ4CNPkgGRBaByQIwCTPRDgBQSwECFAMUAAAACAASL1Jdlp4SFEsAAABeAAAAEQAAAAAAAAAAAAAAgAEAAAAAd29yZC9kb2N1bWVudC54bWxQSwUGAAAAAAEAAQA/AAAAegAAAAAA"
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(try FileFormats.extract(data, ext: "docx"), "你好🙂 & ZIP\n")
        var corrupt = try DocumentArchive.make([("a.txt", Data("original".utf8))])
        corrupt[35] ^= 1
        XCTAssertThrowsError(try DocumentArchive(corrupt).content("a.txt"))
        XCTAssertThrowsError(try DocumentArchive.make([("../escape.txt", Data())]))
        XCTAssertThrowsError(try DocumentArchive(Data("not a zip".utf8)))
    }
    @MainActor func testZipGenerationCreatesRealEntriesAndRejectsTraversal() throws {
        let data = try FileFormats.generate(format: "zip", content: #"[{"name":"你好.txt","content":"实际文件🙂"},{"name":"data.csv","content":"a,b\n1,2"}]"#)
        let archive = try DocumentArchive(data)
        XCTAssertEqual(String(data: try archive.content("你好.txt"), encoding: .utf8), "实际文件🙂")
        XCTAssertTrue(try FileFormats.extract(data, ext: "zip").contains("data.csv"))
        XCTAssertThrowsError(try FileFormats.generate(format: "zip", content: #"[{"name":"../x.txt","content":"x"}]"#))
    }
    func testFileVaultScopesPathsAndRetainsImportedText() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try FileVault(accountID: UUID(), root: root); let b = try FileVault(accountID: UUID(), root: root)
        let source = root.appendingPathComponent("输入.txt"); try Data("你好🙂".utf8).write(to: source)
        let file = try a.importFile(source)
        XCTAssertEqual(file.extractedText, "你好🙂"); XCTAssertEqual(try a.data(file), Data("你好🙂".utf8))
        XCTAssertThrowsError(try b.data(file))
        var bad = file; bad.storedName = "../输入.txt"; XCTAssertThrowsError(try a.url(bad))
        a.remove(file); XCTAssertThrowsError(try a.data(file))
    }
    @MainActor func testArithmeticRejectsCodeAndInvalidOperations() throws {
        XCTAssertEqual(try ToolRuntime.calculate("(12 + 3.5) * -2 / 5"), -6.2, accuracy: 0.00001)
        for input in ["1/0", "2+", "process.exit()", "1;print(2)", "nan", "(1+2", "1e999"] {
            XCTAssertThrowsError(try ToolRuntime.calculate(input))
        }
    }
    @MainActor func testRuntimeCreatesFilesAndCannotReadOtherConversationAttachments() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        let foreign = try vault.save(data: Data("private".utf8), name: "private.txt", text: "private")
        var events: [ToolEvent] = []
        let runtime = ToolRuntime(vault: vault, files: [], servers: [], approve: { _, _ in false }, event: { events.append($0) })
        _ = try runtime.definitions()
        let denied = try await runtime.execute(ToolCall(id: "read", name: "read_file", arguments: "{\"file_id\":\"\(foreign.id.uuidString)\"}"))
        XCTAssertTrue(denied.hasPrefix("Tool error:")); XCTAssertFalse(denied.contains("private"))
        let output = try await runtime.execute(ToolCall(id: "create", name: "create_file", arguments: ##"{"name":"结果.md","format":"md","content":"# 真实文件🙂"}"##))
        XCTAssertTrue(output.contains("文件已创建"))
        let file = try XCTUnwrap(runtime.files.first)
        XCTAssertEqual(String(data: try vault.data(file), encoding: .utf8), "# 真实文件🙂")
        XCTAssertTrue(events.contains { if case .file = $0 { return true }; return false })
        let read = try await runtime.execute(ToolCall(id: "read2", name: "read_file", arguments: "{\"file_id\":\"\(file.id.uuidString)\",\"offset\":2,\"length\":4}"))
        XCTAssertTrue(read.contains("真实文件"))
    }
    @MainActor func testRemoteWebReadRequiresApprovalAndRejectsBeforeNetwork() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root); var approvals = 0
        let runtime = ToolRuntime(vault: vault, files: [], servers: [], approve: { _, _ in approvals += 1; return false }, event: { _ in })
        let result = try await runtime.execute(ToolCall(id: "web", name: "read_webpage", arguments: #"{"url":"https://example.com/article"}"#))
        XCTAssertEqual(approvals, 1); XCTAssertTrue(result.contains("用户拒绝"))
        XCTAssertFalse(result.contains("example.com"))
    }
    @MainActor func testRuntimeCanZipExistingBinaryAttachments() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        let original = Data([0,1,2,255,128]); let file = try vault.save(data: original, name: "二进制.bin")
        let runtime = ToolRuntime(vault: vault, files: [file], servers: [], approve: { _, _ in false }, event: { _ in })
        let args = try JSONSerialization.data(withJSONObject: ["name": "打包.zip", "file_ids": [file.id.uuidString]])
        let result = try await runtime.execute(ToolCall(id: "zip", name: "zip_files", arguments: String(data: args, encoding: .utf8)!))
        XCTAssertTrue(result.contains("ZIP 已生成"))
        let generated = try XCTUnwrap(runtime.files.last)
        XCTAssertEqual(try DocumentArchive(vault.data(generated)).content("二进制.bin"), original)
    }
    @MainActor func testMCPDocumentResourcesRemainReadableAfterSaving() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        let data = try FileFormats.generate(format: "docx", content: "MCP 生成文档🙂")
        let file = try XCTUnwrap(ToolRuntime.saveResource(["mimeType": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "blob": data.base64EncodedString()], vault: vault))
        XCTAssertEqual(file.extractedText?.trimmingCharacters(in: .newlines), "MCP 生成文档🙂")
        XCTAssertEqual(try vault.data(file), data)
        let text = try XCTUnwrap(ToolRuntime.saveResource(["text": "MCP 文本", "mimeType": "text/plain"], vault: vault))
        XCTAssertEqual(text.extractedText, "MCP 文本")
        XCTAssertThrowsError(try ToolRuntime.saveResource(["blob": "invalid base64 !"], vault: vault))
    }
}

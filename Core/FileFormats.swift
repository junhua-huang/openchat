import Foundation
import UIKit
import PDFKit

private final class OfficeXML: NSObject, XMLParserDelegate {
    let mode: String
    let shared: [String]
    var text = ""; var strings: [String] = []; var buffer = ""; var capturing = false
    var cellType = ""; var cellName = ""; var size = 0
    var formula = ""; var capturingFormula = false
    init(_ mode: String, shared: [String] = []) { self.mode = mode; self.shared = shared }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "si" || name == "c" { buffer = ""; formula = "" }
        if name == "c" { cellType = attributes["t"] ?? ""; cellName = attributes["r"] ?? "" }
        if name == "t" || (mode == "sheet" && name == "v") { capturing = true }
        if mode == "sheet", name == "f" { capturing = true; capturingFormula = true }
        if mode == "word", name == "tab" { text += "\t" }
        if mode == "word", name == "br" { text += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if Task.isCancelled { parser.abortParsing(); return }
        guard capturing else { return }; size += string.utf8.count
        if size > 2_000_000 { parser.abortParsing(); return }
        if mode == "word" { text += string }
        else if capturingFormula { formula += string }
        else { buffer += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "t" || name == "v" { capturing = false }
        if name == "f" { capturing = false; capturingFormula = false }
        if mode == "word", name == "p" { text += "\n" }
        if mode == "shared", name == "si" { strings.append(buffer) }
        if mode == "sheet", name == "c" {
            let value = cellType == "s" ? (Int(buffer).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? buffer) : buffer
            text += "[" + cellName + "] " + (formula.isEmpty ? value : "=" + formula + " [cached: " + value + "]") + "\t"
        }
        if mode == "sheet", name == "row" { text += "\n" }
    }
    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = self
        let parsed = parser.parse(); try Task.checkCancellation()
        guard parsed, size <= 2_000_000, text.utf8.count <= 2_000_000 else { throw AppFailure.message("文档 XML 无效或提取的文字过多。") }
    }
}

enum FileFormats {
    static let textExtensions = Set(["txt","md","csv","tsv","json","xml","html","htm","css","js","ts","swift","py","c","cpp","h","java","yaml","yml","log","sql","svg"])
    static func extract(_ data: Data, ext: String) throws -> String {
        try Task.checkCancellation()
        if ext == "pdf" {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount <= 200 else { throw AppFailure.message("PDF 无法读取、已加密或超过 200 页。") }
            var text = ""
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                text += "\n[第 \(index + 1) 页]\n" + (pdf.page(at: index)?.string ?? "")
                guard text.utf8.count <= 2_000_000 else { throw AppFailure.message("PDF 文字过多，请拆分文件。") }
            }
            return text
        }
        if ["docx", "xlsx", "zip"].contains(ext) {
            let zip = try DocumentArchive(data)
            if ext == "zip" { return "ZIP 文件目录（未执行内容）：\n" + zip.entries.map { "\($0.name) · \($0.size) bytes" }.joined(separator: "\n") }
            if ext == "docx" {
                let reader = OfficeXML("word"); try reader.parse(zip.content("word/document.xml")); return reader.text
            }
            var shared: [String] = []
            if zip.entries.contains(where: { $0.name == "xl/sharedStrings.xml" }) {
                let reader = OfficeXML("shared"); try reader.parse(zip.content("xl/sharedStrings.xml")); shared = reader.strings
            }
            let sheets = zip.entries.filter { $0.name.hasPrefix("xl/worksheets/") && $0.name.hasSuffix(".xml") }.sorted { $0.name < $1.name }
            guard !sheets.isEmpty, sheets.count <= 32 else { throw AppFailure.message("Excel 工作表为空或过多。") }
            var text = ""
            for sheet in sheets {
                try Task.checkCancellation()
                let reader = OfficeXML("sheet", shared: shared); try reader.parse(zip.content(sheet.name))
                text += "\n[\(sheet.name)]\n" + reader.text
                guard text.utf8.count <= 2_000_000 else { throw AppFailure.message("表格文字过多，请拆分工作簿。") }
            }
            return text
        }
        guard textExtensions.contains(ext), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
              text.utf8.count <= 2_000_000 else { throw AppFailure.message("不支持此格式或编码。可导入图片、PDF、DOCX、XLSX、ZIP 和常见文本文件。") }
        return text
    }
    static func xml(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 }))
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func package(_ files: [(String, String)]) throws -> Data { try DocumentArchive.make(files.map { ($0.0, Data($0.1.utf8)) }) }
    private static let relPrefix = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    @MainActor static func generate(format: String, content: String) throws -> Data {
        if format == "pdf" { return try generatePDF(content) }
        return try generatePortable(format: format, content: content)
    }
    static func generatePortable(format: String, content: String) throws -> Data {
        try Task.checkCancellation()
        guard content.utf8.count <= 500_000 else { throw AppFailure.message("单次生成内容超过 500 KB，请拆分文件。") }
        if textExtensions.contains(format) { return Data(content.utf8) }
        if format == "zip" {
            guard let files = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [[String: String]], !files.isEmpty else {
                throw AppFailure.message("ZIP 内容需为含 name、content 的 JSON 数组。")
            }
            return try DocumentArchive.make(files.map { item in
                guard let name = item["name"], let value = item["content"], FileVault.safeName(name) == name else { throw AppFailure.message("ZIP 子文件名称无效。") }
                return (name, Data(value.utf8))
            })
        }
        if format == "docx" {
            let paragraphs = content.components(separatedBy: "\n").map { "<w:p><w:r><w:t xml:space=\"preserve\">\(xml($0))</w:t></w:r></w:p>" }.joined()
            return try package([
                ("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"),
                ("_rels/.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(relPrefix)officeDocument\" Target=\"word/document.xml\"/></Relationships>"),
                ("word/document.xml", "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(paragraphs)<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/></w:sectPr></w:body></w:document>")])
        }
        if format == "xlsx" {
            guard let rows = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [[Any]], rows.count <= 5000,
                  rows.allSatisfy({ $0.count <= 64 && $0.allSatisfy { $0 is String || $0 is NSNumber || $0 is NSNull } }) else {
                throw AppFailure.message("XLSX 内容需为二维 JSON 数组，最多 5000 行、64 列。")
            }
            let sheet = rows.enumerated().map { row, cells in
                "<row r=\"\(row + 1)\">" + cells.enumerated().map { column, value in
                    var col = column + 1; var letters = ""
                    while col > 0 { col -= 1; letters = String(UnicodeScalar(65 + col % 26)!) + letters; col /= 26 }
                    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                        return "<c r=\"\(letters)\(row + 1)\" t=\"n\"><v>\(number.stringValue)</v></c>"
                    }
                    let text = value is NSNull ? "" : String(describing: value)
                    return "<c r=\"\(letters)\(row + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(text))</t></is></c>"
                }.joined() + "</row>"
            }.joined()
            return try package([
                ("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>"),
                ("_rels/.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(relPrefix)officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"),
                ("xl/workbook.xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(relPrefix.dropLast())\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
                ("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(relPrefix)worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
                ("xl/worksheets/sheet1.xml", "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(sheet)</sheetData></worksheet>")])
        }
        throw AppFailure.message("不支持此生成格式。")
    }
    @MainActor private static func generatePDF(_ content: String) throws -> Data {
        guard content.utf8.count <= 500_000 else { throw AppFailure.message("单次生成内容超过 500 KB，请拆分文件。") }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let storage = NSTextStorage(string: content, attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.black])
        let layout = NSLayoutManager(); storage.addLayoutManager(layout)
        let textContainer = NSTextContainer(size: CGSize(width: 499, height: 746)); textContainer.lineFragmentPadding = 0
        layout.addTextContainer(textContainer)
        // Paginate with separate text containers so text is never clipped or silently dropped.
        var containers = [textContainer]; var ranges = [layout.glyphRange(for: textContainer)]
        while let last = ranges.last, NSMaxRange(last) < layout.numberOfGlyphs {
            guard containers.count < 200, last.length > 0 else { throw AppFailure.message("PDF 页数过多。") }
            let next = NSTextContainer(size: textContainer.size); next.lineFragmentPadding = 0; layout.addTextContainer(next)
            containers.append(next); ranges.append(layout.glyphRange(for: next))
        }
        return renderer.pdfData { context in
            for range in ranges {
                context.beginPage(); UIColor.white.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 595, height: 842))
                layout.drawBackground(forGlyphRange: range, at: CGPoint(x: 48, y: 48))
                layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: 48, y: 48))
            }
        }
    }
}

import Foundation

enum TableAlignment: Equatable { case leading, center, trailing }
enum MessageBlock: Equatable {
    case prose(String)
    case code(language: String, text: String)
    case heading(level: Int, text: String)
    case listItem(depth: Int, marker: String, text: String, checked: Bool?)
    case quote(String)
    case divider
    case table(headers: [String], alignment: [TableAlignment], rows: [[String]])
}

enum MessageContent {
    private static let listPattern = try! NSRegularExpression(pattern: #"^([-+*]|[0-9]{1,9}[.)])\s+(.*)$"#)
    // Fence parsing happens first so Markdown-looking code is never formatted.
    static func blocks(_ text: String) -> [MessageBlock] {
        var result: [MessageBlock] = []
        var lines: [String] = []
        var fence: Character?
        var fenceLength = 0
        var language = ""
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let marker = trimmed.first
            let count = marker.map { first in trimmed.prefix(while: { $0 == first }).count } ?? 0
            if let active = fence {
                if marker == active, count >= fenceLength, trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(.code(language: language, text: lines.joined(separator: "\n"))); lines = []; fence = nil
                } else { lines.append(line) }
            } else if (marker == "\u{0060}" || marker == "~"), count >= 3 {
                result += proseBlocks(lines); lines = []; fence = marker; fenceLength = count
                language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
            } else { lines.append(line) }
        }
        if fence != nil { result.append(.code(language: language, text: lines.joined(separator: "\n"))) }
        else { result += proseBlocks(lines) }
        return result
    }

    private static func proseBlocks(_ lines: [String]) -> [MessageBlock] {
        var result: [MessageBlock] = []
        var paragraph: [String] = []
        func emitParagraph() {
            if !paragraph.isEmpty { result.append(.prose(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trim = line.trimmingCharacters(in: .whitespaces)
            if trim.isEmpty { emitParagraph(); i += 1; continue }
            if i + 1 < lines.count, trim.contains("|"), let alignment = tableSeparator(lines[i + 1]) {
                let headers = tableCells(trim)
                if headers.count == alignment.count {
                    emitParagraph(); i += 2
                    var rows: [[String]] = []
                    while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        var cells = tableCells(lines[i])
                        if cells.count < headers.count { cells += Array(repeating: "", count: headers.count - cells.count) }
                        rows.append(Array(cells.prefix(headers.count))); i += 1
                    }
                    result.append(.table(headers: headers, alignment: alignment, rows: rows)); continue
                }
            }
            let hashes = trim.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trim.dropFirst(hashes).first?.isWhitespace == true {
                emitParagraph()
                result.append(.heading(level: hashes, text: String(trim.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }
            if i + 1 < lines.count {
                let underline = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if underline.count >= 3, underline.allSatisfy({ $0 == "=" }) || (underline.count >= 3 && underline.allSatisfy({ $0 == "-" })) {
                    emitParagraph(); result.append(.heading(level: underline.first == "=" ? 1 : 2, text: trim)); i += 2; continue
                }
            }
            let rule = trim.filter { !$0.isWhitespace }
            if rule.count >= 3, let first = rule.first, "-*_".contains(first), rule.allSatisfy({ $0 == first }) {
                emitParagraph(); result.append(.divider); i += 1; continue
            }
            if trim.hasPrefix(">") {
                emitParagraph(); var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let value = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    quoted.append(value.hasPrefix(" ") ? String(value.dropFirst()) : String(value)); i += 1
                }
                result.append(.quote(quoted.joined(separator: "\n"))); continue
            }
            if let item = listItem(line) {
                emitParagraph(); var body = item.text; i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                      listItem(lines[i]) == nil, lines[i].prefix(while: { $0 == " " || $0 == "\t" }).count > item.indent {
                    body += "\n" + lines[i].trimmingCharacters(in: .whitespaces); i += 1
                }
                result.append(.listItem(depth: min(item.indent / 2, 6), marker: item.marker, text: body, checked: item.checked)); continue
            }
            paragraph.append(line); i += 1
        }
        emitParagraph(); return result
    }
    private static func listItem(_ line: String) -> (indent: Int, marker: String, text: String, checked: Bool?)? {
        let trim = line.trimmingCharacters(in: .whitespaces)
        guard let first = trim.first, "-+*0123456789".contains(first),
              let match = listPattern.firstMatch(in: trim, range: NSRange(trim.startIndex..., in: trim)),
              let markerRange = Range(match.range(at: 1), in: trim), let bodyRange = Range(match.range(at: 2), in: trim) else { return nil }
        let marker = String(trim[markerRange]); var body = String(trim[bodyRange]); var checked: Bool?
        if body.hasPrefix("[ ] ") { checked = false; body = String(body.dropFirst(4)) }
        else if body.lowercased().hasPrefix("[x] ") { checked = true; body = String(body.dropFirst(4)) }
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return (indent, ["-", "*", "+"].contains(marker) ? "•" : marker, body, checked)
    }
    private static func tableSeparator(_ line: String) -> [TableAlignment]? {
        let cells = tableCells(line)
        guard !cells.isEmpty, cells.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else { return nil }
        return cells.map { cell in
            if cell.hasPrefix(":"), cell.hasSuffix(":") { return .center }
            return cell.hasSuffix(":") ? .trailing : .leading
        }
    }
    static func tableCells(_ line: String) -> [String] {
        let trim = line.trimmingCharacters(in: .whitespaces); let chars = Array(trim)
        var cells: [String] = []; var cell = ""; var escaped = false; var codeTicks = 0; var i = 0
        while i < chars.count {
            let char = chars[i]
            if escaped { cell.append(char); escaped = false; i += 1; continue }
            if char == "\\" { escaped = true; i += 1; continue }
            if char == "\u{0060}" {
                var count = 1
                while i + count < chars.count, chars[i + count] == char { count += 1 }
                if codeTicks == 0 { codeTicks = count } else if codeTicks == count { codeTicks = 0 }
                cell += String(repeating: "\u{0060}", count: count); i += count; continue
            }
            if char == "|", codeTicks == 0 { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(char) }
            i += 1
        }
        if escaped { cell += "\\" }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if trim.hasPrefix("|"), cells.first == "" { cells.removeFirst() }
        if trim.hasSuffix("|"), cells.last == "" { cells.removeLast() }
        return cells
    }
}

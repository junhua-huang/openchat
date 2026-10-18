import Foundation

struct MathExpression: Equatable {
    let latex: String
    let display: Bool
    let source: String
}

enum MathPart: Equatable {
    case text(String)
    case math(MathExpression)
}

enum MessageMath {
    // Parse before Markdown: its backslash escapes and emphasis would otherwise
    // consume LaTeX commands and subscripts. Never interpret code or link URLs.
    static func parts(_ text: String) -> [MathPart] {
        let chars = Array(text)
        var result: [MathPart] = []
        var start = 0
        var i = 0
        func matches(_ token: [Character], at offset: Int) -> Bool {
            offset + token.count <= chars.count && Array(chars[offset..<(offset + token.count)]) == token
        }
        func escaped(_ offset: Int) -> Bool {
            var j = offset
            while j > 0, chars[j - 1] == "\\" { j -= 1 }
            return (offset - j).isMultiple(of: 2) == false
        }
        while i < chars.count {
            if chars[i] == "`", !escaped(i) {
                var count = 1
                while i + count < chars.count, chars[i + count] == "`" { count += 1 }
                var end = i + count
                var found = false
                while end < chars.count {
                    if chars[end] == "`" {
                        var run = 1
                        while end + run < chars.count, chars[end + run] == "`" { run += 1 }
                        if run == count { i = end + run; found = true; break }
                        end += run
                    } else { end += 1 }
                }
                if !found { i += count }
                continue
            }
            if matches(["]", "("], at: i), !escaped(i) {
                var depth = 1
                i += 2
                while i < chars.count, depth > 0 {
                    if !escaped(i) {
                        if chars[i] == "(" { depth += 1 }
                        if chars[i] == ")" { depth -= 1 }
                    }
                    i += 1
                }
                continue
            }
            var opening: [Character] = []
            var closing: [Character] = []
            var display = false
            if !escaped(i) {
                if matches(["$", "$"], at: i) { opening = ["$", "$"]; closing = opening; display = true }
                else if matches(["\\", "["], at: i) { opening = ["\\", "["]; closing = ["\\", "]"]; display = true }
                else if matches(["\\", "("], at: i) { opening = ["\\", "("]; closing = ["\\", ")"] }
                else if chars[i] == "$", i + 1 < chars.count, !chars[i + 1].isWhitespace {
                    opening = ["$"]; closing = opening
                }
            }
            guard !opening.isEmpty else { i += 1; continue }
            let body = i + opening.count
            var end = body
            var matched: Int?
            while end < chars.count {
                // Single-dollar inline math cannot cross a paragraph/line.
                if opening == ["$"], chars[end] == "\n" { break }
                if matches(closing, at: end), !escaped(end) {
                    let validDollar = opening != ["$"] ||
                        (end > body && !chars[end - 1].isWhitespace &&
                         (end + 1 == chars.count || (!chars[end + 1].isNumber && chars[end + 1] != "$")))
                    if validDollar { matched = end; break }
                }
                end += 1
            }
            guard let end = matched else {
                // Keep unfinished streaming delimiters intact; don't reinterpret
                // the second dollar of an incomplete display opener as inline.
                i += opening.count
                continue
            }
            let latex = String(chars[body..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !latex.isEmpty {
                if start < i { result.append(.text(String(chars[start..<i]))) }
                let next = end + closing.count
                result.append(.math(MathExpression(latex: latex, display: display, source: String(chars[i..<next]))))
                i = next; start = next
            } else { i = end + closing.count }
        }
        if start < chars.count { result.append(.text(String(chars[start...]))) }
        return result
    }
}

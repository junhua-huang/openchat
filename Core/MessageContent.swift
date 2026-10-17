import Foundation

enum MessageBlock: Equatable {
    case prose(String)
    case code(language: String, text: String)
}

enum MessageContent {
    // Unclosed fenced code stays a code block while a reply streams in.
    static func blocks(_ text: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
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
                if marker == active, count >= fenceLength,
                   trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(.code(language: language, text: lines.joined(separator: "\n")))
                    lines = []; fence = nil
                } else { lines.append(line) }
            } else if (marker == "`" || marker == "~"), count >= 3 {
                if !lines.isEmpty { blocks.append(.prose(lines.joined(separator: "\n"))); lines = [] }
                fence = marker; fenceLength = count
                language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
            } else { lines.append(line) }
        }
        if fence != nil { blocks.append(.code(language: language, text: lines.joined(separator: "\n"))) }
        else if !lines.isEmpty { blocks.append(.prose(lines.joined(separator: "\n"))) }
        return blocks
    }
}

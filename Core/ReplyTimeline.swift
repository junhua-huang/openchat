import Foundation

struct ReplyTimelinePart: Identifiable, Equatable {
    enum Content: Equatable { case text(String), tool(ToolActivity) }
    let id: String
    let content: Content
}

extension ChatMessage {
    var timeline: [ReplyTimelinePart] {
        let anchored = (toolActivities ?? []).enumerated().filter { $0.element.textOffset != nil }.sorted {
            let a = $0.element.textOffset ?? 0; let b = $1.element.textOffset ?? 0
            return a == b ? $0.offset < $1.offset : a < b
        }
        var result: [ReplyTimelinePart] = []
        var position = text.startIndex; var offset = 0
        let count = text.count
        for (_, activity) in anchored {
            let next = max(offset, min(count, activity.textOffset ?? 0))
            let end = text.index(position, offsetBy: next - offset)
            if position < end { result.append(ReplyTimelinePart(id: "text-\(offset)", content: .text(String(text[position..<end])))) }
            result.append(ReplyTimelinePart(id: "tool-" + activity.id, content: .tool(activity)))
            position = end; offset = next
        }
        if position < text.endIndex { result.append(ReplyTimelinePart(id: "text-\(offset)", content: .text(String(text[position...])))) }
        return result
    }
}

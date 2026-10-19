import Foundation

enum ToolPresentation {
    static func title(_ name: String) -> String {
        switch name {
        case "calculate": return "计算"
        case "create_file": return "生成文件"
        case "zip_files": return "打包文件"
        case "read_file": return "读取附件"
        case "read_webpage": return "读取网页"
        case "web_search_call", "search_web": return "联网搜索"
        case "read_working_memory": return "读取工作记忆"
        case "update_working_memory": return "更新工作记忆"
        case "code_interpreter_call": return "Python 分析"
        case "image_generation_call": return "生成图片"
        default: return name
        }
    }
}

enum ReplyProgress: Equatable {
    case approval, paused, tool(String), starting, continuing
    static func current(approval: Bool, paused: Bool, runningTool: String?, hasText: Bool) -> ReplyProgress {
        if approval { return .approval }
        if paused { return .paused }
        if let tool = runningTool { return .tool(tool) }
        return hasText ? .continuing : .starting
    }
    var title: String {
        switch self {
        case .approval: return "等待你确认工具调用"
        case .paused: return "已暂停，返回后继续"
        case .tool(let name): return "正在" + ToolPresentation.title(name) + "…"
        case .starting: return "正在思考与回复…"
        case .continuing: return "正在继续回复…"
        }
    }
}

enum ComposerDraft {
    static func insertingSuggestion(_ suggestion: String, into draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? suggestion : draft + "\n\n" + suggestion
    }
}

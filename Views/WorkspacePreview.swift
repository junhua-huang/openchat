#if DEBUG
import SwiftUI

// Synthetic UI fixtures are excluded from Release and never call an AI service.
struct WorkspacePreview: View {
    @StateObject private var store: ChatStore
    init(auth: AuthManager) { _store = StateObject(wrappedValue: Self.makeStore(auth: auth)) }
    var body: some View { ChatWorkspaceView(store: store) }
    @MainActor private static func makeStore(auth: AuthManager) -> ChatStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenChat-UI-" + UUID().uuidString)
        let connection = APIConnection(name: "ChatGPT", baseURL: "https://example.com/v1", apiKey: "synthetic-preview",
                                       modelIDs: ["GPT-6.1-Sol"])
        let ticks = String(repeating: "\u{0060}", count: 3)
        let answer = """
        ## 让想法变成一个小作品

        先选一个**今天就能完成**的目标，再逐步完善。

        1. 明确要解决的问题。
        2. 做出最小版本，尽早开始体验。

        | 阶段 | 目标 |
        | :--- | :--- |
        | 今天 | 完成核心流程 |
        | 明天 | 收集真实反馈 |

        > 每次只改进一个最影响体验的问题。

        \(ticks)swift
        let idea = "从一个问题开始"
        print(idea)
        \(ticks)
        """
        let empty = ProcessInfo.processInfo.arguments.contains("--ui-empty")
        let thread = ChatThread(title: empty ? "新对话" : "从想法到作品", model: "GPT-6.1-Sol",
            messages: empty ? [] : [ChatMessage(role: .user, text: "怎样把一个想法变成作品？"),
                                   ChatMessage(role: .assistant, text: answer)],
            draft: empty ? nil : "帮我把第二步展开讲讲")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(ChatArchive(threads: [thread], selectedID: thread.id))
                .write(to: directory.appendingPathComponent(connection.id.uuidString + ".json"))
        } catch { assertionFailure("Unable to prepare synthetic UI fixture") }
        return ChatStore(accountID: connection.id, auth: auth, apiConnection: connection,
                         storageDirectory: directory, transport: { _, _, delta in delta("这是本地界面预览。") })
    }
}
#endif

#if DEBUG
import SwiftUI

// Synthetic UI fixtures are excluded from Release and never call an AI service.
struct WorkspacePreview: View {
    @StateObject private var store: ChatStore
    init(auth: AuthManager) { _store = StateObject(wrappedValue: Self.makeStore(auth: auth)) }
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--ui-models") {
            ModelPickerView(store: store) { store.selectModel($0) }.task { await store.loadModels() }
        } else if ProcessInfo.processInfo.arguments.contains("--ui-mcp") {
            NavigationStack {
                MCPDiscoveryView(connections: store.mcpConnections, client: MCPRegistryClient(transport: { request in
                    let data = Data(#"{"servers":[{"server":{"name":"io.synthetic/docs","title":"测试文档服务","description":"仅用于离线界面验证","remotes":[{"type":"streamable-http","url":"https://catalog.synthetic.invalid/mcp"}]}}]}"#.utf8)
                    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
                }))
            }
        } else if ProcessInfo.processInfo.arguments.contains("--ui-tools") {
            ToolsSettingsView(store: store)
        } else if ProcessInfo.processInfo.arguments.contains("--ui-approval") {
            ToolApprovalView(approval: ToolApproval(threadID: UUID(), runID: UUID(), name: "示例 MCP / 搜索",
                arguments: "{\n  \"query\": \"原生 iOS 文件预览\"\n}")) { _ in }
        } else { ChatWorkspaceView(store: store) }
    }
    @MainActor private static func makeStore(auth: AuthManager) -> ChatStore {
        // Keep synthetic exports in the app container while the capture script
        // switches between processes; temporary locations can be purged/remapped.
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("OpenChat-UI-" + UUID().uuidString)
        let connection = APIConnection(name: "OpenAI API", baseURL: "https://api.openai.com/v1", apiKey: "synthetic-preview",
                                       modelIDs: ["gpt-6.1-sol"])
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
        var thread = ChatThread(title: empty ? "新对话" : "从想法到作品", model: "gpt-6.1-sol",
            messages: empty ? [] : [ChatMessage(role: .user, text: "怎样把一个想法变成作品？"),
                                   ChatMessage(role: .assistant, text: answer)],
            draft: empty ? nil : "帮我把第二步展开讲讲", reasoningEfforts: ["gpt-6.1-sol": "high"])
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if ProcessInfo.processInfo.arguments.contains("--ui-files") {
                let vault = try FileVault(accountID: connection.id, root: directory.appendingPathComponent("files"))
                let file = try vault.save(data: FileFormats.generate(format: "pdf", content: "行动计划\n\n今天：完成核心流程。\n明天：收集真实反馈。"), name: "行动计划.pdf", text: "行动计划")
                _ = try vault.save(data: FileFormats.generate(format: "docx", content: "OpenChat 文档🙂\n第二段"), name: "示例.docx")
                _ = try vault.save(data: FileFormats.generate(format: "xlsx", content: #"[["项目","金额"],["示例",12.5]]"#), name: "示例.xlsx")
                _ = try vault.save(data: FileFormats.generate(format: "zip", content: #"[{"name":"hello.txt","content":"native ZIP 你好🙂"}]"#), name: "示例.zip")
                let source = try vault.save(data: Data("# 我的需求\n做一个原生应用。".utf8), name: "需求.md", text: "# 我的需求\n做一个原生应用。")
                thread.messages = [ChatMessage(role: .user, text: "把计划整理成 PDF 文件。"),
                    ChatMessage(role: .assistant, text: "已经整理成 PDF。点击文件卡片可预览，通过分享按钮保存到「文件」。",
                        attachments: [file], toolActivities: [ToolActivity(id: "synthetic-file", name: "create_file", state: "complete", detail: "文件已保存到本机")])]
                thread.draft = "再分析一下这个需求"; thread.draftAttachments = [source]
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-timeline") {
                let before = "先计算 1 + 1。\n\n"
                let middle = "结果是 2。\n\n接着检索公开资料。\n\n"
                thread.messages = [ChatMessage(role: .user, text: "展示工具执行顺序"),
                    ChatMessage(role: .assistant, text: before + middle + "这是最终总结，可以在下方重新查看完整工具记录。", toolActivities: [
                        ToolActivity(id: "preview-calc", name: "calculate", state: "complete", detail: "2", textOffset: before.count),
                        ToolActivity(id: "preview-search", name: "search_web", state: "complete", detail: "合成检索结果", textOffset: before.count + middle.count)])]
            }
            try JSONEncoder().encode(ChatArchive(threads: [thread], selectedID: thread.id))
                .write(to: directory.appendingPathComponent(connection.id.uuidString + ".json"))
        } catch { assertionFailure("Unable to prepare synthetic UI fixture") }
        return ChatStore(accountID: connection.id, auth: auth, apiConnection: connection,
                         storageDirectory: directory, transport: { _, history, _, delta in
                             if ProcessInfo.processInfo.arguments.contains("--ui-background") {
                                 delta("开始生成…")
                                 try await Task.sleep(nanoseconds: 8_000_000_000)
                                 delta("回复已在后台完成")
                             } else if ProcessInfo.processInfo.arguments.contains("--ui-scroll") {
                                 for index in 1...12 {
                                     delta("第 \(index) 段：这是一段用于验证流式滚动、键盘收起和输入框高度变化的本地文字。\n\n")
                                     try await Task.sleep(nanoseconds: 90_000_000)
                                 }
                                 delta("滚动验收结束 \(history.count)")
                             } else { delta("这是本地界面预览。") }
                         },
                         mcpConnections: MCPConnections(memoryOnly: true, servers: [MCPServer(name: "示例 MCP", endpoint: "https://synthetic.invalid/mcp")]))
    }
}
#endif

import SwiftUI

struct WorkingMemoryView: View {
    @ObservedObject var memory: WorkingMemoryStore
    @State private var text = ""
    @State private var revision = 0
    @State private var baseline = ""
    @State private var problem: String?
    @State private var confirmClear = false
    @State private var confirmDiscard = false
    @State private var draftTask: Task<Void, Never>?
    @State private var saved = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Toggle("所有模型共享工作记忆", isOn: Binding(get: { memory.content.enabled }, set: { enabled in
                    do {
                        let previous = memory.content.revision
                        try memory.setEnabled(enabled)
                        if revision == previous { revision = memory.content.revision }
                        preserveDraft()
                    } catch { problem = error.localizedDescription }
                })).tint(Palette.switchTint).disabled(!memory.ready)
            } footer: {
                Text("开启后，已保存的记忆会随对话发送给当前使用的 ChatGPT 或 API 服务。切换模型、连接或新建对话后仍可使用。不会读取 ChatGPT 官方记忆。")
            }
            Section {
                TextEditor(text: $text).frame(minHeight: 260).accessibilityIdentifier("memory.editor")
                LabeledContent("字符", value: "\(text.count) / 8000")
                Button("保存记忆") {
                    do {
                        try memory.replace(text, expectedRevision: revision)
                        try memory.discardDraft(); loadSaved(); saved = true; TouchFeedback.tap()
                    }
                    catch { problem = error.localizedDescription }
                }.disabled(!memory.ready || text.count > 8000 || text == memory.content.text)
                if revision != memory.content.revision {
                    Text("记忆已有更新，重新读取后可编辑最新内容。").foregroundStyle(.secondary)
                    Button("放弃草稿并读取最新记忆") { confirmDiscard = true }
                }
            } header: { Text("当前工作记忆") } footer: {
                if saved { Text("已保存，下一次请求生效。") }
                else if text != baseline { Text("编辑草稿会保存在本机，点击保存后才会用于对话。") }
                if let message = memory.draftProblem { Text(message) }
                Text("记录任务目标、已确认事实、决定和下一步。启用工具时，模型可调用本地记忆工具更新进展；更新显示在对话工具记录中。请勿保存密码或 API Key。")
            }.disabled(!memory.ready)
            if !memory.ready {
                Section {
                    Text(memory.problem ?? "记忆未就绪").foregroundStyle(.secondary)
                    Button("重新读取") { memory.reload(); restoreDraft() }
                }
            }
            Section {
                Button("清空工作记忆", role: .destructive) { confirmClear = true }
                    .disabled(!memory.ready || memory.content.text.isEmpty)
            }
        }.scrollContentBackground(.hidden).background(Palette.paper)
            .navigationTitle("共享工作记忆").navigationBarTitleDisplayMode(.inline)
            .onAppear { restoreDraft() }
            .onChange(of: text) { _, _ in
                if text != memory.content.text { saved = false }
                draftTask?.cancel()
                draftTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                    preserveDraft()
                }
            }
            .onDisappear { draftTask?.cancel(); draftTask = nil; preserveDraft() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { preserveDraft() } }
            .onChange(of: memory.content.revision) { _, _ in
                // Preserve a user's unsaved edits when a model updates memory.
                if text == baseline { loadSaved() }
            }
            .alert("工作记忆", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("知道了", role: .cancel) { problem = nil }
            } message: { Text(problem ?? "") }
            .confirmationDialog("清空所有模型共享的工作记忆？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    do { try memory.replace("", expectedRevision: revision); try memory.discardDraft(); loadSaved() }
                    catch { problem = error.localizedDescription }
                }
            }
            .confirmationDialog("放弃未保存的编辑并读取最新记忆？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃编辑", role: .destructive) {
                    do { try memory.discardDraft(); loadSaved() }
                    catch { problem = error.localizedDescription }
                }
            }
    }
    private func loadSaved() { text = memory.content.text; baseline = text; revision = memory.content.revision }
    private func restoreDraft() {
        if let draft = memory.draft { text = draft.text; baseline = draft.baseText; revision = draft.baseRevision }
        else { loadSaved() }
    }
    private func preserveDraft() {
        guard memory.ready else { return }
        do {
            if text == baseline { if memory.draft != nil { try memory.discardDraft() } }
            else { try memory.saveDraft(WorkingMemoryDraft(text: text, baseText: baseline, baseRevision: revision)) }
        } catch { problem = error.localizedDescription }
    }
}

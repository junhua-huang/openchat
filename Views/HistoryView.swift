import SwiftUI

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ChatStore
    let onSelect: (ChatThread) -> Void
    let onNew: () -> Void
    @State private var query = ""
    @State private var renameID: UUID?
    @State private var renameTitle = ""
    @State private var deleting: ChatThread?

    private var results: [ChatThread] {
        store.threads.filter { thread in
            !thread.messages.isEmpty && (query.isEmpty || thread.title.localizedStandardContains(query)
                || thread.messages.contains { $0.text.localizedStandardContains(query) })
        }.sorted { $0.updated > $1.updated }
    }
    private func group(_ thread: ChatThread) -> Int {
        if Calendar.current.isDateInToday(thread.updated) { return 0 }
        let week = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return thread.updated > week ? 1 : 2
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground()
                if results.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("留住值得继续的对话", systemImage: "bubble.left.and.text.bubble.right", description: Text("开始聊天后，对话会保存在这里。"))
                    } else { ContentUnavailableView.search(text: query) }
                } else {
                    List {
                        ForEach(0..<3, id: \.self) { section in
                            let threads = results.filter { group($0) == section }
                            if !threads.isEmpty {
                                Section(["今天", "最近七天", "更早"][section]) {
                                    ForEach(threads) { thread in
                                        Button { TouchFeedback.tap(); onSelect(thread) } label: { row(thread) }
                                            .disabled(store.isSending)
                                            .listRowBackground(Palette.card.opacity(0.72))
                                            .contextMenu {
                                                Button("重命名", systemImage: "pencil") { renameTitle = thread.title; renameID = thread.id }
                                                Button("删除对话", systemImage: "trash", role: .destructive) { deleting = thread }
                                            }
                                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                                Button("删除", role: .destructive) { deleting = thread }.disabled(store.isSending)
                                            }
                                    }
                                }
                            }
                        }
                    }.scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("你的对话").navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "搜索标题与内容")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button { TouchFeedback.tap(); onNew() } label: {
                    Label("开启新对话", systemImage: "square.and.pencil").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(18).liquidSurface(radius: 28, interactive: true)
                }.buttonStyle(.plain).padding(.horizontal, 24).padding(.bottom, 12)
                    .disabled(store.isSending || !store.storageReady)
            }
            .alert("重命名对话", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
                TextField("对话标题", text: $renameTitle)
                Button("取消", role: .cancel) { renameID = nil }
                Button("保存") { if let id = renameID { store.rename(id, to: renameTitle) }; renameID = nil }
                    .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSending)
            }
            .confirmationDialog("删除这段本机对话？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除对话", role: .destructive) { if let thread = deleting { store.delete([thread.id]) }; deleting = nil }
            }
        }.presentationDragIndicator(.visible)
    }
    private func row(_ thread: ChatThread) -> some View {
        HStack(spacing: 14) {
            Image(systemName: thread.id == store.selectedID ? "bubble.left.fill" : "bubble.left")
                .foregroundStyle(thread.id == store.selectedID ? Palette.accent : .secondary).frame(width: 23)
            VStack(alignment: .leading, spacing: 6) {
                Text(thread.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text(thread.messages.last(where: { !$0.text.isEmpty })?.text ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if thread.id == store.selectedID { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent) }
        }.padding(.vertical, 9).accessibilityElement(children: .combine)
            .accessibilityValue(thread.id == store.selectedID ? "当前对话" : "")
    }
}

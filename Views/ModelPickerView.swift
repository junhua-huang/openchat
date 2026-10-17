import SwiftUI

struct ModelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ChatStore
    let onSelect: (String) -> Void
    @State private var query = ""
    private var filtered: [ModelChoice] {
        store.models.filter { query.isEmpty || $0.display_name.localizedStandardContains(query) || $0.slug.localizedStandardContains(query) }
    }
    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground()
                if store.isLoadingModels && store.models.isEmpty { ProgressView("正在获取可用模型…") }
                else {
                    List {
                        Section {
                            ForEach(filtered) { model in
                                Button { onSelect(model.slug) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "sparkles").font(.title3).foregroundStyle(Palette.accent).frame(width: 26)
                                        Text(model.display_name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                        Spacer()
                                        if model.slug == store.selectedModel {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                                        }
                                    }.padding(.vertical, 12)
                                }.disabled(store.isSending)
                                    .listRowBackground(Palette.card.opacity(0.75))
                                    .accessibilityValue(model.slug == store.selectedModel ? "已选择" : "")
                            }
                        } footer: {
                            Text(store.isAPIConnection ? "来自当前 API 连接。手动配置的模型始终保留，刷新可读取服务商的模型列表。" : "列表来自当前 ChatGPT 连接，模型使用受账户与工作空间权限限制。")
                        }
                        if filtered.isEmpty {
                            Section {
                                Text(query.isEmpty ? "暂时没有可用模型。请刷新，或在账户设置中检查连接配置。" : "没有找到匹配的模型。")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.listRowBackground(Palette.card.opacity(0.75))
                        }
                        Section {
                            Button { Task { await store.loadModels(refresh: true) } } label: {
                                Label("刷新模型列表", systemImage: "arrow.clockwise")
                            }.disabled(store.isLoadingModels || store.isSending)
                        }.listRowBackground(Palette.card.opacity(0.75))
                    }.scrollContentBackground(.hidden).refreshable { await store.loadModels(refresh: true) }
                }
            }
            .searchable(text: $query, prompt: "搜索模型")
            .navigationTitle("选择模型").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

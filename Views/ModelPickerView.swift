import SwiftUI

private struct ConnectedModel: Identifiable {
    let connectionID: UUID
    let connectionName: String
    let model: ModelChoice
    let api: APIConnection?
    var id: String { connectionID.uuidString + "|" + model.slug }
}
private struct ModelSource: Identifiable {
    let id: UUID
    let title: String
    let api: APIConnection?
}

struct ModelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var apiConnections: APIConnections
    @ObservedObject var store: ChatStore
    let onSelect: (String) -> Void
    @State private var query = ""
    @State private var catalogs: [UUID: [ModelChoice]] = [:]
    @State private var problems: [UUID: String] = [:]
    @State private var refreshing = false
    @State private var problem: String?
    @AppStorage("modelPicker.favorites.v1") private var favoritesJSON = "[]"
    @AppStorage("modelPicker.recent.v1") private var recentJSON = "[]"

    private var sources: [ModelSource] {
        auth.accounts.filter { $0.tokens?.permitsInference == true }.map {
            ModelSource(id: $0.id, title: "ChatGPT · " + $0.label, api: nil)
        } + apiConnections.connections.map { ModelSource(id: $0.id, title: $0.name, api: $0) }
    }
    private var choices: [ConnectedModel] {
        sources.flatMap { source in
            var seen = Set<String>()
            let models = (catalogs[source.id] ?? []) + (source.api?.modelIDs ?? []).map {
                ModelChoice(slug: $0, display_name: $0, visibility: nil)
            }
            return models.filter { seen.insert($0.slug).inserted }.map {
                ConnectedModel(connectionID: source.id, connectionName: source.title, model: $0, api: source.api)
            }
        }.filter {
            query.isEmpty || $0.model.slug.localizedStandardContains(query) ||
            $0.model.display_name.localizedStandardContains(query) || $0.connectionName.localizedStandardContains(query)
        }
    }
    private func keys(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
    private func json(_ keys: [String]) -> String {
        (try? String(decoding: JSONEncoder().encode(keys), as: UTF8.self)) ?? "[]"
    }
    private var favorites: Set<String> { Set(keys(favoritesJSON)) }
    private var recent: [ConnectedModel] { keys(recentJSON).compactMap { key in choices.first { $0.id == key } } }
    private func isSelected(_ choice: ConnectedModel) -> Bool {
        choice.connectionID == store.connectionID && choice.model.slug == store.selectedModel
    }

    var body: some View {
        NavigationStack {
            List {
                effortSection
                let starred = choices.filter { favorites.contains($0.id) }
                if !starred.isEmpty {
                    Section("收藏") { ForEach(starred) { row($0) } }.listRowBackground(Palette.card.opacity(0.75))
                }
                if !recent.isEmpty {
                    Section("最近使用") { ForEach(Array(recent.prefix(5))) { row($0) } }
                        .listRowBackground(Palette.card.opacity(0.75))
                }
                ForEach(sources) { source in
                    let models = choices.filter { $0.connectionID == source.id }
                    if !models.isEmpty || query.isEmpty {
                        Section {
                            ForEach(models) { row($0) }
                            if let error = problems[source.id] {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                            }
                            if models.isEmpty {
                                Text("暂未加载模型，可刷新列表。").font(.subheadline).foregroundStyle(.secondary)
                            }
                        } header: { Text(source.title) }
                            .listRowBackground(Palette.card.opacity(0.75))
                    }
                }
                if !query.isEmpty && choices.isEmpty {
                    Section { Text("没有找到匹配的模型或连接。").foregroundStyle(.secondary) }
                }
                Section {
                    Button { Task { await refresh(includeAPI: true) } } label: {
                        HStack {
                            Label("刷新所有连接的模型", systemImage: "arrow.clockwise")
                            Spacer()
                            if refreshing { ProgressView() }
                        }
                    }.disabled(refreshing || store.isSending)
                    NavigationLink { APISettingsView() } label: { Label("管理 API 连接", systemImage: "server.rack") }
                    NavigationLink { WorkingMemoryView(memory: store.workingMemory) } label: { Label("共享工作记忆", systemImage: "brain") }
                } footer: {
                    Text("模型名称相同时，按连接区分。切换连接后显示该连接的本机对话；共享工作记忆会随下次请求发送给所选模型。")
                }.listRowBackground(Palette.card.opacity(0.75))
            }.scrollContentBackground(.hidden).background(AmbientBackground())
                .searchable(text: $query, prompt: "搜索所有连接与模型")
                .refreshable { await refresh(includeAPI: true) }
                .navigationTitle("模型与思考强度").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .task {
                    catalogs[store.connectionID] = store.models
                    await refresh(includeAPI: false)
                }
                .alert("切换模型", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                    Button("知道了", role: .cancel) { problem = nil }
                } message: { Text(problem ?? "") }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    private var effortSection: some View {
        Section {
            LabeledContent("当前连接", value: store.connectionName)
            LabeledContent("当前模型", value: store.selectedModel)
            if !store.effortOptions.isEmpty {
                Picker("思考强度", selection: Binding(get: { store.selectedEffort }, set: { store.selectEffort($0) })) {
                    ForEach([ReasoningEffort.automatic] + store.effortOptions) { Text($0.title).tag($0) }
                }.disabled(store.isSending)
            } else { LabeledContent("思考强度", value: "默认") }
            if let connection = store.apiConnection {
                NavigationLink { APIConnectionEditor(connection: connection) } label: {
                    Label("配置此 API 的模型思考档位", systemImage: "slider.horizontal.3")
                }.disabled(store.isSending)
            }
        } header: { Text("当前模型") } footer: {
            Text(store.effortOptions.isEmpty ? "服务商未提供可识别的强度档位。API 可按模型手动设置，默认不发送强度参数。"
                 : "强度按当前对话与模型保存，默认由服务商决定。更高强度通常需要更多时间和用量。")
        }.listRowBackground(Palette.card.opacity(0.75))
    }

    private func row(_ choice: ConnectedModel) -> some View {
        HStack(spacing: 10) {
            Button { select(choice) } label: {
                HStack(spacing: 12) {
                    Image(systemName: choice.api == nil ? "sparkles" : "server.rack").foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(choice.model.display_name).font(.subheadline.weight(.medium))
                        Text(choice.connectionName).font(.caption).foregroundStyle(.secondary)
                    }.foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if isSelected(choice) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent) }
                }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(store.isSending)
                .accessibilityValue(isSelected(choice) ? "已选择" : "")
            Button {
                var values = favorites
                if values.contains(choice.id) { values.remove(choice.id) } else { values.insert(choice.id) }
                favoritesJSON = json(values.sorted())
            } label: {
                Image(systemName: favorites.contains(choice.id) ? "star.fill" : "star")
                    .foregroundStyle(Palette.accent).padding(8)
            }.buttonStyle(.borderless).accessibilityLabel(favorites.contains(choice.id) ? "取消收藏" : "收藏模型")
        }
    }

    private func select(_ choice: ConnectedModel) {
        guard !store.isSending else { return }
        do {
            if choice.connectionID == store.connectionID {
                onSelect(choice.model.slug)
            } else {
                store.flushDrafts()
                apiConnections.requestedModel = (choice.connectionID, choice.model.slug)
                if var connection = choice.api {
                    let original = connection
                    if !connection.modelIDs.contains(choice.model.slug) {
                        connection.modelIDs.append(choice.model.slug)
                    }
                    if let efforts = choice.model.reasoningEfforts {
                        if connection.modelReasoningEfforts == nil { connection.modelReasoningEfforts = [:] }
                        connection.modelReasoningEfforts?[choice.model.slug] = efforts
                    }
                    if connection != original { try apiConnections.save(connection) }
                    try apiConnections.select(connection.id)
                } else {
                    auth.select(choice.connectionID)
                    guard auth.activeID == choice.connectionID else { throw AppFailure.message("ChatGPT 连接未能切换，请检查账户授权。") }
                    try apiConnections.select(nil)
                }
                dismiss()
            }
            recentJSON = json([choice.id] + keys(recentJSON).filter { $0 != choice.id }.prefix(11))
            TouchFeedback.tap()
        } catch { apiConnections.requestedModel = nil; problem = error.localizedDescription }
    }

    private func refresh(includeAPI: Bool) async {
        guard !refreshing, !store.isSending else { return }
        refreshing = true
        defer { refreshing = false }
        for source in sources {
            if source.id == store.connectionID {
                if includeAPI {
                    await store.loadModels(refresh: true)
                    if let error = store.errorText { problems[source.id] = error }
                }
                catalogs[source.id] = store.models
                continue
            }
            if source.api != nil && !includeAPI { continue }
            do {
                let models: [ModelChoice]
                if let connection = source.api { models = try await APIChatClient.models(connection: connection) }
                else {
                    let token = try await auth.accessToken(for: source.id)
                    models = try await ResponsesClient.models(token: token)
                }
                try Task.checkCancellation()
                catalogs[source.id] = models; problems[source.id] = nil
            } catch is CancellationError { return }
            catch { problems[source.id] = error.localizedDescription }
        }
    }
}

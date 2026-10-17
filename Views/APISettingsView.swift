import SwiftUI

struct APISettingsView: View {
    @EnvironmentObject private var apiConnections: APIConnections
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var problem: String?

    var body: some View {
        Form {
            if !apiConnections.isReady {
                Section {
                    Text(apiConnections.errorText ?? "API 钥匙串尚未就绪").foregroundStyle(.secondary)
                    Button("重新读取安全存储") { apiConnections.reload() }
                }
            }
            Section {
                if apiConnections.connections.isEmpty {
                    Label("添加自己的 AI 服务，即可使用 API 聊天。", systemImage: "server.rack")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(apiConnections.connections) { connection in
                    VStack(alignment: .leading, spacing: 13) {
                        NavigationLink {
                            APIConnectionEditor(connection: connection)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(connection.name).font(.headline)
                                Text(connection.host).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            do { try apiConnections.select(connection.id); TouchFeedback.tap(); dismiss() }
                            catch { problem = error.localizedDescription }
                        } label: {
                            Label(apiConnections.activeID == connection.id ? "正在使用" : "使用此连接",
                                  systemImage: apiConnections.activeID == connection.id ? "checkmark.circle.fill" : "bubble.left")
                                .font(.subheadline)
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 7)
                }
                Button { adding = true } label: { Label("添加 API 连接", systemImage: "plus.circle") }
                    .disabled(!apiConnections.isReady)
            } header: { Text("OpenAI 兼容 API") } footer: {
                Text("支持使用 Bearer API Key 的 Chat Completions 文本流式接口。API 费用由所选服务商单独收取，不使用 ChatGPT 套餐额度。")
            }
            Section {
                Label("API Key 保存在设备钥匙串中", systemImage: "key.fill")
                Label("聊天记录按连接分别保存", systemImage: "externaldrive")
            } footer: {
                Text("发送消息时，当前对话上下文会发送给该连接的服务商。仅填写你信任的 HTTPS API 地址。删除连接会移除其密钥，已有本机记录仍保留。")
            }.font(.subheadline)
        }
        .navigationTitle("API 连接").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        .sheet(isPresented: $adding) { NavigationStack { APIConnectionEditor() } }
        .alert("连接提示", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("知道了", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }
}

struct APIConnectionEditor: View {
    @EnvironmentObject private var apiConnections: APIConnections
    @Environment(\.dismiss) private var dismiss
    private let existing: APIConnection?
    @State private var name: String
    @State private var baseURL: String
    @State private var key: String
    @State private var modelText: String
    @State private var available: [ModelChoice] = []
    @State private var fetching = false
    @State private var fetchTask: Task<Void, Never>?
    @State private var problem: String?
    @State private var confirmDelete = false

    init(connection: APIConnection? = nil) {
        existing = connection
        _name = State(initialValue: connection?.name ?? "")
        _baseURL = State(initialValue: connection?.baseURL ?? "")
        _key = State(initialValue: connection?.apiKey ?? "")
        _modelText = State(initialValue: connection?.modelIDs.joined(separator: "\n") ?? "")
    }

    private var draft: APIConnection {
        APIConnection(id: existing?.id ?? UUID(), name: name, baseURL: baseURL, apiKey: key,
                      modelIDs: APIConnection.parseModels(modelText))
    }

    var body: some View {
        Form {
            if existing == nil {
                Section("快速填写地址") {
                    HStack {
                        Button("DeepSeek") { preset("DeepSeek", "https://api.deepseek.com") }
                        Spacer()
                        Button("OpenAI API") { preset("OpenAI API", "https://api.openai.com/v1") }
                    }.buttonStyle(.borderless)
                    Text("也可直接填写其他服务商的 OpenAI 兼容接口。模型 ID 请以服务商控制台为准。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(fetching)
            }
            Section {
                TextField("连接名称", text: $name)
                TextField("https://服务商地址/v1", text: $baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("API 基础地址")
                SecureField("API Key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            } header: { Text("连接信息") } footer: {
                Text("地址填到 API 版本路径，例如 /v1。程序会添加 /chat/completions；若填写了完整端点，会自动整理。")
            }.disabled(fetching)
            Section {
                TextField("每行一个模型 ID，或用逗号分隔", text: $modelText, axis: .vertical)
                    .lineLimit(2...7).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("模型 ID 列表")
                Button(action: fetchModels) {
                    HStack {
                        Label("获取服务商模型列表", systemImage: "arrow.down.circle")
                        Spacer()
                        if fetching { ProgressView() }
                    }
                }.disabled(fetching || baseURL.isEmpty || key.isEmpty)
                ForEach(available) { model in
                    let selected = APIConnection.parseModels(modelText).contains(model.slug)
                    Button {
                        var ids = APIConnection.parseModels(modelText)
                        if selected { ids.removeAll { $0 == model.slug } } else { ids.append(model.slug) }
                        modelText = ids.joined(separator: "\n")
                    } label: {
                        HStack {
                            Text(model.slug).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        }
                    }.buttonStyle(.borderless)
                }
            } header: { Text("可用模型") } footer: {
                Text("获取列表只会调用 /models，不会发送聊天。部分服务不支持此接口，此时直接填写模型 ID 即可。请选支持文本聊天的模型。")
            }
            Section {
                Button("保存连接") { save() }
                    .disabled(fetching || !apiConnections.isReady || (try? draft.validated()) == nil)
            }
            if existing != nil {
                Section { Button("删除此连接", role: .destructive) { confirmDelete = true }.disabled(fetching) }
            }
        }
        .navigationTitle(existing == nil ? "添加 API" : "编辑 API").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if existing == nil { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .onDisappear { fetchTask?.cancel() }
        .onChange(of: baseURL) { _, _ in available = [] }
        .onChange(of: key) { _, _ in available = [] }
        .alert("API 连接提示", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("知道了", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
        .confirmationDialog("删除连接及其 API Key？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除连接", role: .destructive) {
                do { if let existing = existing { try apiConnections.delete(existing.id) }; dismiss() }
                catch { problem = error.localizedDescription }
            }
        }
    }

    private func preset(_ label: String, _ url: String) {
        guard !fetching else { return }
        if baseURL != url { key = ""; modelText = "" }
        name = label; baseURL = url; available = []
    }
    private func save() {
        do { try apiConnections.save(draft); TouchFeedback.tap(); dismiss() }
        catch { problem = error.localizedDescription }
    }
    private func fetchModels() {
        let connection = draft
        fetching = true
        available = []
        fetchTask = Task {
            defer { fetching = false; fetchTask = nil }
            do {
                let result = try await APIChatClient.models(connection: connection)
                try Task.checkCancellation()
                available = result
                if result.isEmpty { problem = "服务商没有返回模型，请手动填写模型 ID。" }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { problem = "获取失败，可手动填写模型 ID。\n" + error.localizedDescription } }
        }
    }
}

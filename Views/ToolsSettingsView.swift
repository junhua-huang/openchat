import SwiftUI

struct ToolsSettingsView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var connections: MCPConnections
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    init(store: ChatStore) { self.store = store; connections = store.mcpConnections }
    private func setting(_ path: WritableKeyPath<ToolSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.toolSettings[keyPath: path] }, set: { value in
            var settings = store.toolSettings; settings[keyPath: path] = value; store.setToolSettings(settings)
        })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("允许模型使用工具", isOn: setting(\.enabled))
                    Toggle("公开网页搜索", isOn: setting(\.allowsPublicSearch)).disabled(!store.toolSettings.enabled)
                    Label("计算、读取当前对话附件、生成文件", systemImage: "iphone")
                    Label("读取公开网页（每次确认）", systemImage: "globe")
                } header: { Text("本次对话") } footer: {
                    Text("公开搜索默认开启，无需 API Key，适用于 ChatGPT 登录和其他 AI 连接。只把搜索词发送给 DuckDuckGo，必要时改用 Bing；不发送聊天记录、附件或模型密钥。公开服务可能受网络或验证码限制；时间筛选仍需核实原文日期。本地工具只读取当前对话附件，长文可分段读取。")
                }.disabled(store.isSending)
                Section {
                    Toggle("OpenAI 内置搜索", isOn: setting(\.webSearch))
                    Toggle("Python 与数据分析", isOn: setting(\.codeInterpreter))
                    Toggle("图片生成", isOn: setting(\.imageGeneration))
                } header: { Text("OpenAI 云端工具") } footer: {
                    Text(store.canUseHostedTools
                        ? "仅通过当前 OpenAI API 连接使用，按服务商规则另行计费。开启内置搜索时优先使用它。Python 会上传当前对话附件至文件服务及容器，上传文件设置 1 小时过期。"
                        : "本区需要官方 OpenAI API 的 Responses 协议连接。上方公开网页搜索可在当前连接使用，也可连接搜索 MCP；不会自动切换到付费 API。")
                }.disabled(!store.canUseHostedTools || store.isSending || !store.toolSettings.enabled)
                Section {
                    if !connections.ready {
                        Text(connections.problem ?? "MCP 安全存储未就绪").font(.caption).foregroundStyle(.secondary)
                        Button("重新读取") { connections.reload() }
                    }
                    ForEach(connections.servers) { server in
                        NavigationLink { MCPServerEditor(connections: connections, existing: server) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(server.name)
                                Text("\(server.enabled ? "已启用" : "未启用") · \(server.tools.count) 个工具")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button { adding = true } label: { Label("添加 MCP 服务器", systemImage: "plus.circle") }.disabled(!connections.ready)
                } header: { Text("MCP 远程工具") } footer: {
                    Text("支持 HTTPS Streamable HTTP，可填写 Bearer Token。工具调用前逐次确认参数。连接保存在钥匙串，添加后可供各 AI 连接使用。暂不支持本机 stdio、旧 SSE 端点或 OAuth 登录。")
                }
            }.scrollContentBackground(.hidden).background(Palette.paper)
                .navigationTitle("工具与 MCP").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $adding) { NavigationStack { MCPServerEditor(connections: connections, existing: nil) } }
        }
    }
}

struct MCPServerEditor: View {
    @ObservedObject var connections: MCPConnections
    let existing: MCPServer?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var endpoint: String
    @State private var token: String
    @State private var enabled: Bool
    @State private var busy = false
    @State private var problem: String?
    @State private var task: Task<Void, Never>?
    @State private var confirmDelete = false
    init(connections: MCPConnections, existing: MCPServer?) {
        self.connections = connections; self.existing = existing
        _name = State(initialValue: existing?.name ?? ""); _endpoint = State(initialValue: existing?.endpoint ?? "")
        _token = State(initialValue: existing?.token ?? ""); _enabled = State(initialValue: existing?.enabled ?? true)
    }
    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name)
                TextField("https://example.com/mcp", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Bearer Token（可选）", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Toggle("启用此连接", isOn: $enabled)
            } footer: { Text("保存前会建立 MCP 会话并获取工具目录。Token 仅发送给此 HTTPS 端点，不跟随重定向。") }.disabled(busy)
            Section {
                Button(action: save) { HStack { Text(enabled ? "连接、获取工具并保存" : "保存为停用连接"); Spacer(); if busy { ProgressView() } } }
                    .disabled(busy || name.isEmpty || endpoint.isEmpty)
                if let problem = problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            }
            if let existing = existing {
                Section("上次获取的工具") {
                    ForEach(existing.tools) { tool in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tool.name).font(.subheadline)
                            Text(tool.description ?? "无说明").font(.caption).foregroundStyle(.secondary).lineLimit(4)
                        }
                    }
                }
                Section { Button("删除此 MCP 连接", role: .destructive) { confirmDelete = true }.disabled(busy) }
            }
        }.navigationTitle(existing == nil ? "添加 MCP" : "编辑 MCP").navigationBarTitleDisplayMode(.inline)
            .toolbar { if existing == nil { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } } }
            .onDisappear { task?.cancel() }
            .confirmationDialog("删除 MCP 连接及凭据？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    do { if let existing = existing { try connections.delete(existing.id) }; dismiss() }
                    catch { problem = error.localizedDescription }
                }
            }
    }
    private func save() {
        busy = true; problem = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                var server = try MCPServer(id: existing?.id ?? UUID(), name: name, endpoint: endpoint, token: token, enabled: enabled).validated()
                if enabled { server.tools = try await MCPClient(server: server).listTools(); try Task.checkCancellation() }
                else if existing?.endpoint == server.endpoint && existing?.token == server.token { server.tools = existing?.tools ?? [] }
                try connections.save(server); dismiss()
            } catch is CancellationError { }
            catch { problem = error.localizedDescription }
        }
    }
}

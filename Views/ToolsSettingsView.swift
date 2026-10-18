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
                    Toggle("允许模型使用工具", isOn: setting(\.enabled)).tint(Palette.switchTint)
                    Toggle("公开网页搜索", isOn: setting(\.allowsPublicSearch)).tint(Palette.switchTint).disabled(!store.toolSettings.enabled)
                    Label("计算、读取当前对话附件、生成文件", systemImage: "iphone")
                    Label("直接读取公开网页", systemImage: "globe")
                } header: { Text("本次对话") } footer: {
                    Text("公开搜索默认开启，无需 API Key，适用于 ChatGPT 登录和其他 AI 连接。只把搜索词发送给 DuckDuckGo，必要时改用 Bing；不发送聊天记录、附件或模型密钥。公开服务可能受网络或验证码限制；时间筛选仍需核实原文日期。本地工具只读取当前对话附件，长文可分段读取。")
                }.disabled(store.isSending)
                Section {
                    NavigationLink { MCPDiscoveryView(connections: connections) } label: {
                        Label("发现 MCP：推荐与搜索", systemImage: "magnifyingglass")
                    }.accessibilityIdentifier("mcp.discover")
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
                    Text("支持 HTTPS Streamable HTTP，支持浏览器 OAuth 登录或 Bearer Token。工具调用前逐次确认参数。连接保存在钥匙串，添加后可供各 AI 连接使用。暂不支持本机 stdio或旧 SSE 端点。")
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
    @State private var oauthEnabled: Bool
    @State private var clientID: String
    @State private var oauth: MCPOAuthCredentials?
    @StateObject private var signIn = MCPOAuthSignIn()
    @State private var busy = false
    @State private var problem: String?
    @State private var task: Task<Void, Never>?
    @State private var confirmDelete = false
    private var needsGitHubToken: Bool { MCPServer.isGitHubEndpoint(endpoint) }
    init(connections: MCPConnections, existing: MCPServer?, prefill: MCPServer? = nil) {
        self.connections = connections; self.existing = existing
        let source = existing ?? prefill
        _name = State(initialValue: source?.name ?? ""); _endpoint = State(initialValue: source?.endpoint ?? "")
        _oauthEnabled = State(initialValue: source?.usesOAuth ?? (source?.oauth != nil || (existing == nil && MCPServer.isGitHubEndpoint(source?.endpoint ?? "") && (source?.token.isEmpty ?? true))))
        _clientID = State(initialValue: source?.oauthClientID ?? source?.oauth?.clientID ?? ""); _oauth = State(initialValue: source?.oauth)
        _token = State(initialValue: source?.token ?? ""); _enabled = State(initialValue: source?.enabled ?? true)
    }
    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name).accessibilityIdentifier("mcp.name")
                TextField("https://example.com/mcp", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("mcp.endpoint")
                Picker("授权方式", selection: $oauthEnabled) {
                    Text("公开访问 / Token").tag(false)
                    Text("OAuth 登录").tag(true)
                }.accessibilityIdentifier("mcp.auth-method")
                if !oauthEnabled {
                SecureField(needsGitHubToken ? "GitHub Personal Access Token（必填）" : "Bearer Token（可选）", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("mcp.token")
                }
                Toggle("启用此连接", isOn: $enabled).tint(Palette.switchTint)
            } footer: { Text("保存前会建立 MCP 会话并获取工具目录。Token 仅发送给此 HTTPS 端点，不跟随重定向。") }.disabled(busy)
            if oauthEnabled {
                Section("OAuth 浏览器登录") {
                    TextField("Client ID（支持动态注册时可留空）", text: $clientID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("mcp.oauth-client-id").disabled(busy)
                    LabeledContent("回调地址") { Text(MCPOAuthSignIn.callbackAddress).font(.caption).textSelection(.enabled) }
                        .accessibilityIdentifier("mcp.oauth-callback")
                    Text("自动发现授权服务器，使用 PKCE 校验登录并安全刷新令牌。不支持动态注册的服务需要先注册公开 OAuth 客户端，并填写 Client ID。此 App 不保存 Client Secret。")
                        .font(.caption).foregroundStyle(.secondary)
                    if oauth != nil {
                        Label("已获得 OAuth 授权", systemImage: "checkmark.shield")
                        Button("重新登录") { oauth = nil; save() }.disabled(busy)
                    }
                    if !signIn.stage.isEmpty { Text(signIn.stage).font(.caption).foregroundStyle(.secondary) }
                    if needsGitHubToken {
                        Text("GitHub 不支持动态注册；需要配置自己的 OAuth 应用。若应用要求 Client Secret，须由可信后端完成交换，也可改用 Token。")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("GitHub OAuth 接入说明", destination: URL(string: "https://github.com/github/github-mcp-server/blob/main/docs/host-integration.md")!)
                    }
                }
            }
            if needsGitHubToken && !oauthEnabled {
                Section("GitHub 授权") {
                    Text("此服务需要 GitHub Personal Access Token。填写令牌本身，无需添加 Bearer 前缀，并按用途选择仓库与访问权限。也可切换为 OAuth 登录，配置自己的公开客户端。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Link("创建 GitHub 访问令牌", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                        .accessibilityIdentifier("mcp.github-token-help")
                }
            }
            Section {
                Button(action: save) { HStack { Text(enabled ? (oauthEnabled && oauth == nil ? "登录并连接" : "连接、获取工具并保存") : "保存为停用连接"); Spacer(); if busy { ProgressView() } } }
                    .disabled(busy || name.isEmpty || endpoint.isEmpty)
                if let problem = problem { Text(problem).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("mcp.connection-error") }
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
        }.scrollDismissesKeyboard(.immediately)
            .navigationTitle(existing == nil ? "添加 MCP" : "编辑 MCP").navigationBarTitleDisplayMode(.inline)
            .toolbar { if existing == nil { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } } }
            .sheet(item: $signIn.browser, onDismiss: { signIn.cancel() }) { item in
                SafariBrowser(url: item.url) { signIn.cancel() }.ignoresSafeArea()
            }
            .onChange(of: endpoint) { _, _ in oauth = nil }
            .onChange(of: clientID) { _, value in if oauth?.clientID != value { oauth = nil } }
            .onDisappear { task?.cancel(); signIn.cancel() }
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
                var server = try MCPServer(id: existing?.id ?? UUID(), name: name, endpoint: endpoint, token: oauthEnabled ? "" : token, enabled: enabled).validated()
                server.usesOAuth = oauthEnabled; server.oauthClientID = oauthEnabled ? clientID : nil
                if oauthEnabled {
                    if let saved = oauth, saved.resource == MCPOAuthClient.canonical(try BoundedHTTP.endpoint(server.endpoint)), saved.clientID == clientID { server.oauth = saved }
                    else if enabled {
                        let credentials = try await signIn.login(endpoint: server.endpoint, clientID: clientID)
                        clientID = credentials.clientID; oauth = credentials; server.oauth = credentials; server.oauthClientID = credentials.clientID
                    }
                }
                if enabled {
                    let client = MCPClient(server: server)
                    defer { Task { await client.disconnect() } }
                    server.tools = try await client.listTools(); server.oauth = client.server.oauth; try Task.checkCancellation()
                }
                else if existing?.endpoint == server.endpoint && existing?.token == server.token { server.tools = existing?.tools ?? [] }
                try connections.save(server); dismiss()
            } catch is CancellationError { }
            catch { problem = error.localizedDescription }
        }
    }
}

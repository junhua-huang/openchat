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
                    Text("添加服务后即可供各 AI 连接使用。需要登录时会打开授权页面；远程工具执行前仍会确认。")
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
    private let preset: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var endpoint: String
    @State private var token: String
    @State private var enabled: Bool
    @State private var mode: MCPAuthorizationMode
    @State private var clientID: String
    @State private var oauth: MCPOAuthCredentials?
    @StateObject private var signIn = MCPOAuthSignIn()
    @State private var advanced = false
    @State private var needsToken = false
    @State private var busy = false
    @State private var problem: String?
    @State private var diagnostic: String?
    @State private var task: Task<Void, Never>?
    @State private var confirmDelete = false

    private var isGitHub: Bool { MCPServer.isGitHubEndpoint(endpoint) }
    private var serviceName: String { MCPConnectionFlow.displayName(name, endpoint: endpoint) }
    private var showsToken: Bool { mode == .token || needsToken || ((isGitHub || !token.isEmpty) && oauth == nil && mode != .oauth) }
    private var canConnect: Bool {
        !busy && !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!enabled || !showsToken || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    init(connections: MCPConnections, existing: MCPServer?, prefill: MCPServer? = nil) {
        self.connections = connections; self.existing = existing
        let source = existing ?? prefill
        preset = !(source?.endpoint.isEmpty ?? true)
        _name = State(initialValue: source?.name ?? ""); _endpoint = State(initialValue: source?.endpoint ?? "")
        _mode = State(initialValue: source?.enabled == false && source?.usesOAuth == true ? .oauth : .automatic)
        _clientID = State(initialValue: source?.oauthClientID ?? source?.oauth?.clientID ?? "")
        _oauth = State(initialValue: source?.oauth)
        _token = State(initialValue: source?.token ?? ""); _enabled = State(initialValue: source?.enabled ?? true)
    }
    var body: some View {
        Form {
            serviceSection
            if showsToken { tokenSection }
            if oauth != nil {
                Section {
                    Label("已获得登录授权", systemImage: "checkmark.shield")
                    Button("重新登录") { oauth = nil; mode = .oauth; connect() }.disabled(busy)
                }
            }
            advancedSection
            if let existing = existing {
                Section {
                    DisclosureGroup("已连接的工具（\(existing.tools.count)）") {
                        ForEach(existing.tools) { tool in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tool.name).font(.subheadline)
                                if let description = tool.description { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            }
                        }
                    }
                    Button("删除此连接", role: .destructive) { confirmDelete = true }.disabled(busy)
                }
            }
        }.scrollContentBackground(.hidden).background(Palette.paper)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(existing == nil ? "添加 MCP" : "编辑 MCP").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { connectionAction }
            .toolbar { if existing == nil { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } } }
            .sheet(item: $signIn.browser, onDismiss: { signIn.cancel() }) { item in
                SafariBrowser(url: item.url) { signIn.cancel() }.ignoresSafeArea()
            }
            .onChange(of: endpoint) { _, _ in oauth = nil; needsToken = false; problem = nil; diagnostic = nil }
            .onChange(of: clientID) { _, value in if oauth?.clientID != value { oauth = nil } }
            .onChange(of: token) { _, value in if !value.isEmpty { oauth = nil }; problem = nil }
            .onChange(of: mode) { _, _ in problem = nil; needsToken = false }
            .onDisappear { task?.cancel(); signIn.cancel() }
            .confirmationDialog("删除 MCP 连接及凭据？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    do { if let existing = existing { try connections.delete(existing.id) }; dismiss() }
                    catch { problem = error.localizedDescription }
                }
            }
    }
    private var serviceSection: some View {
        Section {
            if preset || isGitHub {
                Label(serviceName, systemImage: isGitHub ? "chevron.left.forwardslash.chevron.right" : "network")
                    .font(.headline).accessibilityIdentifier("mcp.service")
            }
            if !preset {
                TextField("粘贴服务器地址", text: $endpoint).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("mcp.endpoint")
            }
            if !showsToken && oauth == nil {
                Button("使用访问令牌") { needsToken = true; problem = nil }
            }
            Text(isGitHub ? "连接后可使用仓库、Issue 等 GitHub 工具。" : "连接后，AI 就能使用此服务提供的工具。")
                .font(.subheadline).foregroundStyle(.secondary)
        } footer: {
            if !showsToken && oauth == nil { Text("如需登录，会自动打开授权页面。") }
        }.disabled(busy)
    }
    private var tokenSection: some View {
        Section {
            SecureField("粘贴访问令牌", text: $token).textContentType(.password)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("mcp.token")
            if isGitHub {
                Link("前往 GitHub 创建令牌", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    .accessibilityIdentifier("mcp.github-token-help")
            }
        } header: { Text("访问令牌") } footer: {
            Text(isGitHub ? "GitHub 目前通过访问令牌连接。创建时只选择需要的仓库和权限；令牌保存在本机钥匙串。" : "此服务需要访问令牌。保存到本机钥匙串，仅用于连接此服务。")
        }.disabled(busy)
    }
    private var advancedSection: some View {
        Section {
            DisclosureGroup("高级设置", isExpanded: $advanced) {
                TextField("名称（可选）", text: $name).accessibilityIdentifier("mcp.name")
                if preset {
                    TextField("服务器地址", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityIdentifier("mcp.endpoint")
                }
                Picker("授权方式", selection: $mode) {
                    ForEach(MCPAuthorizationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("mcp.auth-method")
                if mode == .oauth {
                    TextField("Client ID（可选）", text: $clientID).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityIdentifier("mcp.oauth-client-id")
                    LabeledContent("回调地址") { Text(MCPOAuthSignIn.callbackAddress).font(.caption).textSelection(.enabled) }
                        .accessibilityIdentifier("mcp.oauth-callback")
                }
                Toggle("启用此连接", isOn: $enabled).tint(Palette.switchTint)
                if let diagnostic = diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.accessibilityIdentifier("mcp.advanced")
        }.disabled(busy)
    }
    private var connectionAction: some View {
        VStack(spacing: 10) {
            if let problem = problem {
                Text(problem).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("mcp.connection-error")
            }
            Button(action: connect) {
                HStack(spacing: 10) {
                    if busy { ProgressView().tint(Palette.onAction) }
                    Text(busy ? (signIn.stage.isEmpty ? "正在连接…" : signIn.stage) : (!enabled ? "保存" : mode == .oauth && oauth == nil && !showsToken ? "登录并连接" : "连接"))
                        .font(.headline)
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Palette.action, in: Capsule()).foregroundStyle(Palette.onAction)
            }.buttonStyle(.plain).disabled(!canConnect).opacity(canConnect || busy ? 1 : 0.4)
                .accessibilityIdentifier("mcp.connect")
        }.padding(.horizontal, 20).padding(.vertical, 12).background(Palette.paper)
    }
    private func connect() {
        guard canConnect else { return }
        busy = true; problem = nil; diagnostic = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                let useToken = mode == .token || ((mode == .automatic || needsToken) && !token.isEmpty)
                var server = MCPServer(id: existing?.id ?? UUID(), name: serviceName, endpoint: endpoint,
                    token: useToken ? token : "", enabled: enabled)
                server.usesOAuth = mode == .oauth ? true : nil
                server.oauthClientID = clientID.isEmpty ? nil : clientID
                if !useToken, let saved = oauth, (saved.boundEndpoint ?? saved.resource) == MCPOAuthClient.canonical(try BoundedHTTP.endpoint(server.endpoint)) { server.oauth = saved }
                if existing?.endpoint == server.endpoint && existing?.token == server.token && existing?.oauth == server.oauth { server.tools = existing?.tools ?? [] }
                let connected = try await MCPConnectionFlow.connect(server, mode: useToken ? .token : mode, login: { endpoint, clientID in
                    try await signIn.login(endpoint: endpoint, clientID: clientID)
                })
                try Task.checkCancellation()
                try connections.save(connected); dismiss()
            } catch is CancellationError {
                if !Task.isCancelled { problem = "登录已取消，可以重新连接。" }
            } catch let error as MCPOAuthSetupRequired {
                needsToken = true; diagnostic = error.localizedDescription
                problem = "此服务暂不支持直接登录。请使用服务商提供的访问令牌连接。"
            } catch let error as MCPAuthorizationRequired {
                needsToken = true; diagnostic = error.localizedDescription
                problem = oauth != nil ? "登录已失效，请重新登录。" : "访问令牌未被接受，请检查是否正确或已过期。"
            } catch { problem = error.localizedDescription }
        }
    }
}

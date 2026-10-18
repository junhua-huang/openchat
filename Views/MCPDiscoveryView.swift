import SwiftUI

struct MCPDiscoveryView: View {
    @ObservedObject var connections: MCPConnections
    @StateObject private var discovery: MCPDiscoveryStore
    @State private var query = ""
    @State private var pageTask: Task<Void, Never>?
    @State private var connectableOnly = false
    @State private var communityOnly = false
    init(connections: MCPConnections, client: MCPRegistryClient = MCPRegistryClient()) {
        self.connections = connections; _discovery = StateObject(wrappedValue: MCPDiscoveryStore(client: client))
    }
    var body: some View {
        List {
            Section {
                Toggle("仅显示可直接添加的服务", isOn: $connectableOnly).tint(Palette.switchTint)
                    .accessibilityIdentifier("mcp.discovery-connectable")
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Picker("结果来源", selection: $communityOnly) {
                        Text("全部").tag(false)
                        Text("社区目录").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("mcp.discovery-source")
                }
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    ForEach(MCPRegistryClient.recommendations) { listing in row(listing) }
                } header: { Text("精选推荐") } footer: { Text("推荐地址来自服务商文档。连接前可查看详情；密钥、配额和可用性由各服务商决定。") }
                Section {
                    ForEach(MCPVendorCatalog.entries.filter { !MCPRegistryClient.recommendations.map(\.id).contains($0.id) && (!connectableOnly || $0.canConnect) }) { listing in row(listing) }
                } header: { Text("厂商服务") } footer: { Text("地址和接入要求根据厂商文档整理。能搜索到不代表本 App 已获厂商授权；需要额外配置的服务会在详情说明。") }
                Section("按用途搜索") {
                    ForEach(["搜索", "开发文档", "代码仓库", "网页", "数据库"], id: \.self) { term in
                        Button { query = term } label: { Label(term, systemImage: "magnifyingglass") }
                    }
                }
            } else {
                if !communityOnly && !discovery.vendorEntries.isEmpty {
                    Section("厂商服务") {
                        ForEach(discovery.vendorEntries.filter { !connectableOnly || $0.canConnect }) { listing in row(listing) }
                    }
                }
                Section {
                    ForEach(discovery.entries.filter { !connectableOnly || $0.canConnect }) { listing in row(listing) }
                    if discovery.loading { HStack { ProgressView(); Text("正在搜索 MCP…").foregroundStyle(.secondary) } }
                    if !discovery.loading, ((communityOnly ? [] : discovery.vendorEntries) + discovery.entries).filter({ !connectableOnly || $0.canConnect }).isEmpty, discovery.problem == nil {
                        ContentUnavailableView("没有找到匹配服务", systemImage: "magnifyingglass", description: Text(connectableOnly ? "可关闭筛选，查看需要额外配置的厂商服务。" : "试试厂商英文名、产品名或用途；也可以手动添加服务。"))
                    }
                    if discovery.nextCursor != nil {
                        Button("加载更多") { pageTask = Task { await discovery.more() } }.disabled(discovery.loading)
                    }
                    if let problem = discovery.problem {
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                        Button("重新搜索") { pageTask = Task { await discovery.search(query, debounce: false) } }
                    }
                } header: { Text("更多社区结果 · MCP Registry") } footer: {
                    Text("支持中英文厂商名和用途关键词。更多结果来自 MCP Registry，可能由第三方维护。搜索词会发送给目录，不会发送聊天记录或密钥；厂商列表在离线时仍可搜索。")
                }
            }
        }.scrollContentBackground(.hidden).background(Palette.paper)
            .navigationTitle("发现 MCP").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索厂商、名称或用途，如微软、GitHub")
            .task(id: query) { pageTask?.cancel(); await discovery.search(query) }
            .onDisappear { pageTask?.cancel() }
    }
    private func row(_ listing: MCPListing) -> some View {
        NavigationLink { MCPListingDetail(listing: listing, connections: connections) } label: {
            VStack(alignment: .leading, spacing: 7) {
                if let publisher = listing.publisher {
                    Text(publisher + " · 厂商文档").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Text(listing.title).font(.headline)
                    if connections.servers.contains(where: { $0.endpoint == listing.endpoint }) {
                        Text("已添加").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(listing.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Text(listing.limitation ?? listing.authorization).font(.caption2).foregroundStyle(.secondary)
            }.padding(.vertical, 6)
        }.accessibilityIdentifier("mcp.listing." + listing.id)
    }
}

private struct MCPListingDetail: View {
    let listing: MCPListing
    @ObservedObject var connections: MCPConnections
    @State private var adding = false
    private var existing: MCPServer? { connections.servers.first { $0.endpoint == listing.endpoint } }
    var body: some View {
        Form {
            Section {
                Text(listing.title).font(.title3.weight(.semibold))
                if let publisher = listing.publisher { Text("服务商：" + publisher).font(.subheadline).foregroundStyle(.secondary) }
                Text(listing.summary)
                Text(listing.authorization).font(.caption).foregroundStyle(.secondary)
            }
            if let endpoint = listing.endpoint {
                Section("连接地址") { Text(endpoint).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if let limitation = listing.limitation { Section { Text(limitation).foregroundStyle(.secondary) } }
            Section {
                if listing.canConnect {
                    Button(existing == nil ? "添加连接" : "编辑已有连接") { adding = true }.disabled(!connections.ready)
                } else if listing.requiresCustomEndpoint {
                    Button("填写专属连接地址") { adding = true }.disabled(!connections.ready)
                }
                if let raw = listing.website, let url = URL(string: raw) { Link("查看服务商文档", destination: url) }
            } footer: { Text("支持公开访问、Bearer Token 和兼容的 OAuth 登录。添加时会检查连接和工具目录；工具执行仍需确认，服务商可能另有账户、配额或客户端准入要求。") }
        }.scrollContentBackground(.hidden).background(Palette.paper)
            .navigationTitle("服务详情").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $adding) {
                NavigationStack { MCPServerEditor(connections: connections, existing: existing,
                    prefill: listing.server ?? MCPServer(name: listing.title, endpoint: "", enabled: true)) }
            }
    }
}

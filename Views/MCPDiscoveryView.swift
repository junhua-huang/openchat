import SwiftUI

struct MCPDiscoveryView: View {
    @ObservedObject var connections: MCPConnections
    @StateObject private var discovery: MCPDiscoveryStore
    @State private var query = ""
    @State private var pageTask: Task<Void, Never>?
    init(connections: MCPConnections, client: MCPRegistryClient = MCPRegistryClient()) {
        self.connections = connections; _discovery = StateObject(wrappedValue: MCPDiscoveryStore(client: client))
    }
    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    ForEach(MCPRegistryClient.recommendations) { listing in row(listing) }
                } header: { Text("精选推荐") } footer: { Text("推荐地址来自服务商文档。连接前可查看详情；密钥、配额和可用性由各服务商决定。") }
                Section("按用途搜索") {
                    ForEach(["搜索", "开发文档", "代码仓库", "网页", "数据库"], id: \.self) { term in
                        Button { query = term } label: { Label(term, systemImage: "magnifyingglass") }
                    }
                }
            } else {
                Section {
                    ForEach(discovery.entries) { listing in row(listing) }
                    if discovery.loading { HStack { ProgressView(); Text("正在搜索 MCP…").foregroundStyle(.secondary) } }
                    if !discovery.loading, discovery.entries.isEmpty, discovery.problem == nil {
                        ContentUnavailableView.search(text: query)
                    }
                    if discovery.nextCursor != nil {
                        Button("加载更多") { pageTask = Task { await discovery.more() } }.disabled(discovery.loading)
                    }
                    if let problem = discovery.problem {
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                        Button("重新搜索") { pageTask = Task { await discovery.search(query, debounce: false) } }
                    }
                } header: { Text("官方 MCP Registry") } footer: {
                    Text("按服务名称搜索，可用英文名称或用途关键词。搜索词发送给 MCP Registry；不会发送聊天记录或密钥。目录收录不代表安全认证，连接前请核对服务商与地址。")
                }
            }
        }.scrollContentBackground(.hidden).background(Palette.paper)
            .navigationTitle("发现 MCP").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索名称或用途，如 search、docs")
            .task(id: query) { pageTask?.cancel(); await discovery.search(query) }
            .onDisappear { pageTask?.cancel() }
    }
    private func row(_ listing: MCPListing) -> some View {
        NavigationLink { MCPListingDetail(listing: listing, connections: connections) } label: {
            VStack(alignment: .leading, spacing: 7) {
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
                }
                if let raw = listing.website, let url = URL(string: raw) { Link("查看服务商文档", destination: url) }
            } footer: { Text("添加后会连接此服务并读取工具目录；具体工具调用仍需逐次确认。仅支持公开访问或 Bearer Token，暂不支持 OAuth 登录。") }
        }.scrollContentBackground(.hidden).background(Palette.paper)
            .navigationTitle("服务详情").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $adding) {
                NavigationStack { MCPServerEditor(connections: connections, existing: existing, prefill: listing.server) }
            }
    }
}

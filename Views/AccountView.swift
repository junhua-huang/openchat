import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var apiConnections: APIConnections
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ChatStore
    let onConnect: (UUID?) -> Void
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("hapticFeedback") private var hapticFeedback = true
    @State private var confirmClear = false
    @State private var confirmSignOut = false
    @State private var showingTools = false

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground()
                Form {
                    Section("AI 服务") {
                        Button { showingTools = true } label: { Label("工具与 MCP", systemImage: "wrench.and.screwdriver") }
                        NavigationLink { APISettingsView() } label: {
                            Label("API 连接与服务商", systemImage: "server.rack")
                        }
                        if let connection = store.apiConnection {
                            LabeledContent("正在使用", value: connection.name)
                            Text(connection.host).font(.caption).foregroundStyle(.secondary)
                        }
                    }.listRowBackground(Palette.card.opacity(0.78))
                    if !store.isAPIConnection {
                        Section {
                            HStack(spacing: 16) {
                                Image(systemName: "person.crop.circle.fill").font(.system(size: 45)).foregroundStyle(Palette.accent.gradient)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(auth.activeAccount?.email ?? "ChatGPT 账户").font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Label(auth.activeAccount?.tokens?.permitsInference == true ? "套餐使用已授权" : "尚未授权套餐使用",
                                          systemImage: auth.activeAccount?.tokens?.permitsInference == true ? "checkmark.shield" : "exclamationmark.shield")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 10)
                            Link(destination: URL(string: "https://chatgpt.com/#settings")!) {
                                Label("管理 ChatGPT 用量与授权", systemImage: "arrow.up.right.square")
                            }
                            if let account = auth.activeAccount {
                                Button { onConnect(account.id) } label: { Label("重新连接当前账户", systemImage: "arrow.triangle.2.circlepath") }
                                    .disabled(auth.isBusy)
                            }
                        }.listRowBackground(Palette.card.opacity(0.78))
                    }
                    Section("外观与体验") {
                        Picker("外观", selection: $appearance) {
                            ForEach(AppAppearance.allCases) { option in Text(option.title).tag(option.rawValue) }
                        }
                        Toggle("触感反馈", isOn: $hapticFeedback).tint(Palette.switchTint)
                    }.listRowBackground(Palette.card.opacity(0.78))
                    Section("账户与工作空间") {
                        ForEach(auth.accounts) { account in
                            Button {
                                if account.tokens != nil {
                                    do { try apiConnections.select(nil); auth.select(account.id); dismiss() }
                                    catch { auth.errorText = error.localizedDescription }
                                }
                                else { onConnect(account.id) }
                            } label: {
                                HStack {
                                    Text(account.label).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                    Spacer()
                                    if !store.isAPIConnection, auth.activeID == account.id { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                                }
                            }.disabled(auth.isBusy)
                        }
                        Button { onConnect(nil) } label: { Label("添加 ChatGPT 连接", systemImage: "plus.circle") }.disabled(auth.isBusy)
                    }.listRowBackground(Palette.card.opacity(0.78))
                    Section {
                        LabeledContent("本机对话", value: "\(store.threads.filter { !$0.messages.isEmpty }.count) 段")
                        Button("清空当前连接的聊天记录", role: .destructive) { confirmClear = true }
                            .disabled(auth.isBusy || !store.storageReady)
                    } header: { Text("聊天记录") } footer: {
                        Text("记录按连接分别保存在本机。发送时会把本次对话所需上下文交给当前 AI 服务商，不同步到 ChatGPT 历史记录。")
                    }.listRowBackground(Palette.card.opacity(0.78))
                    if !store.isAPIConnection {
                        Section {
                            Button(role: .destructive) { confirmSignOut = true } label: {
                                HStack { Text("退出当前连接"); Spacer(); if auth.isBusy { ProgressView() } }
                            }.disabled(auth.isBusy)
                        } footer: { Text("退出会清除本机令牌并尝试撤销远程会话，本机聊天记录将保留。") }
                            .listRowBackground(Palette.card.opacity(0.78))
                    }
                    Section {
                        HStack {
                            OpenChatMark(size: 42)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("openchat").font(.system(.subheadline, design: .rounded, weight: .semibold))
                                Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1.2") · 开源客户端")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.leading, 7)
                        }.padding(.vertical, 5)
                        Text("独立开源项目，与 AI 服务商无隶属关系。模型、额度和费用由当前连接的服务商决定。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.listRowBackground(Palette.card.opacity(0.78))
                }.scrollContentBackground(.hidden)
            }
            .navigationTitle("账户与设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showingTools) { ToolsSettingsView(store: store) }
            .confirmationDialog("删除当前连接在本机的全部对话？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("删除全部对话", role: .destructive) { store.clearHistory() }
            }
            .confirmationDialog("退出当前 ChatGPT 连接？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("退出连接", role: .destructive) { Task { await auth.signOut() } }
            }
        }.presentationDragIndicator(.visible)
    }
}

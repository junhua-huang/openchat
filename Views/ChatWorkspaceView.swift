import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

private enum WorkspaceSheet: String, Identifiable { case history, models, settings, tools; var id: String { rawValue } }
private struct ConnectIntent { let accountID: UUID? }
private struct ChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ChatWorkspaceView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var apiConnections: APIConnections
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 28
    @StateObject private var store: ChatStore
    @State private var editingMessage: ChatMessage?
    @State private var sheet: WorkspaceSheet?
    @State private var pendingConnection: ConnectIntent?
    @State private var followOutput = true
    @State private var isNearBottom = true
    @State private var isDragging = false
    @State private var importing = false
    @State private var showingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var showingApproval = false
    @State private var photoLoading = false
    @State private var importTarget: UUID?
    @FocusState private var inputFocused: Bool

    init(accountID: UUID, auth: AuthManager, apiConnection: APIConnection? = nil) {
        _store = StateObject(wrappedValue: ChatStore(accountID: accountID, auth: auth, apiConnection: apiConnection))
    }
    init(store: ChatStore) { _store = StateObject(wrappedValue: store) }
    private var draft: String {
        get { store.selected?.draft ?? "" }
        nonmutating set { store.updateDraft(newValue) }
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(store.selected?.draftAttachments ?? []).isEmpty) && !store.isImporting && !photoLoading
            && store.models.contains(where: { $0.slug == store.selectedModel }) && store.storageReady && store.canUseConnection
    }
    private var modelName: String {
        store.models.first(where: { $0.slug == store.selectedModel })?.display_name
            ?? (store.isLoadingModels ? "加载模型…" : "选择模型")
    }

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: 0) {
                if !store.isAPIConnection, auth.activeAccount?.tokens?.permitsInference == false {
                    notice("请连接并允许使用 ChatGPT 套餐。", icon: "person.crop.circle.badge.exclamationmark") { sheet = .settings }
                }
                if let error = store.errorText {
                    notice(error, icon: "exclamationmark.circle") { store.errorText = nil }
                }
                conversation
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .sheet(item: $sheet, onDismiss: {
            if let intent = pendingConnection {
                pendingConnection = nil
                // A completed connection will select ChatGPT as the active service.
                Task { await auth.connect(accountID: intent.accountID) }
            }
        }) { selected in
            switch selected {
            case .history:
                HistoryView(store: store, onSelect: { thread in
                    store.select(thread); followOutput = true; sheet = nil
                }, onNew: { store.newThread(); followOutput = true; sheet = nil })
            case .models:
                ModelPickerView(store: store) { slug in store.selectModel(slug); TouchFeedback.tap() }
            case .settings:
                AccountView(store: store) { id in
                    pendingConnection = ConnectIntent(accountID: id)
                    sheet = nil
                }
            case .tools: ToolsSettingsView(store: store)
            }
        }
        .sheet(item: $editingMessage) { message in
            MessageEditorView(message: message) { text in
                let sent = store.editAndSend(message.id, text: text)
                if sent { followOutput = true }
                return sent
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): let target = importTarget; Task { await store.importFiles(urls, threadID: target) }
            case .failure(let error): store.errorText = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photos, maxSelectionCount: 4, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            let target = store.selectedID; photoLoading = true
            Task {
                defer { photoLoading = false }
                for item in items {
                    do { if let data = try await item.loadTransferable(type: Data.self) { await store.importPhoto(data, threadID: target) } }
                    catch { store.errorText = "无法读取照片，请重新选择。" }
                }
                photos = []
            }
        }
        .sheet(isPresented: $showingApproval) {
            if let approval = store.selectedApproval {
                ToolApprovalView(approval: approval) { allow in store.resolveApproval(approval.id, allow: allow); showingApproval = false }
            }
        }
        .onChange(of: store.selectedApproval?.id) { _, id in if id == nil { showingApproval = false } }
        .task { await store.loadModels() }
        .onChange(of: auth.activeID) { _, id in
            if id != nil, store.isAPIConnection {
                do { try apiConnections.select(nil) } catch { store.errorText = error.localizedDescription }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { store.flushDrafts() } }
        .onDisappear { store.stopAll() }
    }

    private var header: some View {
        LiquidCluster {
            HStack(spacing: 8) {
                Button { inputFocused = false; sheet = .history; TouchFeedback.tap() } label: { LiquidIcon(name: "sidebar.left") }
                    .accessibilityLabel("历史对话")
                Button { inputFocused = false; sheet = .models; TouchFeedback.tap() } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(modelName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if !store.effortOptions.isEmpty {
                                Text("思考 · " + store.selectedEffort.title).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 12).frame(minHeight: 48)
                        .foregroundStyle(.primary).liquidSurface(radius: 24, interactive: true)
                }.disabled(store.isSending).accessibilityLabel("选择模型与推理强度，当前为 \(modelName)，\(store.selectedEffort.title)").layoutPriority(1)
                Spacer(minLength: 0)
                Button { store.newThread(); followOutput = true; inputFocused = true; TouchFeedback.tap() } label: {
                    LiquidIcon(name: "square.and.pencil")
                }.disabled(!store.storageReady).accessibilityLabel("新建对话")
                Menu {
                    Button("账户与设置", systemImage: "person.crop.circle") { inputFocused = false; sheet = .settings }
                    Button("工具与 MCP", systemImage: "wrench.and.screwdriver") { inputFocused = false; sheet = .tools }
                    if let thread = store.selected, !thread.messages.isEmpty {
                        ShareLink(item: thread.markdown) { Label("分享整段对话", systemImage: "square.and.arrow.up") }
                        Button(thread.isPinned == true ? "取消置顶" : "置顶对话", systemImage: "pin") { store.togglePin(thread.id) }
                    }
                } label: { LiquidIcon(name: "ellipsis") }.accessibilityLabel("更多选项")
            }
        }.buttonStyle(.plain).padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 10)
    }

    private var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                  VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        if store.selected?.messages.isEmpty != false { emptyState }
                        ForEach(store.selected?.messages ?? []) { message in
                            MessageRow(message: message, fileVault: store.fileVault,
                                canRetry: message.role == .assistant && store.selected?.messages.last?.id == message.id && !store.isSending,
                                retry: { followOutput = true; store.retry() },
                                edit: { inputFocused = false; editingMessage = message },
                                chooseVersion: { store.chooseVersion(messageID: message.id, index: $0) }).equatable().id(message.id)
                        }
                    }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 20)
                        .frame(maxWidth: 780).frame(maxWidth: .infinity)
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ChatBottomKey.self, value: geometry.frame(in: .named("chat-scroll")).maxY)
                        })
                  }
                }
                .coordinateSpace(name: "chat-scroll")
                .scrollDismissesKeyboard(.interactively)
                .task {
                    await Task.yield()
                    if store.selected?.messages.isEmpty == false { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .simultaneousGesture(DragGesture().onChanged { value in
                    isDragging = true
                    if value.translation.height > 12 { followOutput = false }
                }.onEnded { _ in isDragging = false; if isNearBottom { followOutput = true } })
                .onPreferenceChange(ChatBottomKey.self) { bottom in
                    isNearBottom = bottom <= viewport.size.height + 65
                    if isNearBottom && !isDragging { followOutput = true }
                }
                .onChange(of: store.selected?.messages.last?.text) { _, _ in
                    if followOutput && !isDragging { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: store.selected?.messages.count) { _, _ in
                    if followOutput { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: store.selectedID) { _, _ in
                    followOutput = true
                    Task { @MainActor in await Task.yield(); proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: inputFocused) { _, focused in
                    if focused && followOutput { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isNearBottom, store.selected?.messages.isEmpty == false {
                        Button {
                            followOutput = true
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: { LiquidIcon(name: "arrow.down") }
                            .accessibilityLabel("回到最新回复").padding(.trailing, 20).padding(.bottom, 12)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            OpenChatMark(size: 58)
            Text("有什么可以帮你？").font(.system(size: titleSize, weight: .semibold)).multilineTextAlignment(.center)
            Text(store.isAPIConnection ? store.connectionName : "从一个问题开始。")
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                suggestion("pencil.and.outline", "写作润色", "让表达更清楚", "帮我润色一段文字，保留我的语气。请让我先发给你。")
                suggestion("lightbulb", "解释概念", "把复杂的说简单", "我想理解一个复杂概念。请先问我是什么，再用生活中的例子解释。")
                suggestion("list.bullet.rectangle", "制定计划", "把想法付诸行动", "帮我把一个想法变成可执行的计划。请先问我这个想法是什么。")
                suggestion("chevron.left.forwardslash.chevron.right", "编程帮助", "一起解决问题", "帮我排查代码问题，请先问我遇到了什么现象、使用的语言和相关代码。")
            }.padding(.top, 16)
        }.padding(.top, 55).padding(.bottom, 30).frame(maxWidth: .infinity)
    }
    private func suggestion(_ icon: String, _ title: String, _ detail: String, _ prompt: String) -> some View {
        Button { draft = prompt; inputFocused = true; TouchFeedback.tap() } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.secondary)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 90, alignment: .leading).padding(16)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.06)))
        }.buttonStyle(.plain)
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if let approval = store.selectedApproval {
                Button { inputFocused = false; showingApproval = true } label: {
                    Label("等待确认：" + approval.name, systemImage: "hand.raised").font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                }.accessibilityLabel("查看待确认的工具调用")
            }
            VStack(alignment: .leading, spacing: 8) {
                if !(store.selected?.draftAttachments ?? []).isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(store.selected?.draftAttachments ?? []) { file in
                                AttachmentCard(file: file, url: try? store.fileVault?.url(file), remove: { store.removeDraftFile(file.id) }).frame(width: 240)
                            }
                        }.padding(.horizontal, 12)
                    }.padding(.top, 12)
                    Text("附件将随问题发送给当前 AI 服务；PDF/Word/Excel 提取文字，图片交给视觉模型。")
                        .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 18)
                }
                TextField("发送消息", text: Binding(get: { draft }, set: { draft = $0 }), axis: .vertical)
                    .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 4 : 8)).focused($inputFocused)
                    .padding(.top, 16).padding(.horizontal, 18)
                    .accessibilityLabel("消息内容").textInputAutocapitalization(.sentences)
                HStack(spacing: 10) {
                    Menu {
                        Button("添加文件", systemImage: "doc.badge.plus") { inputFocused = false; importTarget = store.selectedID; importing = true }
                        Button("选择照片", systemImage: "photo") { inputFocused = false; showingPhotos = true }
                        Button("工具与 MCP", systemImage: "wrench.and.screwdriver") { inputFocused = false; sheet = .tools }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 18, weight: .medium)).frame(width: 32, height: 40)
                    }.disabled(store.isImporting || photoLoading || !store.storageReady).accessibilityLabel("添加附件或工具")
                    Text(store.isImporting || photoLoading ? "正在读取附件…" : store.isSending ? "正在回复" : store.connectionName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if store.toolSettings.enabled {
                        Button { inputFocused = false; sheet = .tools } label: { Image(systemName: "wrench.and.screwdriver").font(.caption).frame(width: 28, height: 36) }
                            .foregroundStyle(.secondary).accessibilityLabel("工具已启用，打开工具设置")
                    }
                    Spacer(minLength: 0)
                    Button(action: sendOrStop) {
                        Image(systemName: store.isSending ? "stop.fill" : "arrow.up")
                            .font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                            .foregroundStyle(Palette.onAction).background(Palette.action, in: Circle())
                    }.disabled(!store.isSending && !canSend).opacity(!store.isSending && !canSend ? 0.35 : 1)
                        .accessibilityLabel(store.isSending ? "停止生成" : "发送消息")
                        .keyboardShortcut(.return, modifiers: .command)
                }.padding(.leading, 18).padding(.trailing, 8).padding(.bottom, 8)
            }.liquidSurface(radius: 28)
            if !inputFocused {
                Text("AI 的回答可能不准确，请核实重要信息。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.buttonStyle(.plain).frame(maxWidth: 780).frame(maxWidth: .infinity)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 7)
    }
    private func sendOrStop() {
        TouchFeedback.tap()
        if store.isSending { store.stop(); return }
        guard canSend else { return }
        followOutput = true
        _ = store.send(draft)
    }
    private func notice(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).foregroundStyle(Palette.accent)
                Text(text).font(.caption).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2)
            }.foregroundStyle(.primary).padding(14)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 5)
    }
}

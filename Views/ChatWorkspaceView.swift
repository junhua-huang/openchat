import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import UIKit

private enum WorkspaceSheet: Identifiable {
    case history, models, settings, tools, edit(ChatMessage), approval(ToolApproval)
    var id: String {
        switch self {
        case .history: return "history"
        case .models: return "models"
        case .settings: return "settings"
        case .tools: return "tools"
        case .edit(let message): return "edit-" + message.id.uuidString
        case .approval(let approval): return "approval-" + approval.id.uuidString
        }
    }
}
private struct ConnectIntent { let accountID: UUID? }
private struct ChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ChatChromeHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, height in height })
    }
}

struct ChatWorkspaceView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var apiConnections: APIConnections
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 28
    @StateObject private var store: ChatStore
    @State private var sheet: WorkspaceSheet?
    @State private var pendingNewConversation = false
    @State private var conversationResetID = UUID()
    @State private var newConversationFocusID: UUID?
    @State private var pendingConnection: ConnectIntent?
    @State private var followOutput = true
    @State private var isNearBottom = true
    @GestureState private var isDragging = false
    @State private var scrollTask: Task<Void, Never>?
    @State private var headerHeight: CGFloat = 66
    @State private var composerHeight: CGFloat = 84
    @State private var importing = false
    @State private var showingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
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
            conversation
        }
        // These overlays leave the scroll viewport intact. Only the individual
        // glass controls intercept touches; there is no full-width bar behind them.
        .overlay(alignment: .top) {
            topControls.background(chromeMeasurement("header"))
        }
        .overlay(alignment: .bottom) {
            composer.id(store.selectedID).background(chromeMeasurement("composer"))
        }
        .onPreferenceChange(ChatChromeHeightKey.self) { heights in
            if let height = heights["header"], height.isFinite, height > 0, abs(headerHeight - height) > 0.5 { headerHeight = height }
            if let height = heights["composer"], height.isFinite, height > 0, abs(composerHeight - height) > 0.5 { composerHeight = height }
        }
        .chatScrollEdgesHidden()
        .sheet(item: $sheet, onDismiss: {
            if pendingNewConversation {
                pendingNewConversation = false
                startNewConversation()
            } else if let intent = pendingConnection {
                pendingConnection = nil
                // A completed connection will select ChatGPT as the active service.
                Task { await auth.connect(accountID: intent.accountID) }
            }
        }) { selected in
            switch selected {
            case .history:
                HistoryView(store: store, onSelect: { thread in
                    store.select(thread); followOutput = true; sheet = nil
                }, onNew: { pendingNewConversation = true; sheet = nil })
            case .models:
                ModelPickerView(store: store) { slug in store.selectModel(slug); TouchFeedback.tap() }
            case .settings:
                AccountView(store: store) { id in
                    pendingConnection = ConnectIntent(accountID: id)
                    sheet = nil
                }
            case .tools: ToolsSettingsView(store: store)
            case .edit(let message):
                MessageEditorView(message: message) { text in
                    let sent = store.editAndSend(message.id, text: text)
                    if sent { followOutput = true }
                    return sent
                }
            case .approval(let approval):
                ToolApprovalView(approval: approval) { allow in
                    store.resolveApproval(approval.id, allow: allow); sheet = nil
                }
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
        .onChange(of: store.selectedApproval?.id) { _, id in
            if id == nil, case .approval = sheet { sheet = nil }
        }
        .task { await store.loadModels() }
        .task(id: newConversationFocusID) {
            guard let request = newConversationFocusID else { return }
            // Let the new composer mount before asking it to become first responder.
            await Task.yield()
            guard !Task.isCancelled, newConversationFocusID == request, sheet == nil else { return }
            inputFocused = true
        }
        .onChange(of: auth.activeID) { _, id in
            if id != nil, store.isAPIConnection {
                do { try apiConnections.select(nil) } catch { store.errorText = error.localizedDescription }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { store.sceneChanged(active: true) }
            else if phase == .background { store.sceneChanged(active: false) }
            else { store.flushDrafts() }
        }
        .onDisappear { scrollTask?.cancel(); scrollTask = nil; store.stopAll() }
    }

    private func chromeMeasurement(_ key: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ChatChromeHeightKey.self, value: [key: geometry.size.height])
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private var topControls: some View {
        VStack(spacing: 0) {
            header
            if !store.isAPIConnection, auth.activeAccount?.tokens?.permitsInference == false {
                notice("请连接并允许使用 ChatGPT 套餐。", icon: "person.crop.circle.badge.exclamationmark") { sheet = .settings }
            }
            if let error = store.errorText {
                notice(error, icon: "exclamationmark.circle") { store.errorText = nil }
            }
        }
    }

    private var header: some View {
        LiquidCluster {
            HStack(spacing: 8) {
                Button { inputFocused = false; sheet = .history; TouchFeedback.tap() } label: { LiquidIcon(name: "sidebar.left") }
                    .contentShape(Rectangle()).accessibilityLabel("历史对话").accessibilityIdentifier("chat.history")
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
                Button(action: startNewConversation) {
                    LiquidIcon(name: "square.and.pencil").contentShape(Rectangle())
                }.disabled(!store.storageReady).accessibilityLabel("新建对话").accessibilityIdentifier("chat.new")
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
                    LazyVStack(alignment: .leading, spacing: 30) {
                        if store.selected?.messages.isEmpty != false { emptyState.id("empty-state") }
                        ForEach(store.selected?.messages ?? []) { message in
                            MessageRow(message: message, fileVault: store.fileVault,
                                canRetry: message.role == .assistant && store.selected?.messages.last?.id == message.id && !store.isSending,
                                retry: { followOutput = true; store.retry() },
                                edit: { inputFocused = false; sheet = .edit(message) },
                                chooseVersion: { store.chooseVersion(messageID: message.id, index: $0) }).equatable().id(message.id)
                        }
                        // This clearance scrolls with the messages. Its bottom is
                        // the scroll target, so the last reply stops above the input.
                        Color.clear.frame(height: composerHeight + 20).id("bottom").accessibilityHidden(true)
                    }.padding(.horizontal, 22).padding(.top, headerHeight + 20)
                        .frame(maxWidth: 780).frame(maxWidth: .infinity)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ChatBottomKey.self, value: geometry.frame(in: .named("chat-scroll")).maxY)
                        })
                }
                // The tall welcome view must not donate its cached scroll offset
                // to the much shorter first exchange. History switches also reset it.
                .id("\(store.selectedID?.uuidString ?? "none")-\(store.selected?.messages.isEmpty != false)-\(conversationResetID)")
                .accessibilityIdentifier("chat.conversation")
                .coordinateSpace(name: "chat-scroll")
                .contentShape(Rectangle())
                .scrollDismissesKeyboard(.immediately)
                .task { requestScroll(proxy) }
                .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() }, including: inputFocused ? .all : .none)
                .simultaneousGesture(DragGesture().updating($isDragging) { _, dragging, _ in dragging = true }.onChanged { value in
                    if inputFocused { dismissKeyboard() }
                    if value.translation.height > 12 { followOutput = false }
                }.onEnded { _ in dismissKeyboard(); if isNearBottom { followOutput = true } })
                .onPreferenceChange(ChatBottomKey.self) { bottom in
                    isNearBottom = bottom <= viewport.size.height + 65
                    if isNearBottom && !isDragging { followOutput = true }
                    requestScroll(proxy)
                }
                .onChange(of: store.selected?.messages.last?.text) { _, _ in
                    requestScroll(proxy)
                }
                .onChange(of: store.selected?.messages.count) { _, _ in
                    requestScroll(proxy)
                }
                .onChange(of: store.selected?.messages.last?.toolActivities) { _, _ in
                    requestScroll(proxy)
                }
                .onChange(of: store.selected?.messages.last?.attachments) { _, _ in
                    requestScroll(proxy)
                }
                .onChange(of: store.selected?.messages.last?.status) { _, _ in requestScroll(proxy) }
                .onChange(of: store.selectedID) { _, _ in
                    followOutput = true
                    scrollTask?.cancel(); scrollTask = nil; requestScroll(proxy)
                }
                .onChange(of: viewport.size.height) { _, _ in requestScroll(proxy) }
                .onChange(of: headerHeight) { _, _ in requestScroll(proxy) }
                .onChange(of: composerHeight) { _, _ in requestScroll(proxy) }
                .onChange(of: inputFocused) { _, _ in requestScroll(proxy) }
                .overlay(alignment: .bottomTrailing) {
                    if !isNearBottom, store.selected?.messages.isEmpty == false {
                        Button {
                            followOutput = true
                            requestScroll(proxy)
                        } label: { LiquidIcon(name: "arrow.down") }
                            .accessibilityLabel("回到最新回复").padding(.trailing, 20).padding(.bottom, composerHeight + 12)
                    }
                }
            }
        }.clipped().contentShape(Rectangle())
    }

    private func requestScroll(_ proxy: ScrollViewProxy) {
        guard followOutput, !isDragging, scrollTask == nil, store.selected?.messages.isEmpty == false else { return }
        // Coalesce streaming updates and wait for message/composer/keyboard layout.
        // Immediate scrollTo during those changes can overshoot estimated lazy rows.
        scrollTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            if followOutput && !isDragging && store.selected?.messages.isEmpty == false {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            scrollTask = nil
        }
    }

    private func dismissKeyboard() {
        inputFocused = false
        // Also resign the UIKit responder: at a scroll boundary, native text
        // selection/keyboard handling can outlive SwiftUI's focus update.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func startNewConversation() {
        guard store.storageReady else { return }
        scrollTask?.cancel(); scrollTask = nil
        inputFocused = false
        store.newThread()
        followOutput = true; isNearBottom = true
        // Reusing an existing blank thread must still reset a previously
        // scrolled welcome page and acknowledge repeated new-chat taps.
        conversationResetID = UUID()
        newConversationFocusID = UUID()
        TouchFeedback.tap()
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
                Button { inputFocused = false; sheet = .approval(approval) } label: {
                    Label("等待确认：" + approval.name, systemImage: "hand.raised").font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                }.accessibilityLabel("查看待确认的工具调用")
            }
                if !(store.selected?.draftAttachments ?? []).isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(store.selected?.draftAttachments ?? []) { file in
                                AttachmentCard(file: file, url: try? store.fileVault?.exportURL(file), remove: { store.removeDraftFile(file.id) }).frame(width: 240)
                            }
                        }.padding(.horizontal, 12)
                    }
                    Text("附件将随问题发送给当前 AI 服务；PDF/Word/Excel 提取文字，图片交给视觉模型。")
                        .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 18)
                }
            LiquidCluster {
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button("添加文件", systemImage: "doc.badge.plus") { inputFocused = false; importTarget = store.selectedID; importing = true }
                        Button("选择照片", systemImage: "photo") { inputFocused = false; showingPhotos = true }
                        Button("工具与 MCP", systemImage: "wrench.and.screwdriver") { inputFocused = false; sheet = .tools }
                    } label: {
                        LiquidIcon(name: "plus")
                    }.disabled(store.isImporting || photoLoading || !store.storageReady).accessibilityLabel("添加附件或工具")
                        .accessibilityIdentifier("chat.add")
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("说点什么…", text: Binding(get: { draft }, set: { draft = $0 }), axis: .vertical)
                            .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 4 : 8)).focused($inputFocused)
                            .padding(.leading, 18).padding(.vertical, 13).frame(maxWidth: .infinity, minHeight: 48)
                            .accessibilityLabel("消息内容").accessibilityIdentifier("chat.composer").textInputAutocapitalization(.sentences)
                    Button(action: sendOrStop) {
                        Image(systemName: store.isSending ? "stop.fill" : "arrow.up")
                            .font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                            .foregroundStyle(Palette.onAction).background(Palette.action, in: Circle())
                    }.disabled(!store.isSending && !canSend).opacity(!store.isSending && !canSend ? 0.35 : 1)
                        .accessibilityLabel(store.isSending ? "停止生成" : "发送消息")
                        .keyboardShortcut(.return, modifiers: .command)
                        .padding(.trailing, 4).padding(.bottom, 4)
                    }.liquidSurface(radius: 26)
                }
            }
            if store.isImporting || photoLoading || store.isWaitingForForeground {
                Text(store.isWaitingForForeground ? "已暂停，返回后继续" : "正在读取附件…")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

import SwiftUI

private enum WorkspaceSheet: String, Identifiable { case history, models, settings; var id: String { rawValue } }
private struct ConnectIntent { let accountID: UUID? }
private struct ChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ChatWorkspaceView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 34
    @StateObject private var store: ChatStore
    @State private var draft = ""
    @State private var sheet: WorkspaceSheet?
    @State private var pendingConnection: ConnectIntent?
    @State private var followOutput = true
    @State private var isNearBottom = true
    @FocusState private var inputFocused: Bool

    init(accountID: UUID, auth: AuthManager) {
        _store = StateObject(wrappedValue: ChatStore(accountID: accountID, auth: auth))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.selectedModel.isEmpty && store.storageReady && !auth.isBusy
            && auth.activeAccount?.tokens?.permitsInference == true
    }
    private var modelName: String {
        store.models.first(where: { $0.slug == store.selectedModel })?.display_name
            ?? (store.isLoadingModels ? "加载模型…" : "选择模型")
    }

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: 0) {
                if auth.activeAccount?.tokens?.permitsInference == false {
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
                Task { await auth.connect(accountID: intent.accountID) }
            }
        }) { selected in
            switch selected {
            case .history:
                HistoryView(store: store, onSelect: { thread in
                    store.select(thread); draft = ""; followOutput = true; sheet = nil
                }, onNew: { store.newThread(); draft = ""; followOutput = true; sheet = nil })
            case .models:
                ModelPickerView(store: store) { slug in store.selectedModel = slug; TouchFeedback.tap(); sheet = nil }
            case .settings:
                AccountView(store: store) { id in
                    pendingConnection = ConnectIntent(accountID: id)
                    sheet = nil
                }
            }
        }
        .task { await store.loadModels() }
        .onDisappear { store.stop() }
    }

    private var header: some View {
        LiquidCluster {
            HStack(spacing: 12) {
                Button { inputFocused = false; sheet = .history; TouchFeedback.tap() } label: { LiquidIcon(name: "sidebar.left") }
                    .accessibilityLabel("历史对话")
                Spacer(minLength: 0)
                Button { inputFocused = false; sheet = .models; TouchFeedback.tap() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkle").foregroundStyle(Palette.accent)
                        Text(modelName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 17).frame(minHeight: 48)
                        .foregroundStyle(.primary).liquidSurface(radius: 24, interactive: true)
                }.disabled(store.isSending).accessibilityLabel("选择模型，当前为 \(modelName)")
                Spacer(minLength: 0)
                Button { inputFocused = false; sheet = .settings; TouchFeedback.tap() } label: { LiquidIcon(name: "person.crop.circle") }
                    .disabled(store.isSending).accessibilityLabel("账户与设置")
            }
        }.buttonStyle(.plain).padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 10)
    }

    private var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        if store.selected?.messages.isEmpty != false { emptyState }
                        ForEach(store.selected?.messages ?? []) { message in
                            MessageRow(message: message, canRetry: store.selected?.messages.last?.id == message.id && !store.isSending) {
                                followOutput = true; store.retry()
                            }.id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: ChatBottomKey.self, value: geometry.frame(in: .named("chat-scroll")).maxY)
                            })
                    }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
                        .frame(maxWidth: 780).frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "chat-scroll")
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture().onChanged { value in
                    if value.translation.height > 12 { followOutput = false }
                })
                .onPreferenceChange(ChatBottomKey.self) { bottom in
                    isNearBottom = bottom <= viewport.size.height + 65
                    if isNearBottom { followOutput = true }
                }
                .onChange(of: store.selected?.messages.last?.text) { _, _ in
                    if followOutput { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: store.selected?.messages.count) { _, _ in
                    if followOutput { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: store.selectedID) { _, _ in
                    followOutput = true; proxy.scrollTo("bottom", anchor: .bottom)
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
        VStack(alignment: .leading, spacing: 24) {
            Text("OPENCHAT").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("你好，\n今天想聊些什么？").font(.system(size: titleSize, weight: .semibold, design: .rounded))
                    .tracking(-1.1).fixedSize(horizontal: false, vertical: true)
                Text("一个问题，一个想法，或只是说说今天。")
                    .font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
            }
            HStack(spacing: 9) {
                Image(systemName: "lock.shield").foregroundStyle(Palette.accent)
                Text("用自己的账户，保留自己的对话").foregroundStyle(.secondary)
            }.font(.caption).padding(.vertical, 8)
            VStack(spacing: 12) {
                suggestion("lightbulb", "让灵感落地", "把脑海里的想法，变成可以开始的计划", "帮我把一个想法变成可执行的计划。请先问我这个想法是什么。")
                suggestion("sparkles", "把复杂的说简单", "换一种容易理解的方式，认识新事物", "我想理解一个复杂概念。请先问我是什么，再用生活中的例子解释。")
                suggestion("pencil.and.outline", "找到更好的表达", "润色文字，也保留自己的声音", "帮我润色一段文字，保留我的语气。请让我先发给你。")
            }.padding(.top, 8)
        }.padding(.top, 24).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func suggestion(_ icon: String, _ title: String, _ detail: String, _ prompt: String) -> some View {
        Button { draft = prompt; inputFocused = true; TouchFeedback.tap() } label: {
            HStack(spacing: 15) {
                Image(systemName: icon).font(.system(size: 21)).foregroundStyle(Palette.accent)
                    .frame(width: 38, height: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain)
    }
    private var composer: some View {
        VStack(spacing: 10) {
            LiquidCluster {
                HStack(alignment: .bottom, spacing: 10) {
                    Button {
                        store.newThread(); draft = ""; followOutput = true; TouchFeedback.tap()
                    } label: { LiquidIcon(name: "plus") }
                        .disabled(store.isSending || !store.storageReady).accessibilityLabel("新建对话")
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("说点什么…", text: $draft, axis: .vertical)
                            .lineLimit(1...6).focused($inputFocused).padding(.vertical, 16).padding(.leading, 19)
                            .accessibilityLabel("消息内容")
                        Button(action: sendOrStop) {
                            Image(systemName: store.isSending ? "stop.fill" : "arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 42, height: 42).foregroundStyle(Palette.onAction)
                                .background(Palette.action, in: Circle())
                        }.disabled(!store.isSending && !canSend).opacity(!store.isSending && !canSend ? 0.45 : 1)
                            .padding(6).accessibilityLabel(store.isSending ? "停止生成" : "发送消息")
                    }.liquidSurface(radius: 29)
                }
            }
            Text("ChatGPT 套餐 · 本机记录 · AI 回答可能有误")
                .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }
    private func sendOrStop() {
        TouchFeedback.tap()
        if store.isSending { store.stop(); return }
        guard canSend else { return }
        followOutput = true
        if store.send(draft) { draft = ""; inputFocused = false }
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

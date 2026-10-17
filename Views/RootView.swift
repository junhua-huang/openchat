import SwiftUI
import SafariServices

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var apiConnections: APIConnections
    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-preview") { WorkspacePreview(auth: auth) }
            else { connectedContent }
            #else
            connectedContent
            #endif
        }
    }
    private var connectedContent: some View {
        Group {
            if let connection = apiConnections.active {
                ChatWorkspaceView(accountID: connection.id, auth: auth, apiConnection: connection).id(connection.revision)
            }
            else if let id = auth.activeID { ChatWorkspaceView(accountID: id, auth: auth).id(id) }
            else { WelcomeView() }
        }
        .sheet(item: $auth.browser, onDismiss: { auth.browserDidDismiss() }) { item in
            SafariBrowser(url: item.url) { auth.browser = nil }.ignoresSafeArea()
        }
        .alert(auth.errorText == nil ? "正在使用你的 ChatGPT 套餐" : "连接提示", isPresented: Binding(
            get: { auth.errorText != nil || auth.showPlanNotice },
            set: { if !$0 { auth.errorText = nil; auth.showPlanNotice = false } }
        )) { Button("知道了", role: .cancel) { auth.errorText = nil; auth.showPlanNotice = false } } message: {
            Text(auth.errorText ?? "符合条件的 AI 请求会使用你授权的 ChatGPT 套餐。你可以在 ChatGPT 设置中查看用量并管理授权。")
        }
    }
}

struct SafariBrowser: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        controller.preferredControlTintColor = UIColor(Palette.accent)
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) { }
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onDone() }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var apiConnections: APIConnections
    @State private var showAPISettings = false
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 38
    var body: some View {
        ZStack {
            AmbientBackground()
            ScrollView {
                VStack(spacing: 32) {
                    HStack(spacing: 9) {
                        Image(systemName: "circle.hexagongrid.fill").foregroundStyle(Palette.accent)
                        Text("openchat").font(.system(.title3, design: .rounded, weight: .semibold))
                        Spacer()
                        Text("你的 AI，随心聊").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 16)
                    VStack(spacing: 22) {
                        OpenChatMark(size: 98).padding(.bottom, 10)
                        VStack(spacing: 10) {
                            Text("好的想法，\n从对话开始。")
                                .font(.system(size: titleSize, weight: .semibold, design: .rounded)).tracking(-1.3)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            Text("连接 ChatGPT 或自己的 AI API，\n让灵感、问题和日常，都有回应。")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6)
                        }
                    }.padding(.top, 30).padding(.bottom, 4)
                    VStack(alignment: .leading, spacing: 22) {
                        feature("sparkles", "使用自己的套餐", "符合条件的请求使用你授权的 ChatGPT 套餐。")
                        feature("bubble.left.and.text.bubble.right", "让每一段对话延续", "切换模型、保留上下文，随时接着聊。")
                        feature("lock.shield", "记录保存在本机", "发送时才将所需上下文交给当前 AI 服务。")
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.card.opacity(0.65), in: RoundedRectangle(cornerRadius: 28))
                    VStack(spacing: 14) {
                        Button { TouchFeedback.tap(); Task { await auth.connect() } } label: {
                            HStack(spacing: 10) {
                                if auth.isBusy { ProgressView().tint(Palette.onAction) }
                                Text("Continue with ChatGPT").font(.headline)
                                if !auth.isBusy { Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold)) }
                            }.frame(maxWidth: .infinity).padding(.vertical, 20)
                                .background(Palette.action, in: Capsule()).foregroundStyle(Palette.onAction)
                        }.disabled(auth.isBusy || !auth.isReady)
                            .opacity(auth.isBusy || !auth.isReady ? 0.65 : 1)
                        Text(auth.isBusy ? auth.stage : "身份与套餐使用分别授权 · 不读取已有聊天记录")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button { showAPISettings = true } label: {
                            Label("使用其他 AI API", systemImage: "server.rack")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(18)
                                .liquidSurface(radius: 27, interactive: true)
                        }.buttonStyle(.plain).disabled(auth.isBusy)
                    }
                    if !auth.accounts.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("继续已有连接").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            ForEach(auth.accounts) { account in
                                Button {
                                    if account.tokens == nil { Task { await auth.connect(accountID: account.id) } }
                                    else {
                                        do { try apiConnections.select(nil); auth.select(account.id) }
                                        catch { auth.errorText = error.localizedDescription }
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "person.crop.circle").font(.title2)
                                        Text(account.label).font(.subheadline).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "arrow.right").font(.caption)
                                    }.foregroundStyle(.primary)
                                }.disabled(auth.isBusy)
                            }
                        }.padding(22).liquidSurface(radius: 26)
                    }
                    Text("独立开源项目 · 与 OpenAI 无隶属关系").font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.bottom, 28).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showAPISettings) { NavigationStack { APISettingsView() } }
    }
    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Palette.accent).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

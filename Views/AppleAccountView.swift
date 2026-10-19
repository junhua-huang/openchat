import AuthenticationServices
import SwiftUI

/// Apple's native control supplies the localized title, logo and accessibility.
struct AppleSignInButton: UIViewRepresentable {
    @ObservedObject var manager: AppleSignInManager
    var disabled = false
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(manager: manager) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: colorScheme == .dark ? .white : .black)
        button.cornerRadius = 14
        button.addTarget(context.coordinator, action: #selector(Coordinator.signIn(_:)), for: .touchUpInside)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        button.isEnabled = !disabled && !manager.isBusy && manager.storageReady
        button.alpha = button.isEnabled ? 1 : 0.5
    }
    final class Coordinator: NSObject {
        let manager: AppleSignInManager
        init(manager: AppleSignInManager) { self.manager = manager }
        @MainActor @objc func signIn(_ button: ASAuthorizationAppleIDButton) {
            guard let window = button.window else { return }
            manager.startSignIn(presentationAnchor: window)
        }
    }
}

struct AppleAccountPanel: View {
    @EnvironmentObject private var appleSignIn: AppleSignInManager
    @Environment(\.colorScheme) private var colorScheme
    var disabled = false
    @State private var confirmSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let account = appleSignIn.account {
                HStack(spacing: 12) {
                    Image(systemName: "apple.logo").font(.title2).frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                        if let email = account.email, email != account.displayName {
                            Text(email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if appleSignIn.sessionState == .checking { ProgressView() }
                }
                HStack {
                    if appleSignIn.sessionState == .unavailable {
                        Button("重试") { Task { await appleSignIn.refreshCredentialState() } }
                    }
                    Spacer()
                    Button("退出 Apple 登录", role: .destructive) { confirmSignOut = true }
                        .disabled(appleSignIn.isBusy)
                }.font(.subheadline)
            } else {
                AppleSignInButton(manager: appleSignIn, disabled: disabled)
                    .id(colorScheme).frame(height: 52)
            }
            if appleSignIn.isBusy {
                HStack(spacing: 8) {
                    ProgressView(); Text("正在完成 Apple 登录…").font(.caption)
                    Spacer()
                    Button("取消") { appleSignIn.cancelCurrentSignIn() }.font(.subheadline)
                }
            }
            if let notice = appleSignIn.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !appleSignIn.storageReady {
                Button("重试读取登录资料") {
                    appleSignIn.restore()
                    Task { await appleSignIn.refreshCredentialState() }
                }.font(.subheadline)
            }
        }
        .confirmationDialog("退出 Apple 登录？", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("退出并移除本机登录资料", role: .destructive) { appleSignIn.signOut() }
        } message: {
            Text("聊天记录、工作记忆和 AI 连接会保留。要停止 Apple 授权，可前往系统设置中的“Apple 账户 > 通过 Apple 登录”。")
        }
    }

    private var status: String {
        switch appleSignIn.sessionState {
        case .signedOut: return "已退出 Apple 登录"
        case .checking: return "正在确认 Apple 登录状态"
        case .signedIn: return "已通过 Apple 登录"
        case .unavailable: return "暂时无法确认登录状态"
        }
    }
}

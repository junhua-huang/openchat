import SwiftUI
import AuthenticationServices

@main
struct LiaoChatApp: App {
    @StateObject private var auth = AuthManager()
    @StateObject private var apiConnections = APIConnections()
    @StateObject private var appleSignIn = AppleSignInManager()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(auth).environmentObject(apiConnections).environmentObject(appleSignIn).tint(Palette.accent)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
                .task { await appleSignIn.refreshCredentialState() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await appleSignIn.refreshCredentialState() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                    appleSignIn.credentialWasRevoked()
                }
        }
    }
}


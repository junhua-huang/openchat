import SwiftUI

@main
struct LiaoChatApp: App {
    @StateObject private var auth = AuthManager()
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(auth).tint(Palette.accent)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        }
    }
}


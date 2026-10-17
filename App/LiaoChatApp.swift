import SwiftUI

@main
struct LiaoChatApp: App {
    @StateObject private var auth = AuthManager()
    @StateObject private var apiConnections = APIConnections()
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(auth).environmentObject(apiConnections).tint(Palette.accent)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        }
    }
}


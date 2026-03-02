import SwiftUI

@main
struct fit_swiftApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var profileStore = ProfileStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(profileStore)
        }
    }
}

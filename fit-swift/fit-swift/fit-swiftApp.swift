import SwiftUI

@main
struct fit_swiftApp: App {
    @StateObject private var authService = AuthService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
        }
    }
}

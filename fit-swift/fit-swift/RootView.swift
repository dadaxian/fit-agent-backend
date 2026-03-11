import SwiftUI

/// 主入口：默认显示教练工作台，支持展开纯聊天与进入我的页面
struct RootView: View {
    @State private var showPureChat = false
    @State private var showSettings = false

    var body: some View {
        CoachOSMockView(
            onOpenSettings: { showSettings = true },
            onOpenChat: { showPureChat = true },
            showsCloseButton: false
        )
        .fullScreenCover(isPresented: $showPureChat) {
            ChatView(showsCloseButton: true)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(showsCloseButton: true)
        }
    }
}

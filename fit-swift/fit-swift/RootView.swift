import SwiftUI

/// 根视图：默认以私教对话为主，可切换至菜单模式
struct RootView: View {
    @State private var showMenuMode = false

    var body: some View {
        Group {
            if showMenuMode {
                MenuView(onSwitchToChat: { showMenuMode = false })
            } else {
                ChatMainView(onSwitchToMenu: { showMenuMode = true })
            }
        }
    }
}

/// 私教对话主界面（拟人交互为主）
struct ChatMainView: View {
    let onSwitchToMenu: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ChatView()
                .ignoresSafeArea(.keyboard, edges: .bottom)

            Button {
                onSwitchToMenu()
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.top, 8)
            .padding(.trailing, 16)
        }
    }
}

/// 菜单模式（原有 Tab 导航）
struct MenuView: View {
    let onSwitchToChat: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ContentView()
                .ignoresSafeArea(.keyboard, edges: .bottom)

            Button {
                onSwitchToChat()
            } label: {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.top, 8)
            .padding(.trailing, 16)
        }
    }
}

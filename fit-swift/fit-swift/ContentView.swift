import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(onOpenChat: { selectedTab = 2 })
                .tabItem {
                    Label("首页", systemImage: "square.grid.2x2")
                }
                .tag(0)

            WorkoutPlaceholderView()
                .tabItem {
                    Label("训练", systemImage: "dumbbell.fill")
                }
                .tag(1)

            ChatView()
                .tabItem {
                    Label("私教", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(2)

            AssessmentPlaceholderView()
                .tabItem {
                    Label("评估", systemImage: "chart.bar.fill")
                }
                .tag(3)

            NutritionPlaceholderView()
                .tabItem {
                    Label("饮食", systemImage: "fork.knife")
                }
                .tag(4)

            SettingsView()
                .tabItem {
                    Label("我的", systemImage: "person.fill")
                }
                .tag(5)
        }
        .tint(.orange)
    }
}

#Preview {
    ContentView()
}

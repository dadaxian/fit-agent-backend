import SwiftUI

struct AssessmentPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "动作评估",
                systemImage: "chart.bar.fill",
                description: Text("评估功能开发中")
            )
            .navigationTitle("评估")
        }
    }
}

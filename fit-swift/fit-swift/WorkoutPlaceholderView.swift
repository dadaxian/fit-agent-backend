import SwiftUI

struct WorkoutPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "训练计划",
                systemImage: "dumbbell.fill",
                description: Text("训练功能开发中")
            )
            .navigationTitle("训练")
        }
    }
}

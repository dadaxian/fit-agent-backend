import SwiftUI

struct NutritionPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "饮食记录",
                systemImage: "fork.knife",
                description: Text("饮食功能开发中")
            )
            .navigationTitle("饮食")
        }
    }
}

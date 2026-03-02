import SwiftUI

struct DashboardView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FitFlow")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("练就更好")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                    }

                    Text("欢迎使用 AI 私教")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("首页")
        }
    }
}

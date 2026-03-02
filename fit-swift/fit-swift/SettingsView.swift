import SwiftUI

struct SettingsView: View {
    @AppStorage("apiBaseURL") private var apiBaseURL = "http://139.196.181.42:8000"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("API 地址", text: $apiBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("后端配置")
                } footer: {
                    Text("真机测试时请填写 Mac 的局域网 IP，如 http://192.168.1.100:8000")
                }
            }
            .navigationTitle("我的")
        }
    }
}

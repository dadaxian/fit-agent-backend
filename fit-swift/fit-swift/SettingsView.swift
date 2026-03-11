import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthService
    var showsCloseButton: Bool = false
    @AppStorage("apiBaseURL") private var apiBaseURL = "http://139.196.181.42:8000"

    @State private var authMode: AuthMode = .login
    @State private var authEmail = ""
    @State private var authPassword = ""
    @State private var authDisplayName = ""
    @State private var authError = ""
    @State private var authLoading = false

    enum AuthMode {
        case login, register
    }

    var body: some View {
        NavigationStack {
            Form {
                if !auth.isLoggedIn {
                    Section {
                        Picker("", selection: $authMode) {
                            Text("登录").tag(AuthMode.login)
                            Text("注册").tag(AuthMode.register)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: authMode) { _, _ in authError = "" }

                        TextField("邮箱", text: $authEmail)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)

                        SecureField(authMode == .register ? "密码（至少 6 位）" : "密码", text: $authPassword)

                        if authMode == .register {
                            TextField("昵称（可选）", text: $authDisplayName)
                        }

                        if !authError.isEmpty {
                            Text(authError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Button {
                            Task { await submitAuth() }
                        } label: {
                            HStack {
                                if authLoading {
                                    ProgressView()
                                        .scaleEffect(0.9)
                                }
                                Text(authLoading ? "处理中..." : (authMode == .login ? "登录" : "注册"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(authLoading || authEmail.isEmpty || authPassword.isEmpty)
                    } header: {
                        Text("登录 / 注册")
                    } footer: {
                        Text("登录后可使用 AI 私教，数据将关联到你的账号")
                    }
                } else {
                    Section {
                        HStack {
                            Text(auth.displayName ?? auth.user?.email ?? "用户")
                                .font(.headline)
                            Spacer()
                            Button("退出登录", role: .destructive) {
                                auth.logout()
                            }
                        }
                        if let email = auth.user?.email {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Label("个人信息", systemImage: "person.text.rectangle")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("账号")
                    }
                }

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
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { dismiss() }
                    }
                }
            }
        }
    }

    private func submitAuth() async {
        authError = ""
        authLoading = true
        defer { authLoading = false }
        do {
            let baseURL = apiBaseURL.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
            if authMode == .login {
                try await auth.login(email: authEmail, password: authPassword, baseURL: baseURL)
            } else {
                try await auth.register(email: authEmail, password: authPassword, displayName: authDisplayName.isEmpty ? nil : authDisplayName, baseURL: baseURL)
            }
            authEmail = ""
            authPassword = ""
            authDisplayName = ""
        } catch {
            authError = error.localizedDescription
        }
    }
}

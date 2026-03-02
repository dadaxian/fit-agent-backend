import Foundation
import Combine

/// 认证服务：登录、注册、Token 存储
/// 与 fitter AuthProvider 行为一致
@MainActor
final class AuthService: ObservableObject {
    static let authKey = "fit-swift-auth"

    @Published private(set) var token: String?
    @Published private(set) var user: AuthUser?
    @Published private(set) var isLoggedIn: Bool = false

    var displayName: String? {
        user?.displayName ?? user?.email
    }

    init() {
        loadStored()
    }

    private func loadStored() {
        guard let data = UserDefaults.standard.data(forKey: Self.authKey),
              let decoded = try? JSONDecoder().decode(StoredAuth.self, from: data),
              !decoded.accessToken.isEmpty else {
            token = nil
            user = nil
            isLoggedIn = false
            return
        }
        token = decoded.accessToken
        user = decoded.user
        isLoggedIn = true
    }

    private func persist(_ auth: StoredAuth?) {
        if let auth {
            if let data = try? JSONEncoder().encode(auth) {
                UserDefaults.standard.set(data, forKey: Self.authKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.authKey)
        }
    }

    /// 登录
    func login(email: String, password: String, baseURL: String) async throws {
        let url = URL(string: "\(baseURL)/auth/login")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        let (data, res) = try await URLSession.shared.data(for: req)
        let http = res as? HTTPURLResponse
        if http?.statusCode != 200 {
            let errMsg = parseAuthError(data)
            throw AuthError.requestFailed(errMsg)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let accessToken = json?["access_token"] as? String,
              let userObj = json?["user"] as? [String: Any] else {
            throw AuthError.parseError
        }
        let u = AuthUser(
            id: userObj["id"] as? String ?? "",
            email: userObj["email"] as? String ?? "",
            displayName: userObj["display_name"] as? String
        )
        let stored = StoredAuth(accessToken: accessToken, user: u)
        persist(stored)
        token = accessToken
        user = u
        isLoggedIn = true
    }

    /// 注册
    func register(email: String, password: String, displayName: String?, baseURL: String) async throws {
        if password.count < 6 {
            throw AuthError.invalidPassword("密码至少 6 位")
        }
        let url = URL(string: "\(baseURL)/auth/register")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["email": email, "password": password]
        if let dn = displayName, !dn.isEmpty {
            body["display_name"] = dn
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, res) = try await URLSession.shared.data(for: req)
        let http = res as? HTTPURLResponse
        if http?.statusCode != 200 {
            let errMsg = parseAuthError(data)
            throw AuthError.requestFailed(errMsg)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let accessToken = json?["access_token"] as? String,
              let userObj = json?["user"] as? [String: Any] else {
            throw AuthError.parseError
        }
        let u = AuthUser(
            id: userObj["id"] as? String ?? "",
            email: userObj["email"] as? String ?? "",
            displayName: userObj["display_name"] as? String
        )
        let stored = StoredAuth(accessToken: accessToken, user: u)
        persist(stored)
        token = accessToken
        user = u
        isLoggedIn = true
    }

    /// 退出登录
    func logout() {
        persist(nil)
        token = nil
        user = nil
        isLoggedIn = false
    }

    private func parseAuthError(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "请求失败"
        }
        if let detail = json["detail"] as? String { return detail }
        if let arr = json["detail"] as? [[String: Any]], let first = arr.first, let msg = first["msg"] as? String {
            return msg
        }
        return "请求失败"
    }
}

struct AuthUser {
    let id: String
    let email: String
    let displayName: String?
}

private struct StoredAuth: Codable {
    let accessToken: String
    let user: AuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case user
    }
}

extension AuthUser: Codable {
    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
    }
}

enum AuthError: Error, LocalizedError {
    case requestFailed(String)
    case parseError
    case invalidPassword(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let m): return m
        case .parseError: return "解析响应失败"
        case .invalidPassword(let m): return m
        }
    }
}

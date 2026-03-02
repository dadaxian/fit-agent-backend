import Foundation

/// LangGraph Agent Protocol API 客户端
/// 对接 Aegra / LangGraph Platform
final class APIClient {
    let baseURL: String
    let assistantId: String
    let authToken: String?

    init(baseURL: String = "http://139.196.181.42:8000", assistantId: String = "agent", authToken: String? = nil) {
        self.baseURL = baseURL.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        self.assistantId = assistantId
        self.authToken = authToken
    }

    private func setAuthHeaders(_ req: inout URLRequest) {
        if let token = authToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// 创建新对话线程
    func createThread() async throws -> String {
        guard let url = URL(string: "\(baseURL)/threads") else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(&req)
        req.httpBody = "{}".data(using: .utf8)

        let (data, res) = try await URLSession.shared.data(for: req)
        guard let http = res as? HTTPURLResponse else {
            throw APIError.httpError(status: 0)
        }
        if http.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard http.statusCode == 200 else {
            throw APIError.httpError(status: http.statusCode)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let threadId = json?["thread_id"] as? String else {
            throw APIError.parseError
        }
        return threadId
    }

    /// 获取线程当前状态（用于 fetchStateHistory，恢复历史消息）
    /// GET /threads/{thread_id}/state
    func getThreadState(threadId: String) async throws -> [String: Any] {
        guard let url = URL(string: "\(baseURL)/threads/\(threadId)/state") else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        setAuthHeaders(&req)

        let (data, res) = try await URLSession.shared.data(for: req)
        guard let http = res as? HTTPURLResponse else {
            throw APIError.httpError(status: 0)
        }
        if http.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpError(status: http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.parseError
        }
        return json
    }

    /// 流式发送消息并接收 AI 回复
    func streamRun(threadId: String, messages: [[String: Any]]) async throws -> AsyncThrowingStream<[String: Any], Error> {
        let urlStr = "\(baseURL)/threads/\(threadId)/runs/stream"
        guard let url = URL(string: urlStr) else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "assistant_id": assistantId,
            "input": ["messages": messages],
            "stream_mode": ["values", "messages"],
            "stream_subgraphs": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        setAuthHeaders(&req)

        let (bytes, res) = try await URLSession.shared.bytes(for: req)
        guard let http = res as? HTTPURLResponse else {
            throw APIError.httpError(status: 0)
        }
        if http.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpError(status: http.statusCode)
        }

        return AsyncThrowingStream { continuation in
            Task {
                var buffer = ""
                for try await byte in bytes {
                    buffer.append(Character(UnicodeScalar(byte)))
                    if buffer.contains("\n") {
                        let lines = buffer.components(separatedBy: "\n")
                        buffer = lines.last ?? ""
                        for line in lines.dropLast() {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { continue }
                            let jsonStr: String
                            if trimmed.hasPrefix("data: ") {
                                jsonStr = String(trimmed.dropFirst(6))
                            } else if trimmed.hasPrefix("{") {
                                jsonStr = trimmed
                            } else { continue }
                            if jsonStr == "[DONE]" { break }
                            guard let data = jsonStr.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                            let eventData: [String: Any]
                            if let inner = json["data"] as? [String: Any] {
                                eventData = inner
                            } else if json["messages"] != nil {
                                eventData = json
                            } else if let values = json["values"] as? [String: Any] {
                                eventData = values
                            } else { continue }
                            continuation.yield(eventData)
                        }
                    }
                }
                continuation.finish()
            }
        }
    }

    enum APIError: Error, LocalizedError {
        case invalidURL
        case httpError(status: Int)
        case parseError
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "无效的 API 地址"
            case .httpError(let s): return "请求失败 (HTTP \(s))"
            case .parseError: return "解析响应失败"
            case .unauthorized: return "请先登录"
            }
        }
    }
}

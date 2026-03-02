import Foundation

/// LangGraph Agent Protocol API 客户端
/// 对接 Aegra / LangGraph Platform
final class APIClient {
    let baseURL: String
    let assistantId: String

    init(baseURL: String = "http://139.196.181.42:8000", assistantId: String = "agent") {
        self.baseURL = baseURL.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        self.assistantId = assistantId
    }

    /// 创建新对话线程
    func createThread() async throws -> String {
        guard let url = URL(string: "\(baseURL)/threads") else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)

        let (data, res) = try await URLSession.shared.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError(status: (res as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let threadId = json?["thread_id"] as? String else {
            throw APIError.parseError
        }
        return threadId
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

        let (bytes, res) = try await URLSession.shared.bytes(for: req)
        guard let http = res as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError(status: (res as? HTTPURLResponse)?.statusCode ?? 0)
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

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "无效的 API 地址"
            case .httpError(let s): return "请求失败 (HTTP \(s))"
            case .parseError: return "解析响应失败"
            }
        }
    }
}

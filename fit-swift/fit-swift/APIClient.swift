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

    /// 获取或创建当前用户的 thread（需登录）。同一用户始终返回同一 thread_id。
    func getOrCreateThread() async throws -> String {
        guard let url = URL(string: "\(baseURL)/threads/get-or-create") else {
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

    /// 非流式：创建 run 并等待完成，返回完整结果。协议与 stream 相同，但一次性返回。
    func waitRun(threadId: String, messages: [[String: Any]]) async throws -> [String: Any] {
        let urlStr = "\(baseURL)/threads/\(threadId)/runs/wait"
        guard let url = URL(string: urlStr) else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "assistant_id": assistantId,
            "input": ["messages": messages],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        setAuthHeaders(&req)

        let (data, res) = try await URLSession.shared.data(for: req)
        guard let http = res as? HTTPURLResponse else { throw APIError.httpError(status: 0) }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw APIError.httpError(status: http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.parseError }
        return json
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

    /// Coach OS：按模块获取页面数据（独立 API，不走 agent 运行）
    func getCoachOSModule(module: String, subState: String? = nil) async throws -> [String: Any] {
        var comps = URLComponents(string: "\(baseURL)/coach-os/modules/\(module)")
        if let subState, !subState.isEmpty, subState != "overview" {
            comps?.queryItems = [URLQueryItem(name: "sub_state", value: subState)]
        }
        guard let url = comps?.url else {
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

    /// Coach OS：读取当前用户黑板 markdown
    func getCoachOSBlackboard() async throws -> String {
        guard let url = URL(string: "\(baseURL)/coach-os/blackboard") else {
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
        return (json["markdown"] as? String) ?? ""
    }

    /// SSE 事件（对齐 Aegra https://docs.aegra.dev/guides/streaming）
    /// Wire 格式示例：
    ///   event: metadata
    ///   data: {"run_id": "..."}
    ///
    ///   event: messages/partial
    ///   data: {"content": [{"type": "text", "text": "你"}]}
    ///
    ///   event: messages/complete
    ///   data: {"type": "ai", "content": [{"type": "text", "text": "你好"}]}
    ///
    ///   event: values
    ///   data: {"messages": [human_msg, ai_msg]}
    ///
    ///   event: end
    ///   data: {}
    struct StreamEvent {
        let event: String
        let data: [String: Any]?
    }

    /// 流式发送消息并接收 AI 回复
    /// 使用标准 SSE 解析，对齐 @langchain/langgraph-sdk
    func streamRun(threadId: String, messages: [[String: Any]]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let urlStr = "\(baseURL)/threads/\(threadId)/runs/stream"
        guard let url = URL(string: urlStr) else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // 对齐 Aegra RunCreate：stream_mode 控制事件类型，与 web fitter 一致
        // values=完整 state 快照，messages=逐 token 流式(messages/partial, messages/complete)
        let body: [String: Any] = [
            "assistant_id": assistantId,
            "input": ["messages": messages],
            "stream": true,
            "stream_mode": ["updates", "messages"],
            "stream_subgraphs": false,
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
                var buffer = Data()
                var currentEvent = ""
                var dataLines: [String] = []
                var firstByte = true
                do {
                    for try await byte in bytes {
                        if firstByte {
                            firstByte = false
                        }
                        
                        buffer.append(byte)
                        
                        // 探测换行符 \n (ASCII 10) 作为 SSE 数据包边界
                        if byte == 10 {
                            let line = String(data: buffer, encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            buffer.removeAll(keepingCapacity: true)

                            if line.isEmpty {
                                // 空行表示一个 SSE 事件结束，拼接 dataLines
                                if !dataLines.isEmpty {
                                    let joined = dataLines.joined(separator: "\n")
                                    if let data = joined.data(using: .utf8),
                                       let jsonAny = try? JSONSerialization.jsonObject(with: data) {
                                        let eventType = currentEvent.isEmpty ? "values" : currentEvent
                                        if let json = jsonAny as? [String: Any] {
                                            if eventType == "error" {
                                                let msg = (json["message"] as? String) ?? "Stream error"
                                                continuation.finish(throwing: NSError(domain: "APIClient", code: -1, userInfo: [NSLocalizedDescriptionKey: msg]))
                                                return
                                            }
                                            continuation.yield(StreamEvent(event: eventType, data: json))
                                        } else if let array = jsonAny as? [[String: Any]] {
                                            // messages/partial 可能返回数组，统一包一层
                                            continuation.yield(StreamEvent(event: eventType, data: ["messages": array]))
                                        }
                                    }
                                }
                                currentEvent = ""
                                dataLines = []
                                continue
                            }

                            if line.hasPrefix("event:") {
                                currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:") {
                                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                            } else if line.hasPrefix("{") || line.hasPrefix("[") {
                                // NDJSON 兼容：裸 JSON 行，立即作为 values
                                if let data = line.data(using: .utf8),
                                   let jsonAny = try? JSONSerialization.jsonObject(with: data) {
                                    if let json = jsonAny as? [String: Any] {
                                        continuation.yield(StreamEvent(event: "values", data: json))
                                    } else if let array = jsonAny as? [[String: Any]] {
                                        continuation.yield(StreamEvent(event: "values", data: ["messages": array]))
                                    }
                                }
                            } else {
                                // id: / retry: 等字段忽略
                            }
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                continuation.finish()
            }
        }
    }

    private static func parseSSEData(_ lines: [String]) -> [String: Any]? {
        let joined = lines.joined(separator: "\n")
        guard !joined.isEmpty,
              let d = joined.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return nil
        }
        return json
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

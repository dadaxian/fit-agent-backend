import Foundation
import AVFoundation

/// 语音服务：ASR（语音转文字）和 TTS（文字转语音）
/// 对接后端 /voice/asr 和 /voice/tts
final class VoiceService {
    let baseURL: String
    let authToken: String?

    init(baseURL: String = "http://139.196.181.42:8000", authToken: String? = nil) {
        self.baseURL = baseURL.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        self.authToken = authToken
    }

    private func setAuthHeaders(_ req: inout URLRequest) {
        if let token = authToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// 语音转文字。prompt 可选，提供前文对话作为上下文纠偏（智谱 ASR 支持）。
    func speechToText(audioData: Data, contentType: String = "audio/webm", prompt: String? = nil) async throws -> String {
        let url = URL(string: "\(baseURL)/voice/asr")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        setAuthHeaders(&req)
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.webm\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        if let p = prompt, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = String(p.prefix(8000))
            appendField("prompt", trimmed)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, res) = try await URLSession.shared.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "请求失败"
            throw VoiceError.asrFailed(msg)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["text"] as? String) ?? ""
    }

    /// 文字转语音，返回音频数据。speed: 0.9 慢 / 1.0 标准 / 1.2 中 / 1.5 快
    func textToSpeech(text: String, speed: Double = 1.5) async throws -> Data {
        let url = URL(string: "\(baseURL)/voice/tts")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        setAuthHeaders(&req)
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("text", text)
        appendField("voice", "female")
        appendField("speed", String(format: "%.1f", speed))
        appendField("volume", "1.0")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, res) = try await URLSession.shared.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            throw VoiceError.ttsFailed("请求失败")
        }
        return data
    }

    enum VoiceError: Error, LocalizedError {
        case asrFailed(String)
        case ttsFailed(String)

        var errorDescription: String? {
            switch self {
            case .asrFailed(let m): return "语音识别失败: \(m)"
            case .ttsFailed(let m): return "语音合成失败: \(m)"
            }
        }
    }
}

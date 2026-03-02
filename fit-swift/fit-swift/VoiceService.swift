import Foundation
import AVFoundation

/// 语音服务：ASR（语音转文字）和 TTS（文字转语音）
/// 对接后端 /voice/asr 和 /voice/tts
final class VoiceService {
    let baseURL: String

    init(baseURL: String = "http://139.196.181.42:8000") {
        self.baseURL = baseURL.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
    }

    /// 语音转文字
    func speechToText(audioData: Data, contentType: String = "audio/webm") async throws -> String {
        let url = URL(string: "\(baseURL)/voice/asr")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.webm\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, res) = try await URLSession.shared.data(for: req)
        guard let http = res as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "请求失败"
            throw VoiceError.asrFailed(msg)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["text"] as? String) ?? ""
    }

    /// 文字转语音，返回音频数据
    func textToSpeech(text: String) async throws -> Data {
        let url = URL(string: "\(baseURL)/voice/tts")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
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
        appendField("speed", "1.0")
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

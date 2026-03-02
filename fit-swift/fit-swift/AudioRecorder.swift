import Foundation
import AVFoundation

/// 使用 AVAudioRecorder 录制音频，输出为 caf 格式（后端可转 wav）
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var error: String?

    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let dir = FileManager.default.temporaryDirectory
        outputURL = dir.appendingPathComponent(UUID().uuidString + ".caf")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]

        recorder = try AVAudioRecorder(url: outputURL!, settings: settings)
        recorder?.record()
        isRecording = true
        error = nil
    }

    func stopRecording() -> Data? {
        recorder?.stop()
        recorder = nil
        isRecording = false
        defer {
            if let u = outputURL {
                try? FileManager.default.removeItem(at: u)
            }
        }
        guard let url = outputURL, let data = try? Data(contentsOf: url) else { return nil }
        return data
    }
}

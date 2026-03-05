import SwiftUI

/// 调试日志：记录关键步骤及耗时，用于排查卡顿
@MainActor
final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: Date
        let message: String
        let elapsed: TimeInterval?

        var displayText: String {
            let t = DateFormatter()
            t.dateFormat = "HH:mm:ss.SSS"
            let ts = t.string(from: time)
            if let e = elapsed {
                return "[\(ts)] \(message) (+\(String(format: "%.0f", e * 1000))ms"
            }
            return "[\(ts)] \(message)"
        }
    }

    @Published private(set) var entries: [LogEntry] = []
    private var lastLogTime: Date?
    private let maxEntries = 50

    /// 流式原始数据记录：每次 stream 请求的完整返回，便于复制分享
    @Published private(set) var streamRawRecords: [String] = []
    @Published private(set) var streamRecordCount = 0

    private init() {}

    func log(_ message: String) {
        let now = Date()
        let elapsed = lastLogTime.map { now.timeIntervalSince($0) }
        lastLogTime = now
        let entry = LogEntry(time: now, message: message, elapsed: elapsed)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast()
        }
    }

    func clear() {
        entries.removeAll()
        lastLogTime = nil
        streamRawRecords.removeAll()
        streamRecordCount = 0
    }

    /// 开始记录本次流式请求的原始返回
    func startStreamCapture() {
        streamRawRecords.removeAll()
        streamRecordCount = 0
    }

    /// 记录一条流式事件（event + data）
    func recordStreamEvent(event: String, data: [String: Any]?) {
        var dataJson = "null"
        if let d = data, let jsonData = try? JSONSerialization.data(withJSONObject: d),
           let s = String(data: jsonData, encoding: .utf8) {
            dataJson = s
        }
        let line = "event: \(event)\ndata: \(dataJson)\n"
        streamRawRecords.append(line)
        streamRecordCount = streamRawRecords.count
    }

    /// 获取完整流式原始数据文本，便于复制
    func getStreamCaptureText() -> String {
        streamRawRecords.joined(separator: "\n")
    }

    /// 清空流式记录
    func clearStreamCapture() {
        streamRawRecords.removeAll()
        streamRecordCount = 0
    }
}

struct DebugOverlayView: View {
    @ObservedObject var logger = DebugLogger.shared
    var useWaitMode: Bool = false
    @State private var expanded = false
    @State private var dragOffset: CGSize = .zero
    @State private var copiedHint = false

    var body: some View {
        VStack {
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("调试")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button("清空") { logger.clear() }
                            .font(.caption2)
                        if useWaitMode {
                            Text("wait 模式")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("关闭「非流式」可启用流式并记录原始数据")
                        }
                        if logger.streamRecordCount > 0 {
                            Button(copiedHint ? "已复制" : "复制流式原始数据") {
                                UIPasteboard.general.string = logger.getStreamCaptureText()
                                copiedHint = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedHint = false }
                            }
                            .font(.caption2)
                            .foregroundStyle(copiedHint ? .green : .blue)
                        }
                        Button("收起") { expanded = false }
                            .font(.caption2)
                    }
                    .padding(4)
                    if logger.streamRecordCount > 0 {
                        Text("流式事件: \(logger.streamRecordCount) 条")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(logger.entries) { e in
                                Text(e.displayText)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                }
                .padding(8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(width: 280)
            }
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "xmark.circle.fill" : "ant.circle.fill")
                    .font(.title2)
                    .foregroundStyle(expanded ? Color.secondary : Color.orange)
            }
        }
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { v in dragOffset = v.translation }
                .onEnded { v in
                    dragOffset = CGSize(
                        width: dragOffset.width + v.predictedEndTranslation.width - v.translation.width,
                        height: dragOffset.height + v.predictedEndTranslation.height - v.translation.height
                    )
                }
        )
    }
}

import SwiftUI

/// 极简调试日志：仅记录核心状态和内存窗口信息
@MainActor
final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let time: Date
        let message: String

        var displayText: String {
            let t = DateFormatter()
            t.dateFormat = "HH:mm:ss"
            return "[\(t.string(from: time))] \(message)"
        }
    }

    @Published private(set) var entries: [LogEntry] = []
    private let maxEntries = 100

    private init() {}

    func log(_ message: String) {
        let entry = LogEntry(time: Date(), message: message)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast()
        }
    }

    func clear() {
        entries.removeAll()
    }
}

struct DebugOverlayView: View {
    @ObservedObject var logger = DebugLogger.shared
    @State private var expanded = false
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        VStack(alignment: .trailing) {
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("系统调试日志")
                            .font(.system(size: 12, weight: .bold))
                        Spacer()
                        Button("清空") { logger.clear() }
                            .font(.system(size: 10))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .clipShape(Capsule())
                        
                        Button {
                            expanded = false
                        } label: {
                            Image(systemName: "chevron.down.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.05))

                    Divider()

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(logger.entries) { e in
                                Text(e.displayText)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.8))
                                    .padding(.horizontal, 10)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(height: 200)
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                .frame(width: 300)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button {
                withAnimation(.spring()) {
                    expanded.toggle()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 44, height: 44)
                        .shadow(color: .black.opacity(0.1), radius: 4)
                    
                    Image(systemName: expanded ? "terminal.fill" : "terminal")
                        .font(.system(size: 20))
                        .foregroundStyle(expanded ? .orange : .secondary)
                }
            }
        }
        .padding()
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

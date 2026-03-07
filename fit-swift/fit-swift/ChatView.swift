import SwiftUI

enum VoiceInputState: String {
    case idle
    case recording
    case uploading
    case converting
}

struct ChatView: View {
    @EnvironmentObject private var auth: AuthService
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var recorder = AudioRecorder()
    @State private var inputText = ""
    @State private var voiceError: String?
    @State private var isVoiceMode = false
    @State private var voiceInputState: VoiceInputState = .idle
    @State private var autoScrollEnabled = true
    @State private var isUserDragging = false
    @AppStorage("apiBaseURL") private var apiBaseURL = "http://139.196.181.42:8000"
    @AppStorage("showToolMessages") private var showToolMessages = true
    @AppStorage("useWaitMode") private var useWaitMode = false  // false=流式（默认），true=wait 非流式

    var body: some View {
        NavigationStack {
            chatMainContent
                .overlay(alignment: .topTrailing) {
                    DebugOverlayView()
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                }
                .navigationTitle("AI 私教")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if auth.isLoggedIn {
                        ToolbarItem(placement: .topBarLeading) {
                            settingsBar
                        }
                    }
                }
        }
        .onAppear {
            updateAPIClient()
            viewModel.useWaitMode = useWaitMode
            if auth.isLoggedIn {
                Task { await viewModel.restoreStateIfNeeded() }
            }
        }
        .onChange(of: apiBaseURL) { _, _ in
            updateAPIClient()
        }
        .onChange(of: auth.token) { _, _ in
            updateAPIClient()
        }
        .onChange(of: useWaitMode) { _, v in
            viewModel.useWaitMode = v
        }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            if !loggedIn {
                viewModel.onLogout()
            } else {
                Task { await viewModel.restoreStateIfNeeded() }
            }
        }
    }

    @ViewBuilder
    private var chatMainContent: some View {
        VStack(spacing: 0) {
            if !auth.isLoggedIn {
                loginPromptView
            } else {
                chatContentWhenLoggedIn
            }
        }
    }

    private var loginPromptView: some View {
        VStack(spacing: 16) {
            CoachAvatar(size: 80, isSpeaking: false)
            Text("请先在「我的」标签登录")
                .font(.title3)
                .fontWeight(.medium)
            Text("登录后即可使用 AI 私教，对话将关联到你的账号")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var chatContentWhenLoggedIn: some View {
        // 同一用户持久使用同一 thread，不再提供「新对话」
        if let err = viewModel.error {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(8)
        }
        if let err = voiceError {
            Text(err)
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(8)
        }
        if viewModel.messages.isEmpty && viewModel.error == nil && !viewModel.isRestoringHistory {
            emptyChatWelcomeView
        }
        if viewModel.isRestoringHistory {
            restoringHistoryView
        }
        chatScrollArea
        Divider()
        chatInputRow
    }

    private var settingsBar: some View {
        Menu {
            Toggle("显示工具", isOn: $showToolMessages)
            Toggle("非流式(wait)", isOn: $useWaitMode)
                .help("开启后使用 wait 接口，不流式但稳定")
        } label: {
            Image(systemName: "gearshape")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyChatWelcomeView: some View {
        VStack(spacing: 20) {
            CoachAvatar(size: 100, isSpeaking: false)
            Text("你好！我是你的 AI 私教。")
                .font(.title2)
                .fontWeight(.medium)
            Text("你可以问我：今天练什么、帮我计时、这组做完休息多久、我有点累要不要减一组……")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var restoringHistoryView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.9)
            Text("恢复对话中...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    private var chatScrollArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                chatMessageList
                    .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                DragGesture()
                    .onChanged { _ in
                        if !isUserDragging { isUserDragging = true }
                        if autoScrollEnabled { autoScrollEnabled = false }
                    }
                    .onEnded { _ in
                        if isUserDragging {
                            isUserDragging = false
                        }
                    }
            )
            .onChange(of: viewModel.displayBlocks.count) { _, _ in
                guard autoScrollEnabled else { return }
                withAnimation {
                    proxy.scrollTo(viewModel.displayBlocks.last?.id ?? "streaming", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.currentAIResponse) { _, _ in
                guard autoScrollEnabled else { return }
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onChange(of: voiceInputState) { _, s in
                if s == .uploading || s == .converting {
                    proxy.scrollTo("voice-progress", anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !autoScrollEnabled || isUserDragging {
                    Button {
                        autoScrollEnabled = true
                        isUserDragging = false
                        withAnimation {
                            proxy.scrollTo(viewModel.displayBlocks.last?.id ?? "streaming", anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(
                                Circle().stroke(Color.orange.opacity(0.6), lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    @ViewBuilder
    private var chatMessageList: some View {
        // 用 VStack 替代 LazyVStack，避免流式更新时懒加载导致新内容不显示
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(viewModel.displayBlocks.enumerated()), id: \.element.id) { idx, block in
                let isLastBlock = idx == viewModel.displayBlocks.count - 1
                ChatDisplayBlockView(block: block, showToolMessages: showToolMessages, isLoading: viewModel.isLoading, isLastBlock: isLastBlock)
                    .id(block.id)
            }
            if viewModel.displayBlocks.isEmpty {
                ForEach(viewModel.messages) { msg in
                    ChatBubble(
                        message: msg,
                        timestamp: msg.timestamp,
                        apiUrl: msg.isHuman ? apiBaseURL : nil,
                        showAvatar: !msg.isHuman,
                        isStreaming: false
                    )
                    .id(msg.id)
                }
            }
            // 流式输出：当有 currentAIResponse 时显示流式气泡
            if !viewModel.currentAIResponse.isEmpty {
                ChatBubble(
                    message: ChatMessage(id: "streaming", isHuman: false, text: viewModel.currentAIResponse, timestamp: Date()),
                    timestamp: Date(),
                    apiUrl: nil,
                    showAvatar: true,
                    isStreaming: true
                )
                .id("streaming")
            }
            if voiceInputState == .uploading || voiceInputState == .converting {
                VoiceProgressBubble(state: voiceInputState)
                    .id("voice-progress")
            }
        }
    }

    @ViewBuilder
    private var chatInputRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VoiceModeToggleButton(
                isVoiceMode: isVoiceMode,
                isLoading: viewModel.isLoading || viewModel.isRestoringHistory,
                onToggle: { isVoiceMode.toggle() }
            )

            if isVoiceMode {
                voiceInputButton
            } else {
                ChatTextField(text: $inputText)
                if viewModel.isLoading {
                    Button("停止") { viewModel.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    SendButton(enabled: !inputText.trimmingCharacters(in: .whitespaces).isEmpty && !viewModel.isRestoringHistory) { sendText() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func updateAPIClient() {
        let url = apiBaseURL.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        viewModel.setAPIClient(APIClient(baseURL: url, authToken: auth.token))
    }

    private func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        viewModel.send(text: text)
    }

    private var voiceInputButton: some View {
        Group {
            if voiceInputState == .uploading || voiceInputState == .converting {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text(voiceInputState == .uploading ? "上传中" : "识别中")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    BatterySegmentsBar(step: voiceInputState == .uploading ? 1 : 2, total: 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                HoldToRecordButton(
                    isRecording: recorder.isRecording,
                    onStart: startVoiceRecording,
                    onStop: stopVoiceRecordingAndSend,
                    onCancel: cancelVoiceRecording
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func startVoiceRecording() {
        voiceError = nil
        voiceInputState = .recording
        Task {
            let granted = await recorder.requestPermission()
            guard granted else {
                await MainActor.run {
                    voiceError = "需要麦克风权限"
                    voiceInputState = .idle
                }
                return
            }
            do {
                try recorder.startRecording()
            } catch {
                await MainActor.run {
                    voiceError = error.localizedDescription
                    voiceInputState = .idle
                }
            }
        }
    }

    private func buildAsrPrompt(from blocks: [ChatDisplayBlock]) -> String? {
        let last2 = Array(blocks.suffix(2))
        guard !last2.isEmpty else { return nil }
        let maxChars = 200
        let parts = last2.compactMap { block -> String? in
            let (role, text): (String, String) = switch block {
            case .human(_, let t, _): ("用户", t)
            case .aiBlock(_, let t, _, _, _): ("AI", t)
            }
            let truncated = text.count > maxChars ? String(text.prefix(maxChars)) + "…" : text
            guard !truncated.isEmpty else { return nil }
            return "\(role)：\(truncated)"
        }
        guard !parts.isEmpty else { return nil }
        return "主题：和AI健身教练聊天，前两个对话（截取200字符）：\n" + parts.joined(separator: "\n")
    }

    private func stopVoiceRecordingAndSend() {
        guard let data = recorder.stopRecording() else { return }
        voiceInputState = .uploading
        voiceError = nil
        let prompt = buildAsrPrompt(from: viewModel.displayBlocks)
        Task {
            do {
                let client = VoiceService(baseURL: apiBaseURL, authToken: auth.token)
                await MainActor.run { voiceInputState = .converting }
                let text = try await client.speechToText(audioData: data, contentType: "audio/x-caf", prompt: prompt)
                await MainActor.run {
                    voiceInputState = .idle
                    if !text.isEmpty {
                        viewModel.send(text: text)
                    }
                }
            } catch {
                await MainActor.run {
                    voiceInputState = .idle
                    voiceError = error.localizedDescription
                }
            }
        }
    }

    private func cancelVoiceRecording() {
        _ = recorder.stopRecording()
        voiceInputState = .idle
    }

}

// MARK: - 语音/键盘切换按钮（带按下动画）
struct VoiceModeToggleButton: View {
    let isVoiceMode: Bool
    let isLoading: Bool
    let onToggle: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isVoiceMode ? "keyboard" : "mic.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(isVoiceMode ? Color.secondary : Color.orange)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill((isVoiceMode ? Color.gray : Color.orange).opacity(isPressed ? 0.25 : 0.12))
                )
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isPressed)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isPressed { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - 聊天输入框（圆角、柔和样式）
struct ChatTextField: View {
    @Binding var text: String

    var body: some View {
        TextField("输入消息...", text: $text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color(.systemGray6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                    )
            )
            .font(.body)
    }
}

// MARK: - 发送按钮（圆角胶囊）
struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(enabled ? Color.orange : Color.gray.opacity(0.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 录音中指示器（脉动圆点）
struct RecordingIndicator: View {
    @State private var scale: CGFloat = 1.0

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    scale = 1.3
                }
            }
    }
}

// MARK: - 按住录音按钮（上滑取消，带录音动画）
struct HoldToRecordButton: View {
    let isRecording: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onCancel: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var hasStarted = false

    private let cancelThreshold: CGFloat = -80

    var body: some View {
        let drag = DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !hasStarted && value.translation.height < 20 {
                    hasStarted = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onStart()
                }
                dragOffset = value.translation.height
            }
            .onEnded { _ in
                if hasStarted {
                    if dragOffset < cancelThreshold {
                        onCancel()
                    } else {
                        onStop()
                    }
                }
                hasStarted = false
                dragOffset = 0
            }

        return Button {
            // 占位，实际由 gesture 处理
        } label: {
            HStack(spacing: 8) {
                if isRecording {
                    RecordingIndicator()
                }
                Text(buttonLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(dragOffset < cancelThreshold ? .red : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.orange.opacity(isRecording ? 0.25 : 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.orange.opacity(isRecording ? 0.5 : 0.2), lineWidth: 1)
                    )
            )
            .scaleEffect(hasStarted && !isRecording ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: hasStarted)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(drag)
    }

    private var buttonLabel: String {
        if dragOffset < cancelThreshold {
            return "松开手指，取消发送"
        }
        if isRecording {
            return "松开 发送"
        }
        return "按住 说话"
    }
}

// MARK: - 语音进度气泡（上传/识别中）
struct VoiceProgressBubble: View {
    let state: VoiceInputState

    var body: some View {
        HStack {
            Spacer(minLength: 50)
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.orange.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                BatterySegmentsBar(step: stepIndex, total: 2)
            }
            .padding(.horizontal, 16)
        }
    }

    private var statusText: String {
        switch state {
        case .uploading: return "上传中"
        case .converting: return "识别中"
        default: return ""
        }
    }

    private var stepIndex: Int {
        switch state {
        case .uploading: return 1
        case .converting: return 2
        default: return 0
        }
    }
}

// MARK: - 电量格进度条
struct BatterySegmentsBar: View {
    let step: Int
    let total: Int
    private let segmentCount = 5

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<segmentCount, id: \.self) { i in
                let filled = (i + 1) <= Int(Double(step) / Double(total) * Double(segmentCount))
                RoundedRectangle(cornerRadius: 2)
                    .fill(filled ? Color.orange : Color.gray.opacity(0.3))
                    .frame(width: 12, height: 8)
            }
        }
    }
}

private func formatTimestamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    f.locale = Locale(identifier: "zh_CN")
    return f.string(from: date)
}

struct ChatDisplayBlockView: View {
    let block: ChatDisplayBlock
    let showToolMessages: Bool
    let isLoading: Bool
    let isLastBlock: Bool
    @State private var toolsExpanded = false

    var body: some View {
        switch block {
        case .human(_, let text, let timestamp):
            HStack {
                Spacer(minLength: 50)
                VStack(alignment: .trailing, spacing: 4) {
                    MarkdownText(text: text)
                        .padding(12)
                        .background(Color.orange.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    if let ts = timestamp {
                        Text(formatTimestamp(ts))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        case .aiBlock(_, let aiText, let toolCalls, let toolResults, let timestamp):
            let hasToolActivity = !toolCalls.isEmpty || !toolResults.isEmpty
            let shouldHide = !showToolMessages && hasToolActivity && aiText.isEmpty
            Group {
                if shouldHide {
                    EmptyView()
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        CoachAvatar(size: 36, isSpeaking: false)
                        VStack(alignment: .leading, spacing: 6) {
                            if !aiText.isEmpty {
                                MarkdownText(text: aiText)
                                    .padding(12)
                                    .background(Color.gray.opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                if let ts = timestamp {
                                    Text(formatTimestamp(ts))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            if showToolMessages && !toolCalls.isEmpty {
                                ForEach(Array(toolCalls.enumerated()), id: \.offset) { _, tc in
                                    HStack(spacing: 6) {
                                        Image(systemName: "wrench.and.screwdriver")
                                            .font(.caption)
                                        Text("执行: \(tc.name)")
                                            .font(.caption)
                                        if !tc.args.isEmpty {
                                            Text(tc.args)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.blue.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            let toolCount = toolResults.count
                            if showToolMessages && toolCount > 0 {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { toolsExpanded.toggle() }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: toolsExpanded ? "chevron.down" : "chevron.right")
                                            .font(.caption2)
                                        Text(toolsExpanded ? "收起" : "展开")
                                            .font(.caption)
                                        Text("工具调用 (\(toolCount))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                if toolsExpanded {
                                    ForEach(toolResults) { tr in
                                        ToolResultRow(item: tr)
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 50)
                    }
                }
            }
        }
    }
}

/// 单条工具结果（可折叠，默认折叠）
struct ToolResultRow: View {
    let item: ToolResultItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(item.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !expanded {
                        Text(preview)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            if expanded {
                MarkdownText(text: item.result)
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var preview: String {
        let s = item.result.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 50 { return String(s.prefix(50)) + "…" }
        return s
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    var timestamp: Date? = nil
    var apiUrl: String? = nil
    var showAvatar: Bool = false
    var isStreaming: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.isHuman { Spacer(minLength: 50) }

            if !message.isHuman && showAvatar {
                CoachAvatar(size: 36, isSpeaking: isStreaming)
            }

            VStack(alignment: message.isHuman ? .trailing : .leading, spacing: 4) {
                MarkdownText(text: message.text)
                    .padding(12)
                    .background(message.isHuman ? Color.orange.opacity(0.2) : Color.gray.opacity(0.2))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if let ts = timestamp ?? message.timestamp {
                    Text(formatTimestamp(ts))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let url = apiUrl {
                    Text(url)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if !message.isHuman { Spacer(minLength: 50) }
        }
    }
}

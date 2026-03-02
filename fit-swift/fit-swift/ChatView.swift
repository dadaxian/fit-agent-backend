import SwiftUI
import AVFoundation

struct ChatView: View {
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var recorder = AudioRecorder()
    @State private var inputText = ""
    @State private var voiceError: String?
    @State private var ttsPlaying = false
    @AppStorage("apiBaseURL") private var apiBaseURL = "http://139.196.181.42:8000"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !viewModel.messages.isEmpty {
                    HStack {
                        Spacer()
                        Button("新对话") {
                            viewModel.newChat()
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }

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

                if viewModel.messages.isEmpty && viewModel.error == nil {
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

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.displayBlocks) { block in
                                ChatDisplayBlockView(block: block, onPlayTts: ttsPlaying ? nil : { playTTS($0) })
                                    .id(block.id)
                            }
                            if viewModel.displayBlocks.isEmpty {
                                ForEach(viewModel.messages) { msg in
                                    ChatBubble(
                                        message: msg,
                                        apiUrl: msg.isHuman ? apiBaseURL : nil,
                                        showAvatar: !msg.isHuman,
                                        isStreaming: false,
                                        onPlayTts: ttsPlaying ? nil : { playTTS($0) }
                                    )
                                    .id(msg.id)
                                }
                            }
                            if viewModel.isLoading {
                                HStack {
                                    ProgressView()
                                    Text("思考中...")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .id("loading")
                            }
                            if !viewModel.currentAIResponse.isEmpty {
                                ChatBubble(
                                    message: ChatMessage(id: "streaming", isHuman: false, text: viewModel.currentAIResponse),
                                    apiUrl: nil,
                                    showAvatar: true,
                                    isStreaming: true,
                                    onPlayTts: nil
                                )
                                .id("streaming")
                            }
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: viewModel.displayBlocks.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo(viewModel.displayBlocks.last?.id ?? "loading", anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.currentAIResponse) { _, _ in
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }

                Divider()

                HStack(alignment: .bottom, spacing: 12) {
                    Button {
                        toggleVoiceInput()
                    } label: {
                        Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.fill")
                            .font(.title2)
                            .foregroundStyle(recorder.isRecording ? .red : .orange)
                    }
                    .disabled(viewModel.isLoading)

                    TextField("输入消息...", text: $inputText)
                        .textFieldStyle(.roundedBorder)

                    if viewModel.isLoading {
                        Button("停止") {
                            viewModel.stop()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button("发送") {
                            sendText()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding()
            }
            .navigationTitle("AI 私教")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            viewModel.setAPIClient(APIClient(baseURL: apiBaseURL))
        }
        .onChange(of: apiBaseURL) { _, new in
            viewModel.setAPIClient(APIClient(baseURL: new))
        }
    }

    private func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        viewModel.send(text: text)
    }

    private func toggleVoiceInput() {
        if recorder.isRecording {
            guard let data = recorder.stopRecording() else { return }
            voiceError = nil
            Task {
                do {
                    let client = VoiceService(baseURL: apiBaseURL)
                    let text = try await client.speechToText(audioData: data, contentType: "audio/x-caf")
                    if !text.isEmpty {
                        await MainActor.run {
                            inputText = text
                            viewModel.send(text: text)
                        }
                    }
                } catch {
                    await MainActor.run {
                        voiceError = error.localizedDescription
                    }
                }
            }
        } else {
            Task {
                let granted = await recorder.requestPermission()
                guard granted else {
                    await MainActor.run { voiceError = "需要麦克风权限" }
                    return
                }
                try? recorder.startRecording()
            }
        }
    }

    private func playTTS(_ text: String) {
        guard !ttsPlaying else { return }
        ttsPlaying = true
        voiceError = nil
        Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                let client = VoiceService(baseURL: apiBaseURL)
                let data = try await client.textToSpeech(text: text)
                let player = try AVAudioPlayer(data: data)
                player.prepareToPlay()
                player.play()
                while player.isPlaying {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch {
                await MainActor.run { voiceError = error.localizedDescription }
            }
            await MainActor.run { ttsPlaying = false }
        }
    }
}

struct ChatDisplayBlockView: View {
    let block: ChatDisplayBlock
    let onPlayTts: ((String) -> Void)?
    @State private var toolsExpanded = false

    var body: some View {
        switch block {
        case .human(_, let text):
            HStack {
                Spacer(minLength: 50)
                MarkdownText(text: text)
                    .padding(12)
                    .background(Color.orange.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        case .aiBlock(_, let aiText, let toolCalls, let toolResults):
            HStack(alignment: .top, spacing: 10) {
                CoachAvatar(size: 36, isSpeaking: false)
                VStack(alignment: .leading, spacing: 6) {
                    if !aiText.isEmpty {
                        MarkdownText(text: aiText)
                            .padding(12)
                            .background(Color.gray.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        if let play = onPlayTts {
                            Button { play(aiText) } label: {
                                Label("朗读", systemImage: "speaker.wave.2.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !toolCalls.isEmpty {
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
                    if toolCount > 0 {
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
    var apiUrl: String? = nil
    var showAvatar: Bool = false
    var isStreaming: Bool = false
    let onPlayTts: ((String) -> Void)?

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

                if let url = apiUrl {
                    Text(url)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !message.isHuman, let play = onPlayTts {
                    Button {
                        play(message.text)
                    } label: {
                        Label("朗读", systemImage: "speaker.wave.2.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !message.isHuman { Spacer(minLength: 50) }
        }
    }
}

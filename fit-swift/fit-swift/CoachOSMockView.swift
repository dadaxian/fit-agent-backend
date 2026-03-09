import SwiftUI
import MarkdownUI

private enum CoachOSModule: String, CaseIterable, Identifiable {
    case home
    case plans
    case training
    case assessment
    case workspace

    var id: String { key }
    var key: String { rawValue }
    var title: String {
        switch self {
        case .home: return "首页"
        case .plans: return "计划"
        case .training: return "训练"
        case .assessment: return "评估"
        case .workspace: return "其他"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .plans: return "calendar"
        case .training: return "dumbbell.fill"
        case .assessment: return "figure.strengthtraining.traditional"
        case .workspace: return "square.and.pencil"
        }
    }

    static func fromServerModule(_ s: String) -> CoachOSModule {
        switch s {
        case "home": return .home
        case "plans": return .plans
        case "workout", "training": return .training
        case "assessment": return .assessment
        case "workspace": return .workspace
        default: return .home
        }
    }
}

private struct CoachOSUIState {
    let module: CoachOSModule
    let subState: String
    let title: String
    let coachMessage: String
    let sections: [[String: Any]]
    let cards: [[String: Any]]
}

@MainActor
private final class CoachOSMockViewModel: ObservableObject {
    @Published var selectedModule: CoachOSModule = .home
    @Published var coachLine: String = "正在连接教练..."
    @Published var coachBubble: String = "你好，我在。"
    @Published var inputText: String = ""
    @Published var isLoading = false
    @Published var isAgentThinking = false
    @Published var error: String?
    @Published var uiState: CoachOSUIState?
    @Published var currentSubState: String = "overview"
    @Published var blackboardMarkdown: String = ""
    @Published var blockedModules: Set<CoachOSModule> = []

    private var apiClient: APIClient?
    private var threadId: String?

    func setAPIClient(_ client: APIClient) {
        apiClient = client
    }

    func loadInitialState() {
        requestModuleData(for: .home, subState: "overview")
    }

    func quickActionTitle() -> String {
        switch module {
        case .home: return "让教练安排今天"
        case .plans: return "让教练调整计划"
        case .training: return "让教练推进训练"
        case .assessment: return "让教练解读评估"
        case .workspace: return "让教练整理黑板"
        }
    }
    private var module: CoachOSModule { selectedModule }

    func sendChatInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inputText = ""
        requestUIState(userText: trimmed, showThinking: true)
    }

    func sendVoiceMockInput() {
        requestUIState(userText: "查看进入计划", showThinking: true)
    }

    func switchModule(_ module: CoachOSModule) {
        // 默认允许用户自由切换，若后端声明阻断再拦截
        guard !blockedModules.contains(module) else {
            updateCoachReply("当前阶段暂不能进入\(module.title)模块。")
            return
        }
        selectedModule = module
        currentSubState = "overview"
        // 用户手动切换时立即切页，不再等待 agent
        requestModuleData(for: module)
    }

    func openPlanItem(title: String) {
        // 用户点击页面元素时走“传统逻辑”：本地直接跳转，不依赖 agent 决策
        navigateLocal(to: .plans, subState: "today")
    }

    func startTraining() {
        requestUIState(userText: "开始训练", showThinking: true)
    }

    func pingCoach() {
        updateCoachReply("我在，你可以直接说：查看进入计划。")
    }

    private func updateCoachReply(_ text: String) {
        coachLine = text
        coachBubble = text
    }

    func navigateLocal(to module: CoachOSModule, subState: String = "overview") {
        guard !blockedModules.contains(module) else {
            updateCoachReply("当前阶段暂不能进入\(module.title)模块。")
            return
        }
        selectedModule = module
        currentSubState = subState
        if module == .workspace, subState == "blackboard" {
            requestBlackboard()
        } else {
            requestModuleData(for: module, subState: subState)
        }
    }

    private func requestUIState(userText: String, showThinking: Bool) {
        guard !isLoading, let client = apiClient else { return }
        isLoading = true
        isAgentThinking = showThinking
        error = nil
        Task { @MainActor in
            defer {
                self.isLoading = false
                self.isAgentThinking = false
            }
            do {
                let tid = try await ensureThread(using: client)
                let message = buildHumanMessage(text: userText)
                let output = try await client.waitRun(threadId: tid, messages: [message])
                let rawMessages = extractMessages(from: output)
                let commands = extractUICommands(from: rawMessages)
                for cmd in commands {
                    applyUICommand(cmd)
                }
                if let aiText = extractLatestAIText(from: rawMessages) {
                    self.updateCoachReply(aiText)
                } else if commands.isEmpty {
                    self.error = "未解析到回复或页面指令"
                }
            } catch {
                self.error = error.localizedDescription
                self.updateCoachReply("请求失败，请稍后重试。")
            }
        }
    }

    private func requestModuleData(for module: CoachOSModule) {
        guard let client = apiClient else { return }
        Task { @MainActor in
            do {
                let payload = try await client.getCoachOSModule(module: module.key, subState: currentSubState)
                guard let parsed = parseUIStateFromPayload(payload) else { return }
                self.uiState = parsed
                self.selectedModule = parsed.module
                self.currentSubState = parsed.subState
            } catch {
                // 模块数据接口失败时不打断用户切页体验，仅提示
                self.error = "模块数据加载失败：\(error.localizedDescription)"
            }
        }
    }

    private func requestModuleData(for module: CoachOSModule, subState: String) {
        guard let client = apiClient else { return }
        currentSubState = subState
        Task { @MainActor in
            do {
                let payload = try await client.getCoachOSModule(module: module.key, subState: subState)
                guard let parsed = parseUIStateFromPayload(payload) else { return }
                self.uiState = parsed
                self.selectedModule = parsed.module
                self.currentSubState = parsed.subState
            } catch {
                self.error = "模块数据加载失败：\(error.localizedDescription)"
            }
        }
    }

    private func requestBlackboard() {
        guard let client = apiClient else { return }
        Task { @MainActor in
            do {
                self.blackboardMarkdown = try await client.getCoachOSBlackboard()
            } catch {
                self.error = "黑板加载失败：\(error.localizedDescription)"
            }
        }
    }

    private func ensureThread(using client: APIClient) async throws -> String {
        if let threadId, !threadId.isEmpty {
            return threadId
        }
        let created = try await client.getOrCreateThread()
        threadId = created
        return created
    }

    private func buildHumanMessage(text: String) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "type": "human",
            "content": [["type": "text", "text": text]],
            "timestamp": formatter.string(from: Date()),
            "timezone": TimeZone.current.identifier,
            "ui_context": [
                "module": selectedModule.key,
                "sub_state": uiState?.subState ?? "overview",
            ],
        ]
    }

    private func extractMessages(from output: [String: Any]) -> [[String: Any]] {
        if let m = output["messages"] as? [[String: Any]] {
            return m
        }
        if let vals = output["values"] as? [String: Any], let m = vals["messages"] as? [[String: Any]] {
            return m
        }
        if let out = output["output"] as? [String: Any], let m = out["messages"] as? [[String: Any]] {
            return m
        }
        if let out = output["output"] as? [String: Any],
           let vals = out["values"] as? [String: Any],
           let m = vals["messages"] as? [[String: Any]] {
            return m
        }
        return []
    }

    private func parseLatestUIState(from messages: [[String: Any]]) -> CoachOSUIState? {
        for msg in messages.reversed() {
            guard (msg["type"] as? String) == "ai" else { continue }
            if let state = parseUIState(from: msg) {
                return state
            }
        }
        return nil
    }

    private func extractLatestAIText(from messages: [[String: Any]]) -> String? {
        for msg in messages.reversed() {
            guard (msg["type"] as? String) == "ai" else { continue }
            if let content = msg["content"] as? String {
                let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
            if let blocks = msg["content"] as? [[String: Any]] {
                let parts = blocks.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return text.isEmpty ? nil : text
                }
                if !parts.isEmpty { return parts.joined(separator: " ") }
            }
        }
        return nil
    }

    private func extractUICommands(from messages: [[String: Any]]) -> [[String: Any]] {
        var commands: [[String: Any]] = []
        let lastHumanIndex = messages.lastIndex { ($0["type"] as? String) == "human" } ?? -1
        for (idx, msg) in messages.enumerated() where idx > lastHumanIndex {
            guard (msg["type"] as? String) == "tool" else { continue }
            guard (msg["name"] as? String) == "ui_command" else { continue }
            if let kwargs = msg["additional_kwargs"] as? [String: Any],
               let cmd = kwargs["ui_command"] as? [String: Any] {
                commands.append(cmd)
                continue
            }
            if let content = msg["content"] as? String,
               let data = content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let wrapped = json["output"] as? [String: Any] {
                    commands.append(wrapped)
                } else {
                    commands.append(json)
                }
            }
        }
        return commands
    }

    private func applyUICommand(_ command: [String: Any]) {
        let type = (command["type"] as? String) ?? ""
        let moduleString = command["module"] as? String
        let payload = command["payload"] as? [String: Any] ?? [:]
        let subState = (command["sub_state"] as? String) ?? (payload["sub_state"] as? String) ?? "overview"
        switch type {
        case "navigate":
            guard let moduleString else { return }
            let target = CoachOSModule.fromServerModule(moduleString)
            if blockedModules.contains(target) {
                updateCoachReply("当前阶段暂不能进入\(target.title)模块。")
                return
            }
            selectedModule = target
            currentSubState = subState
            if target == .workspace, subState == "blackboard" {
                requestBlackboard()
            } else {
                requestModuleData(for: target, subState: subState)
            }
        case "show_message":
            if let text = payload["text"] as? String {
                updateCoachReply(text)
            } else if let text = payload["message"] as? String {
                updateCoachReply(text)
            }
        default:
            break
        }
    }

    private func parseUIStateFromPayload(_ payload: [String: Any]) -> CoachOSUIState? {
        if let ui = payload["ui_state"] as? [String: Any] {
            return mapToState(ui)
        }
        return mapToState(payload)
    }

    private func parseUIState(from aiMessage: [String: Any]) -> CoachOSUIState? {
        if let kwargs = aiMessage["additional_kwargs"] as? [String: Any],
           let ui = kwargs["ui_state"] as? [String: Any],
           let parsed = mapToState(ui) {
            return parsed
        }
        if let kwargs = aiMessage["kwargs"] as? [String: Any] {
            if let extra = kwargs["additional_kwargs"] as? [String: Any],
               let ui = extra["ui_state"] as? [String: Any],
               let parsed = mapToState(ui) {
                return parsed
            }
            if let ui = kwargs["ui_state"] as? [String: Any], let parsed = mapToState(ui) {
                return parsed
            }
        }
        return nil
    }

    private func mapToState(_ raw: [String: Any]) -> CoachOSUIState? {
        let moduleString = raw["module"] as? String ?? "home"
        let module = CoachOSModule.fromServerModule(moduleString)
        let subState = raw["sub_state"] as? String ?? "overview"
        let title = raw["title"] as? String ?? "FitFlow AI 操作系统"
        let coachMessage = raw["coach_message"] as? String ?? "页面已更新。"
        let data = raw["data"] as? [String: Any]
        let sections = data?["sections"] as? [[String: Any]] ?? []
        let cards = raw["cards"] as? [[String: Any]] ?? []
        if let permissions = raw["permissions"] as? [String: Any],
           let blocked = permissions["blocked_modules"] as? [String] {
            blockedModules = Set(blocked.map { CoachOSModule.fromServerModule($0) })
        } else {
            blockedModules = []
        }
        return CoachOSUIState(
            module: module,
            subState: subState,
            title: title,
            coachMessage: coachMessage,
            sections: sections,
            cards: cards
        )
    }

}

struct CoachOSMockView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthService
    @StateObject private var viewModel = CoachOSMockViewModel()
    @State private var isVoiceMode = false
    @State private var isRecording = false
    @State private var spin = false
    @AppStorage("apiBaseURL") private var apiBaseURL = "http://139.196.181.42:8000"

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                backgroundLayer

                VStack(spacing: 0) {
                    tabBar

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(viewModel.uiState?.title ?? "Agent 页面系统")
                                .font(.headline)

                            Text("当前模块：\(viewModel.selectedModule.title)")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                            moduleContent

                            Button(viewModel.quickActionTitle()) {
                                viewModel.sendVoiceMockInput()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)

                            if let err = viewModel.error {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 170)
                    }

                    bottomInputBar
                }

                floatingCoach
                floatingCloseButton
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navigationBarHidden(true)
            .onAppear {
                let url = apiBaseURL.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
                viewModel.setAPIClient(APIClient(baseURL: url, authToken: auth.token))
                if viewModel.uiState == nil, auth.isLoggedIn {
                    viewModel.loadInitialState()
                }
            }
            .onChange(of: viewModel.isAgentThinking) { newValue in
                spin = newValue
            }
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemTeal).opacity(0.14), Color(.systemOrange).opacity(0.10), Color(.systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.orange.opacity(0.12))
                .frame(width: 260, height: 260)
                .blur(radius: 18)
                .offset(x: 130, y: -260)

            Circle()
                .fill(Color.cyan.opacity(0.12))
                .frame(width: 220, height: 220)
                .blur(radius: 20)
                .offset(x: -140, y: -160)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 14) {
            ForEach(CoachOSModule.allCases) { module in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        viewModel.switchModule(module)
                    }
                } label: {
                    Image(systemName: module.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(viewModel.selectedModule == module ? Color.orange : Color.secondary.opacity(0.85))
                        .frame(width: 38, height: 38)
                        .background(
                            Group {
                                if viewModel.selectedModule == module {
                                    Circle().fill(.thinMaterial)
                                } else {
                                    Circle().fill(Color.clear)
                                }
                            }
                        )
                        .overlay(
                            Circle()
                                .stroke(viewModel.selectedModule == module ? Color.white.opacity(0.35) : Color.clear, lineWidth: 0.8)
                        )
                        .shadow(
                            color: viewModel.selectedModule == module ? Color.orange.opacity(0.25) : Color.clear,
                            radius: 8,
                            x: 0,
                            y: 4
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(module.title)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(Color.white.opacity(0.32), lineWidth: 0.8)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var bottomInputBar: some View {
        HStack(alignment: .center, spacing: 10) {
            VoiceModeToggleButton(
                isVoiceMode: isVoiceMode,
                isLoading: false,
                onToggle: { isVoiceMode.toggle() }
            )

            if isVoiceMode {
                HoldToRecordButton(
                    isRecording: isRecording,
                    onStart: { isRecording = true },
                    onStop: {
                        isRecording = false
                        viewModel.sendVoiceMockInput()
                    },
                    onCancel: { isRecording = false }
                )
                .frame(maxWidth: .infinity)
            } else {
                ChatTextField(text: $viewModel.inputText)
                SendButton(enabled: !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    viewModel.sendChatInput()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var floatingCoach: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !viewModel.coachBubble.isEmpty {
                MarkdownText(text: viewModel.coachBubble)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
                    )
                    .frame(maxWidth: 260, alignment: .leading)
            }
            Button {
                viewModel.pingCoach()
            } label: {
                ZStack {
                    CoachAvatar(size: 56, isSpeaking: viewModel.isLoading)
                        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                    if viewModel.isAgentThinking {
                        Circle()
                            .trim(from: 0.1, to: 0.82)
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [.orange.opacity(0.1), .orange, .orange.opacity(0.15)]),
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                            )
                            .frame(width: 66, height: 66)
                            .rotationEffect(.degrees(spin ? 360 : 0))
                            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 16)
        .padding(.bottom, 84)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var floatingCloseButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    @ViewBuilder
    private var moduleContent: some View {
        switch viewModel.selectedModule {
        case .home:
            homeContentFromSections
        case .plans:
            if viewModel.currentSubState == "today" {
                plansTodayContentFromSections
            } else {
                plansContentFromSections
            }
        case .training:
            trainingContentFromSections
        case .workspace:
            if viewModel.currentSubState == "blackboard" {
                blackboardContent
            } else {
                defaultListContent
            }
        case .assessment:
            defaultListContent
        }
    }

    private var homeContentFromSections: some View {
        let metricsSection = section(type: "metrics")
        let focusSection = section(type: "focus")
        return VStack(alignment: .leading, spacing: 12) {
            if let items = metricsSection?["items"] as? [[String: Any]], !items.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(items.prefix(2)).indices, id: \.self) { idx in
                        let item = items[idx]
                        metricTile(
                            title: item["title"] as? String ?? "指标",
                            value: item["value"] as? String ?? "--",
                            hint: item["hint"] as? String ?? ""
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if let focus = focusSection {
                VStack(alignment: .leading, spacing: 8) {
                    Text(focus["title"] as? String ?? "今日重点")
                        .font(.headline)
                    Text(focus["text"] as? String ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
                )
            } else {
                defaultListContent
            }
        }
    }

    private var plansContentFromSections: some View {
        let planSection = section(type: "plan_overview")
        let items = planSection?["items"] as? [[String: Any]] ?? []
        return VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                defaultListContent
            } else {
                ForEach(items.indices, id: \.self) { idx in
                    let item = items[idx]
                    planRow(
                        title: item["title"] as? String ?? "计划项",
                        subtitle: item["subtitle"] as? String ?? ""
                    ) {
                        viewModel.openPlanItem(title: item["title"] as? String ?? "计划")
                    }
                }
            }
        }
    }

    private var plansTodayContentFromSections: some View {
        let todaySection = section(type: "today_overview")
        let items = todaySection?["items"] as? [[String: Any]] ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(todaySection?["title"] as? String ?? "今日训练计划")
                    .font(.headline)
                Spacer()
                Text("Today")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
            }

            if items.isEmpty {
                defaultListContent
            } else {
                ForEach(items.indices, id: \.self) { idx in
                    let item = items[idx]
                    planRow(
                        title: item["title"] as? String ?? "今日计划",
                        subtitle: item["subtitle"] as? String ?? ""
                    ) {
                        // 用户点击页面元素时走“传统逻辑”：直接进入训练进行中页
                        viewModel.navigateLocal(to: .training, subState: "session")
                    }
                }
            }
        }
    }

    private var trainingContentFromSections: some View {
        let panel = section(type: "training_panel")
        let fields = panel?["fields"] as? [String: Any] ?? [:]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(panel?["title"] as? String ?? "专业训练面板")
                    .font(.headline)
                Spacer()
                Text("休息 90s")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("项目：\(fields["exercise"] as? String ?? "杠铃卧推")")
                    .font(.headline)
                Text("\(fields["set_progress"] as? String ?? "第 2 组 / 共 4 组") · \(fields["target"] as? String ?? "8-10 次，建议 60kg")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("动作提示：\(fields["tip"] as? String ?? "下放 2 秒，底部停顿 0.5 秒，稳定推起")。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
            )

            HStack(spacing: 10) {
                tinyAction("完成本组")
                tinyAction("太重了")
                tinyAction("太轻了")
            }
        }
    }

    private var defaultListContent: some View {
        let listItems = (section(type: "list")?["items"] as? [[String: Any]]) ?? []
        let fallback = listItems.isEmpty ? ((viewModel.uiState?.cards ?? []).map { $0 }) : listItems
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(fallback.indices, id: \.self) { idx in
                let card = fallback[idx]
                VStack(alignment: .leading, spacing: 6) {
                    Text(card["title"] as? String ?? "信息")
                        .font(.headline)
                    Text(card["value"] as? String ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
                )
            }
        }
    }

    private var blackboardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("黑板")
                    .font(.headline)
                Spacer()
                Text("Markdown")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
            }

            if viewModel.blackboardMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("黑板为空。你可以让教练把长内容整理到黑板。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            } else {
                MarkdownText(text: viewModel.blackboardMarkdown)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
                    )
            }
        }
    }

    private func section(type: String) -> [String: Any]? {
        let sections: [[String: Any]]
        if viewModel.uiState?.module == viewModel.selectedModule {
            sections = viewModel.uiState?.sections ?? []
        } else {
            sections = fallbackSections(for: viewModel.selectedModule)
        }
        return sections.first(where: { ($0["type"] as? String) == type })
    }

    private func fallbackSections(for module: CoachOSModule) -> [[String: Any]] {
        switch module {
        case .home:
            return [
                [
                    "id": "home_metrics",
                    "type": "metrics",
                    "title": "今日总览",
                    "items": [
                        ["id": "sessions", "title": "本周完成", "value": "3 / 4", "hint": "训练次数"],
                        ["id": "streak", "title": "连续打卡", "value": "6 天", "hint": "保持不错"],
                    ],
                ],
                [
                    "id": "home_focus",
                    "type": "focus",
                    "title": "今日重点",
                    "text": "胸肩三头训练 + 高蛋白饮食，建议先训练再补饮食记录。",
                ],
            ]
        case .plans:
            return [
                [
                    "id": "plan_overview",
                    "type": "plan_overview",
                    "title": "计划概览",
                    "items": [
                        ["id": "training", "title": "训练计划概览", "subtitle": "本周 4 练，当前第 2 周"],
                        ["id": "nutrition", "title": "饮食计划概览", "subtitle": "2200 kcal，蛋白 160g"],
                        ["id": "changes", "title": "最近调整记录", "subtitle": "卧推工作组 4 -> 3"],
                    ],
                ],
            ]
        case .training:
            return [
                [
                    "id": "training_panel",
                    "type": "training_panel",
                    "title": "专业训练面板",
                    "fields": [
                        "exercise": "杠铃卧推",
                        "set_progress": "第 2 组 / 共 4 组",
                        "target": "8-10 次，建议 60kg",
                        "rest_seconds": 90,
                        "tip": "下放 2 秒，底部停顿 0.5 秒，稳定推起",
                    ],
                ],
            ]
        case .assessment:
            return [
                [
                    "id": "default_list",
                    "type": "list",
                    "items": [
                        ["id": "movement_eval", "title": "动作评估", "value": "上传视频检查动作标准度"],
                        ["id": "physique_eval", "title": "体态评估", "value": "上传肌肉照片进行阶段评估"],
                    ],
                ],
            ]
        case .workspace:
            return [
                [
                    "id": "default_list",
                    "type": "list",
                    "items": [
                        ["id": "blackboard", "title": "训练黑板", "value": "可用 Markdown 记录本周重点"],
                        ["id": "notes", "title": "教练笔记", "value": "记录疲劳感、恢复和调整建议"],
                    ],
                ],
            ]
        }
    }

    private func metricTile(title: String, value: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
        )
    }

    private func planRow(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    private func tinyAction(_ title: String) -> some View {
        Button(title) {}
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
            .buttonStyle(.plain)
    }
}


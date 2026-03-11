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
    @Published var chatMessages: [(role: String, content: String)] = []
    @Published var inputText: String = ""
    @Published var isLoading = false
    @Published var isAgentThinking = false
    @Published var error: String?
    @Published var uiState: CoachOSUIState?
    @Published var currentSubState: String = "overview"
    @Published var blackboardMarkdown: String = ""
    @Published var blockedModules: Set<CoachOSModule> = []
    @Published var externalNavigationTarget: String? = nil

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
        sendText(inputText)
    }

    func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        navigateLocal(to: .plans, subState: "training_detail")
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

    private func extractChatMessages(from messages: [[String: Any]]) -> [(role: String, content: String)] {
        var result: [(role: String, content: String)] = []
        for msg in messages {
            let role = msg["type"] as? String ?? ""
            guard role == "human" || role == "ai" else { continue }
            var content = ""
            if let c = msg["content"] as? String {
                content = c.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let blocks = msg["content"] as? [[String: Any]] {
                let parts = blocks.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                content = parts.joined(separator: " ")
            }
            if !content.isEmpty {
                result.append((role: role, content: content))
            }
        }
        return result
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
            let moduleKey = moduleString.lowercased()

            if ["chat", "conversation", "dialog"].contains(moduleKey) {
                externalNavigationTarget = "chat"
                return
            }
            if ["settings", "profile", "me", "mine"].contains(moduleKey) {
                externalNavigationTarget = "settings"
                return
            }

            let target: CoachOSModule
            if ["coach", "workbench", "coachos"].contains(moduleKey) {
                let tab = (payload["module_tab"] as? String) ?? "home"
                target = CoachOSModule.fromServerModule(tab)
            } else {
                target = CoachOSModule.fromServerModule(moduleString)
            }

            if blockedModules.contains(target) {
                updateCoachReply("当前阶段暂不能进入\(target.title)模块。")
                return
            }

            var resolvedSubState = subState
            if target == .plans {
                if ["today", "plan_today", "training_today"].contains(resolvedSubState) {
                    resolvedSubState = "training_detail"
                } else if ["nutrition", "diet", "meal_plan", "diet_detail"].contains(resolvedSubState) {
                    resolvedSubState = "nutrition_detail"
                }
                if ["nutrition", "diet"].contains(moduleKey), resolvedSubState == "overview" {
                    resolvedSubState = "nutrition_detail"
                }
            }

            selectedModule = target
            currentSubState = resolvedSubState
            if target == .workspace, resolvedSubState == "blackboard" {
                requestBlackboard()
            } else {
                requestModuleData(for: target, subState: resolvedSubState)
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
    private enum PlanExpandedKind {
        case training
        case nutrition
    }

    var onOpenSettings: (() -> Void)? = nil
    var onOpenChat: (() -> Void)? = nil
    var showsCloseButton: Bool = true

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthService
    @StateObject private var viewModel = CoachOSMockViewModel()
    @StateObject private var recorder = AudioRecorder()
    @State private var isDrawerOpen = false
    @FocusState private var isTextFocused: Bool
    @State private var voiceDragOffset: CGFloat = 0
    @State private var userSpin = false
    @State private var isStartingRecording = false
    @State private var spin = false
    @State private var showErrorAlert = false
    @State private var errorAlertMessage = ""
    @State private var expandedPlanKind: PlanExpandedKind?
    @State private var editableExercises: [ExercisePreview] = [
        .init(
            name: "杠铃深蹲",
            sets: 4,
            reps: "8-10",
            weightKg: "60",
            note: "",
            perSetTiming: true,
            difficulty: "正常",
            setRows: [
                .init(setNo: 1, weightKg: "60", reps: "10", done: false),
                .init(setNo: 2, weightKg: "60", reps: "9", done: false),
                .init(setNo: 3, weightKg: "60", reps: "8", done: false),
                .init(setNo: 4, weightKg: "60", reps: "8", done: false),
            ],
            layer: .traditional
        ),
        .init(
            name: "🏃 跑步（轻松跑）",
            sets: 1,
            reps: "8.2 km",
            weightKg: "0",
            note: "配速 5'45\"",
            perSetTiming: false,
            difficulty: "正常",
            setRows: [],
            layer: .template
        ),
        .init(
            name: "🏀 篮球对抗",
            sets: 1,
            reps: "45 min",
            weightKg: "0",
            note: "RPE 7/10",
            perSetTiming: false,
            difficulty: "正常",
            setRows: [],
            layer: .free
        ),
        .init(
            name: "腿举",
            sets: 3,
            reps: "12",
            weightKg: "140",
            note: "",
            perSetTiming: false,
            difficulty: "正常",
            setRows: [
                .init(setNo: 1, weightKg: "140", reps: "12", done: false),
                .init(setNo: 2, weightKg: "140", reps: "12", done: false),
                .init(setNo: 3, weightKg: "140", reps: "12", done: false),
            ],
            layer: .traditional
        ),
    ]
    @State private var nutritionMeals: [NutritionMealPreview] = [
        .init(name: "第1餐", time: "07:30", kcal: 520, macros: "P30/C60/F18", desc: "燕麦 50g + 鸡蛋 2 个 + 牛奶 200ml + 香蕉"),
        .init(name: "第2餐", time: "12:00", kcal: 750, macros: "P45/C85/F24", desc: "米饭 180g + 牛肉 150g + 青椒炒肉 + 紫菜蛋花汤"),
        .init(name: "第3餐", time: "18:30", kcal: 680, macros: "P40/C75/F22", desc: "玉米 1 根 + 三文鱼 120g + 蒜蓉西兰花 + 菌菇汤"),
    ]
    @State private var activityLogs: [ActivityLogPreview] = [
        .init(icon: "🏃", name: "慢跑（轻松）", detail: "30 分钟 · 配速 5'50\"/km · 平均心率 148"),
        .init(icon: "🏀", name: "篮球对抗", detail: "45 分钟 · RPE 7/10 · 热量约 420 kcal"),
    ]
    @AppStorage("apiBaseURL") private var apiBaseURL = "http://139.196.181.42:8000"

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                backgroundLayer

                VStack(spacing: 0) {
                    tabBar

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            moduleContent

                            if let err = viewModel.error {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, viewModel.selectedModule == .training ? 0 : 14)
                        .padding(.bottom, 170)
                    }
                }

                floatingCoach
                floatingUser
                floatingTopControls
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
            .onChange(of: recorder.isRecording) { newValue in
                // 录音时开启旋转动效，停止即关闭
                userSpin = newValue
                if !newValue {
                    isStartingRecording = false
                }
            }
            .onChange(of: viewModel.error) { newValue in
                guard let newValue, !newValue.isEmpty else { return }
                errorAlertMessage = newValue
                showErrorAlert = true
            }
            .onChange(of: viewModel.selectedModule) { _ in
                expandedPlanKind = nil
            }
            .onChange(of: viewModel.externalNavigationTarget) { target in
                guard let target else { return }
                if target == "chat" {
                    onOpenChat?()
                } else if target == "settings" {
                    onOpenSettings?()
                }
                viewModel.externalNavigationTarget = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let screenH = UIScreen.main.bounds.height
                let overlap = max(0, screenH - frame.origin.y)
                withAnimation(.easeInOut(duration: 0.2)) {
                    keyboardHeight = overlap
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    keyboardHeight = 0
                }
            }
            .alert("请求失败", isPresented: $showErrorAlert) {
                Button("我知道了", role: .cancel) {}
            } message: {
                Text(errorAlertMessage)
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

    private var floatingUser: some View {
        GeometryReader { geo in
            // 给左侧教练头像预留空间，避免抽屉遮挡（经验值）
            let reservedLeft: CGFloat = 140
            let maxDrawerWidth = max(220, min(320, geo.size.width - reservedLeft))
            HStack(alignment: .center, spacing: 10) {
                if isDrawerOpen {
                    HStack(spacing: 10) {
                        TextField("输入消息...", text: $viewModel.inputText)
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
                            .focused($isTextFocused)

                        SendButton(enabled: !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            let text = viewModel.inputText
                            viewModel.inputText = ""
                            viewModel.sendText(text)
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                isDrawerOpen = false
                            }
                            isTextFocused = false
                        }
                    }
                    .frame(maxWidth: maxDrawerWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                userAvatarControl
            }
            .padding(.trailing, 16)
            .padding(.bottom, 56 + max(0, keyboardHeight - 24)) // 键盘弹出时同步抬升
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isDrawerOpen)
        }
    }

    private var userAvatarControl: some View {
        let cancelThreshold: CGFloat = -80
        let willCancel = voiceDragOffset < cancelThreshold
        let isRecordingUI = recorder.isRecording || isStartingRecording

        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(Color.orange.opacity(0.25), lineWidth: 1))
                .frame(width: 56, height: 56)

            Image(systemName: isRecordingUI ? "mic.fill" : "person.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(willCancel ? Color.red : Color.orange)

            if isRecordingUI {
                Circle()
                    .trim(from: 0.1, to: 0.82)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [Color.orange.opacity(0.1), Color.orange, Color.orange.opacity(0.15)]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                    )
                    .frame(width: 68, height: 68)
                    .rotationEffect(.degrees(userSpin ? 360 : 0))
                    .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: userSpin)
            }
        }
        .contentShape(Circle())
        .onTapGesture {
            guard !recorder.isRecording && !isStartingRecording else { return }
            let next = !isDrawerOpen
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isDrawerOpen = next
            }
            if next {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isTextFocused = true
                }
            } else {
                isTextFocused = false
            }
        }
        // 长按（>=0.5s）才进入录音态，避免单击误触发
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
                .onEnded { _ in
                    guard !recorder.isRecording else { return }
                    // 进入录音，收起抽屉
                    isTextFocused = false
                    isDrawerOpen = false
                    isStartingRecording = true
                    startVoiceRecording()
                }
        )
        // 录音态才响应上滑取消/松开发送
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard recorder.isRecording else { return }
                    voiceDragOffset = value.translation.height
                }
                .onEnded { _ in
                    defer { voiceDragOffset = 0 }
                    guard recorder.isRecording else { return }
                    if voiceDragOffset < cancelThreshold {
                        cancelVoiceRecording()
                    } else {
                        stopVoiceRecordingAndSend()
                    }
                }
        )
    }

    private var floatingCoach: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        .padding(.leading, 16)
        .padding(.bottom, 56 + max(0, keyboardHeight - 24)) // 键盘弹出时同步抬升
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func startVoiceRecording() {
        Task {
            let granted = await recorder.requestPermission()
            guard granted else {
                await MainActor.run { isStartingRecording = false }
                return
            }
            do {
                try recorder.startRecording()
            } catch {
                // ignore UI error for now
                await MainActor.run { isStartingRecording = false }
            }
        }
    }

    private func stopVoiceRecordingAndSend() {
        guard let data = recorder.stopRecording() else { return }
        let prompt: String? = nil
        Task {
            do {
                let service = VoiceService(baseURL: apiBaseURL, authToken: auth.token)
                let text = try await service.speechToText(audioData: data, contentType: "audio/x-caf", prompt: prompt)
                await MainActor.run {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        viewModel.sendText(text)
                    }
                }
            } catch {
                // ignore UI error for now
            }
        }
    }

    private func cancelVoiceRecording() {
        _ = recorder.stopRecording()
    }

    private var floatingTopControls: some View {
        HStack(spacing: 6) {
            if isTopControlsExpanded {
                VStack(alignment: .trailing, spacing: 8) {
                    if let onOpenChat {
                        floatingEntryButton(
                            title: "纯对话",
                            tint: .orange,
                            action: onOpenChat
                        ) {
                            ZStack {
                                CoachAvatar(size: 34, isSpeaking: false)
                                Image(systemName: "bubble.left.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Color.orange, in: Circle())
                                    .offset(x: 13, y: 12)
                            }
                            .frame(width: 34, height: 34)
                        }
                    }

                    if let onOpenSettings {
                        floatingEntryButton(
                            title: "我的",
                            tint: .blue,
                            action: onOpenSettings
                        ) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.blue)
                                .frame(width: 34, height: 34)
                                .background(Color.blue.opacity(0.12), in: Circle())
                        }
                    }

                    if showsCloseButton {
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
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    isTopControlsExpanded.toggle()
                }
            } label: {
                Image(systemName: isTopControlsExpanded ? "chevron.right.circle.fill" : "chevron.left.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 8)
        .padding(.top, 84)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func floatingEntryButton<Avatar: View>(
        title: String,
        tint: Color,
        action: @escaping () -> Void,
        @ViewBuilder avatar: () -> Avatar
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                avatar()
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color.white.opacity(0.32), lineWidth: 0.8)
            )
            .shadow(color: tint.opacity(0.15), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var moduleContent: some View {
        switch viewModel.selectedModule {
        case .home:
            homeContentFromSections
        case .plans:
            if ["training_detail", "today"].contains(viewModel.currentSubState) {
                plansContentFromSections(forcedExpanded: .training)
            } else if ["nutrition_detail", "diet_detail", "nutrition", "diet"].contains(viewModel.currentSubState) {
                plansContentFromSections(forcedExpanded: .nutrition)
            } else {
                plansContentFromSections()
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
        return VStack(alignment: .leading, spacing: 8) {
            timelineCard
            
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

    private func plansContentFromSections(forcedExpanded: PlanExpandedKind? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            weekStripCard
            ZStack(alignment: .top) {
                if let expanded = forcedExpanded ?? expandedPlanKind {
                    planExpandedCard(for: expanded)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        ))
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        planSummaryCard(
                            title: "训练计划",
                            subtitle: "目标：腿 · 4 个动作",
                            icon: "figure.strengthtraining.traditional",
                            lines: ["杠铃深蹲", "腿举", "腿弯举", "提踵"],
                            tint: .orange
                        ) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                expandedPlanKind = .training
                                viewModel.currentSubState = "training_detail"
                            }
                        }
                        planSummaryCard(
                            title: "饮食计划",
                            subtitle: "目标：2200 kcal",
                            icon: "fork.knife",
                            lines: ["第1餐 520 kcal", "第2餐 750 kcal", "第3餐 680 kcal", "P130/C240/F70"],
                            tint: .teal
                        ) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                expandedPlanKind = .nutrition
                                viewModel.currentSubState = "nutrition_detail"
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private var plansTodayContentFromSections: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日训练计划")
                    .font(.headline)
                Spacer()
                Text("Today")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("腿 · 4 个动作")
                    .font(.headline)
                ForEach(Array(todayExercisePreview.enumerated()), id: \.offset) { idx, item in
                    HStack(spacing: 8) {
                        Text("\(idx + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(item.sets) 组 · \(item.reps)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    viewModel.navigateLocal(to: .training, subState: "session")
                } label: {
                    Text("开始训练")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("今日饮食计划")
                    .font(.headline)
                ForEach(["第1餐 · 520 kcal", "第2餐 · 750 kcal", "第3餐 · 680 kcal"], id: \.self) { meal in
                    HStack {
                        Text(meal)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("目标：2200 kcal · 蛋白 130g · 碳水 240g · 脂肪 70g")
                    .font(.caption)
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

    private struct FoodItem: Identifiable {
        let id = UUID()
        let name: String
        let kcalPer100g: Int
        let p: Double
        let c: Double
        let f: Double
        let unit: String = "100g"
    }

    private struct ActionLibraryItem: Identifiable {
        let id = UUID()
        let name: String
        let sets: Int
        let reps: String
        let defaultWeight: String
    }

    @State private var foodLibrary: [FoodItem] = [
        .init(name: "鸡胸肉", kcalPer100g: 133, p: 24.6, c: 0, f: 1.9),
        .init(name: "糙米饭", kcalPer100g: 111, p: 2.6, c: 23.5, f: 0.9),
        .init(name: "西兰花", kcalPer100g: 34, p: 4.1, c: 4.3, f: 0.6),
        .init(name: "鸡蛋", kcalPer100g: 143, p: 13.3, c: 1.1, f: 8.8),
        .init(name: "牛排", kcalPer100g: 250, p: 27.3, c: 0, f: 15.0),
    ]
    @State private var actionLibrary: [ActionLibraryItem] = [
        .init(name: "卧推", sets: 4, reps: "8-10", defaultWeight: "50"),
        .init(name: "硬拉", sets: 4, reps: "5", defaultWeight: "80"),
        .init(name: "高位下拉", sets: 3, reps: "10-12", defaultWeight: "45"),
        .init(name: "哑铃肩推", sets: 3, reps: "10", defaultWeight: "16"),
        .init(name: "保加利亚分腿蹲", sets: 3, reps: "10", defaultWeight: "18"),
    ]

    @State private var isShowingFoodLibrary = false
    @State private var isShowingCustomFood = false
    @State private var isShowingActionLibrary = false
    @State private var selectedFoodForImport: FoodItem?
    @State private var importFoodAmount: Double = 100
    @State private var customFoodName = ""
    @State private var customFoodKcal = ""
    @State private var customFoodP = ""
    @State private var customFoodC = ""
    @State private var customFoodF = ""

    @State private var activeTrainingExerciseIdx: Int = 0
    @State private var activeTrainingSetIdx: Int = 0
    @State private var isTrainingActive: Bool = false
    @State private var trainingTimer: Int = 0
    @State private var trainingTimerActive: Bool = false
    @State private var isTrainingListExpanded: Bool = true
    @State private var isTopControlsExpanded: Bool = false
    @State private var keyboardHeight: CGFloat = 0

    private var trainingContentFromSections: some View {
        let traditionalExercises = editableExercises.filter { $0.layer == .traditional }
        let safeExerciseIdx = min(activeTrainingExerciseIdx, max(traditionalExercises.count - 1, 0))

        return VStack(alignment: .leading, spacing: 6) {
            // 顶部动作列表，可折叠，固定高度区域
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        isTrainingListExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text("今日动作列表（传统训练）")
                            .font(.headline)
                        Spacer()
                        Image(systemName: isTrainingListExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isTrainingListExpanded {
                    ScrollView {
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(Array(traditionalExercises.enumerated()), id: \.element.id) { idx, exercise in
                                let doneCount = exercise.setRows.filter(\.done).count
                                Button {
                                    activeTrainingExerciseIdx = idx
                                    activeTrainingSetIdx = 0
                                    isTrainingActive = false
                                    trainingTimerActive = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(exercise.name)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                            .foregroundStyle(safeExerciseIdx == idx ? .orange : .primary)
                                        Text("\(doneCount)/\(exercise.setRows.count) 组")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(doneCount >= exercise.setRows.count ? .green : .secondary)
                                        ProgressView(value: exercise.setRows.isEmpty ? 0 : Double(doneCount), total: Double(max(exercise.setRows.count, 1)))
                                            .tint(doneCount >= exercise.setRows.count ? .green : .orange)
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        safeExerciseIdx == idx ? Color.orange.opacity(0.12) : Color.black.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 140, alignment: .top)
                    .clipped()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

            // 底部执行面板，固定高度
            VStack(alignment: .leading, spacing: 12) {
                if traditionalExercises.isEmpty {
                    Text("当前没有传统训练动作，请先在计划中添加。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    let currentExercise = traditionalExercises[safeExerciseIdx]
                    let hasSet = !currentExercise.setRows.isEmpty

                    HStack {
                        Text(currentExercise.name)
                            .font(.title3.weight(.bold))
                        Spacer()
                        Text(hasSet ? "第 \(min(activeTrainingSetIdx + 1, currentExercise.setRows.count)) 组 / 共 \(currentExercise.setRows.count) 组" : "无组次")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if hasSet {
                        let safeSetIdx = min(activeTrainingSetIdx, currentExercise.setRows.count - 1)
                        let currentSet = currentExercise.setRows[safeSetIdx]
                        let doneCount = currentExercise.setRows.filter(\.done).count
                        let plannedCount = max(currentExercise.sets, 1)

                        HStack {
                            Text("当前组 #\(safeSetIdx + 1)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                            Spacer()
                            Text("完成 \(doneCount) / 计划 \(plannedCount)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(doneCount >= plannedCount ? .green : .secondary)
                        }

                        HStack(spacing: 26) {
                            VStack {
                                Text(currentSet.weightKg)
                                    .font(.system(size: 38, weight: .bold, design: .rounded))
                                Text("kg").font(.caption2).foregroundStyle(.secondary)
                            }
                            VStack {
                                Text(currentSet.reps)
                                    .font(.system(size: 38, weight: .bold, design: .rounded))
                                Text("次").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        if trainingTimerActive {
                            Text(formatTime(trainingTimer))
                                .font(.system(size: 44, weight: .light, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity)
                        }

                        HStack(spacing: 10) {
                            if !isTrainingActive {
                                Button {
                                    isTrainingActive = true
                                    trainingTimer = 0
                                    trainingTimerActive = true
                                } label: {
                                    Text("开始本组")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .background(Color.orange, in: Capsule())
                                }
                            }

                            Button {
                                let refId = currentExercise.id
                                if let globalIdx = editableExercises.firstIndex(where: { $0.id == refId }), editableExercises[globalIdx].setRows.indices.contains(safeSetIdx) {
                                    editableExercises[globalIdx].setRows[safeSetIdx].done = true
                                }
                                isTrainingActive = false
                                trainingTimerActive = false

                                if safeSetIdx < currentExercise.setRows.count - 1 {
                                    activeTrainingSetIdx = safeSetIdx + 1
                                } else if safeExerciseIdx < traditionalExercises.count - 1 {
                                    activeTrainingExerciseIdx = safeExerciseIdx + 1
                                    activeTrainingSetIdx = 0
                                } else {
                                    // 超计划组：到末组后继续追加新组并进入（计划组数保持不变）
                                    let nextNo = currentExercise.setRows.count + 1
                                    if let globalIdx = editableExercises.firstIndex(where: { $0.id == refId }) {
                                        editableExercises[globalIdx].setRows.append(
                                            .init(setNo: nextNo, weightKg: currentSet.weightKg, reps: currentSet.reps, done: false)
                                        )
                                        activeTrainingSetIdx = nextNo - 1
                                    }
                                }
                            } label: {
                                Text("完成本组")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.green, in: Capsule())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220, alignment: .top)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .frame(height: 410)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if trainingTimerActive { trainingTimer += 1 }
        }
    }

    private func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
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

    private struct ExercisePreview: Identifiable {
        let id = UUID()
        let name: String
        var sets: Int
        var reps: String
        var weightKg: String
        var note: String
        var perSetTiming: Bool
        var difficulty: String
        var setRows: [SetRowPreview]
        var isExpanded: Bool = false
        var layer: ExerciseLayer = .traditional
    }

    private enum ExerciseLayer: String, CaseIterable {
        case traditional = "传统训练"
        case template = "增强模板"
        case free = "自由记录"
    }

    private struct SetRowPreview: Identifiable {
        let id = UUID()
        var setNo: Int
        var weightKg: String
        var reps: String
        var done: Bool
    }

    private struct NutritionMealPreview: Identifiable {
        let id = UUID()
        var name: String
        var time: String
        var kcal: Int
        var macros: String
        var desc: String
    }

    private struct ActivityLogPreview: Identifiable {
        let id = UUID()
        var icon: String
        var name: String
        var detail: String
    }

    private var todayExercisePreview: [ExercisePreview] {
        editableExercises
    }

    private func addSetRow(for exerciseIndex: Int) {
        guard editableExercises.indices.contains(exerciseIndex) else { return }
        let nextNo = (editableExercises[exerciseIndex].setRows.last?.setNo ?? 0) + 1
        editableExercises[exerciseIndex].setRows.append(
            .init(setNo: nextNo, weightKg: editableExercises[exerciseIndex].weightKg, reps: editableExercises[exerciseIndex].reps, done: false)
        )
        editableExercises[exerciseIndex].sets = editableExercises[exerciseIndex].setRows.count
    }

    private func syncSetNos(for exerciseIndex: Int) {
        guard editableExercises.indices.contains(exerciseIndex) else { return }
        for i in editableExercises[exerciseIndex].setRows.indices {
            editableExercises[exerciseIndex].setRows[i].setNo = i + 1
        }
        editableExercises[exerciseIndex].sets = editableExercises[exerciseIndex].setRows.count
    }

    private var weekStripCard: some View {
        let days = [("日", "8"), ("一", "9"), ("二", "10"), ("三", "11"), ("四", "12"), ("五", "13"), ("六", "14")]
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                    VStack(spacing: 5) {
                        Circle()
                            .fill(idx == 3 ? Color.orange.opacity(0.8) : Color.black.opacity(0.12))
                            .frame(width: 6, height: 6)
                        Text(day.0)
                            .font(.caption2)
                            .foregroundStyle(idx == 3 ? Color.orange : Color.secondary)
                        Text(day.1)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(idx == 3 ? Color.orange : Color.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(idx == 3 ? Color.orange.opacity(0.16) : Color.clear)
                    )
                }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
            )
            Image(systemName: "calendar")
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
                )
        }
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("06:00").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("12:00").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("18:00").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("22:00").font(.caption2).foregroundStyle(.secondary)
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.35), Color.orange.opacity(0.22), Color.black.opacity(0.35)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 26)
                HStack(spacing: 0) {
                    Capsule().fill(Color.orange.opacity(0.75)).frame(width: 4, height: 18).offset(x: 76)
                    Spacer()
                }
                HStack(spacing: 0) {
                    Circle().fill(Color.blue).frame(width: 12, height: 12).offset(x: 160)
                    Spacer()
                }
                HStack(spacing: 0) {
                    Circle().fill(Color.red).frame(width: 12, height: 12).offset(x: 255)
                    Spacer()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: 0.72)
                    .tint(.orange)
                Text("已摄入 1950 / 目标 2200 kcal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    miniMacro(label: "蛋白", value: "118 / 130g", tint: .red)
                    miniMacro(label: "碳水", value: "210 / 240g", tint: .blue)
                    miniMacro(label: "脂肪", value: "58 / 70g", tint: .orange)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.8)
        )
    }

    private func miniMacro(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.opacity(0.25))
                .frame(height: 4)
        }
    }

    private func planSummaryCard(
        title: String,
        subtitle: String,
        icon: String,
        lines: [String],
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(title, systemImage: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(lines, id: \.self) { line in
                    Text("• \(line)")
                        .font(.caption2)
                        .foregroundStyle(.primary.opacity(0.9))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.42), tint.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func planExpandedCard(for kind: PlanExpandedKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                        expandedPlanKind = nil
                        viewModel.currentSubState = "overview"
                    }
                } label: {
                    Label("返回", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(kind == .training ? "训练详情" : "饮食详情")
                    .font(.subheadline.weight(.semibold))
            }
            if kind == .training {
                VStack(alignment: .leading, spacing: 12) {
                    Text("周三 · 腿 · \(editableExercises.count) 个动作")
                        .font(.headline)
                    
                    // 三层模型分类展示
                    ForEach(ExerciseLayer.allCases, id: \.self) { layer in
                        let layerExercises = editableExercises.filter { $0.layer == layer }
                        if !layerExercises.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(layer.rawValue)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.orange)
                                    .padding(.top, 4)
                                
                                ForEach(layerExercises) { exercise in
                                    let idx = editableExercises.firstIndex(where: { $0.id == exercise.id })!
                                    VStack(alignment: .leading, spacing: 10) {
                                        Button {
                                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                                editableExercises[idx].isExpanded.toggle()
                                            }
                                        } label: {
                                            HStack(spacing: 10) {
                                                Circle()
                                                    .fill(layer == .traditional ? Color.orange.opacity(0.1) : Color.gray.opacity(0.1))
                                                    .frame(width: 44, height: 44)
                                                    .overlay(
                                                        Image(systemName: layer == .traditional ? "figure.strengthtraining.traditional" : (layer == .template ? "bolt.fill" : "pencil.and.outline"))
                                                            .font(.system(size: 18))
                                                            .foregroundStyle(layer == .traditional ? .orange : .secondary)
                                                    )
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(editableExercises[idx].name)
                                                        .font(.subheadline.weight(.semibold))
                                                    Text(layer == .traditional ? "\(editableExercises[idx].setRows.count) 组" : editableExercises[idx].reps)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                Button(role: .destructive) {
                                                    editableExercises.remove(at: idx)
                                                } label: {
                                                    Image(systemName: "trash")
                                                        .font(.caption2)
                                                        .foregroundStyle(.red)
                                                }
                                                .buttonStyle(.plain)

                                                Image(systemName: editableExercises[idx].isExpanded ? "chevron.up" : "chevron.down")
                                                    .font(.caption2.weight(.bold))
                                                    .foregroundStyle(.blue)
                                            }
                                        }
                                        .buttonStyle(.plain)

                                        if editableExercises[idx].isExpanded {
                                            VStack(alignment: .leading, spacing: 10) {
                                                if layer == .traditional {
                                                    // 传统训练的详细编辑
                                                    TextField("点击输入备注", text: $editableExercises[idx].note)
                                                        .textFieldStyle(.plain)
                                                        .font(.subheadline)
                                                        .padding(.vertical, 6)
                                                        .padding(.horizontal, 10)
                                                        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

                                                    ForEach(editableExercises[idx].setRows.indices, id: \.self) { setIdx in
                                                        HStack(spacing: 8) {
                                                            Text("\(editableExercises[idx].setRows[setIdx].setNo)")
                                                                .font(.subheadline.weight(.semibold))
                                                                .frame(width: 40, height: 40)
                                                                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                                                            VStack(alignment: .leading, spacing: 1) {
                                                                TextField("重量", text: $editableExercises[idx].setRows[setIdx].weightKg)
                                                                    .keyboardType(.decimalPad)
                                                                    .font(.subheadline.weight(.semibold))
                                                            }
                                                            .frame(width: 65, height: 40)
                                                            .padding(.horizontal, 4)
                                                            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                                                            VStack(alignment: .leading, spacing: 1) {
                                                                TextField("次数", text: $editableExercises[idx].setRows[setIdx].reps)
                                                                    .keyboardType(.numberPad)
                                                                    .font(.subheadline.weight(.semibold))
                                                            }
                                                            .frame(width: 65, height: 40)
                                                            .padding(.horizontal, 4)
                                                            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                                                            Button {
                                                                editableExercises[idx].setRows[setIdx].done.toggle()
                                                            } label: {
                                                                Image(systemName: editableExercises[idx].setRows[setIdx].done ? "checkmark.circle.fill" : "checkmark")
                                                                    .font(.system(size: 20, weight: .semibold))
                                                                    .foregroundStyle(editableExercises[idx].setRows[setIdx].done ? Color.green : Color.gray)
                                                                    .frame(width: 40, height: 40)
                                                                    .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                                            }
                                                            .buttonStyle(.plain)
                                                        }
                                                    }
                                                    
                                                    Button { addSetRow(for: idx) } label: {
                                                        Text("+ 新增一组").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                                                    }
                                                } else {
                                                    // 通用/自由记录的编辑
                                                    VStack(alignment: .leading, spacing: 8) {
                                                        TextField("数值 (如: 8.2 km / 45 min)", text: $editableExercises[idx].reps)
                                                            .textFieldStyle(.roundedBorder)
                                                        TextField("备注 (如: 配速 / RPE)", text: $editableExercises[idx].note)
                                                            .textFieldStyle(.roundedBorder)
                                                    }
                                                    .font(.caption)
                                                }
                                            }
                                            .padding(.leading, 54)
                                            .transition(.opacity)
                                        }
                                    }
                                    .padding(10)
                                    .background(Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            isShowingActionLibrary = true
                        } label: {
                            Label("从动作库新增", systemImage: "plus.square.on.square")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }

                        Button {
                            viewModel.navigateLocal(to: .training, subState: "session")
                        } label: {
                            Text("开始传统训练")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
                )
                .sheet(isPresented: $isShowingActionLibrary) {
                    NavigationStack {
                        List(actionLibrary) { item in
                            Button {
                                let rows = (1...item.sets).map { no in
                                    SetRowPreview(setNo: no, weightKg: item.defaultWeight, reps: item.reps, done: false)
                                }
                                editableExercises.append(
                                    .init(
                                        name: item.name,
                                        sets: item.sets,
                                        reps: item.reps,
                                        weightKg: item.defaultWeight,
                                        note: "",
                                        perSetTiming: false,
                                        difficulty: "正常",
                                        setRows: rows,
                                        layer: .traditional
                                    )
                                )
                                isShowingActionLibrary = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.subheadline.weight(.semibold))
                                        Text("\(item.sets) 组 · \(item.reps) · 默认 \(item.defaultWeight)kg")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .navigationTitle("动作库")
                        .toolbar { Button("关闭") { isShowingActionLibrary = false } }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("今日饮食目标：2200 kcal")
                        .font(.headline)
                    
                    ForEach(nutritionMeals) { meal in
                        let mIdx = nutritionMeals.firstIndex(where: { $0.id == meal.id })!
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("餐次名称", text: $nutritionMeals[mIdx].name)
                                    .font(.subheadline.weight(.bold))
                                Spacer()
                                TextField("时间", text: $nutritionMeals[mIdx].time)
                                    .font(.caption)
                                    .frame(width: 50)
                                Button {
                                    nutritionMeals.remove(at: mIdx)
                                } label: {
                                    Image(systemName: "trash").font(.caption).foregroundStyle(.red)
                                }
                            }
                            
                            HStack {
                                VStack(alignment: .leading) {
                                    TextField("描述", text: $nutritionMeals[mIdx].desc)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(nutritionMeals[mIdx].macros)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    HStack(spacing: 2) {
                                        TextField("热量", value: $nutritionMeals[mIdx].kcal, formatter: NumberFormatter())
                                            .font(.subheadline.weight(.semibold))
                                            .frame(width: 40)
                                            .multilineTextAlignment(.trailing)
                                        Text("kcal").font(.caption2)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                    
                    HStack(spacing: 12) {
                        Button { isShowingFoodLibrary = true } label: {
                            Label("食物库导入", systemImage: "magnifyingglass")
                                .font(.caption.weight(.semibold))
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color.blue.opacity(0.1), in: Capsule())
                        }
                        
                        Button { isShowingCustomFood = true } label: {
                            Label("自定义添加", systemImage: "plus")
                                .font(.caption.weight(.semibold))
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color.orange.opacity(0.1), in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
                )
                .sheet(isPresented: $isShowingFoodLibrary) {
                    NavigationStack {
                        List(foodLibrary) { food in
                            Button {
                                importFoodAmount = 100
                                isShowingFoodLibrary = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    selectedFoodForImport = food
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(food.name).font(.headline)
                                        Text("P:\(food.p, specifier: "%.1f") C:\(food.c, specifier: "%.1f") F:\(food.f, specifier: "%.1f")").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(food.kcalPer100g) kcal").font(.subheadline.weight(.bold))
                                }
                            }
                        }
                        .navigationTitle("食物库")
                        .toolbar { Button("关闭") { isShowingFoodLibrary = false } }
                    }
                }
                .sheet(isPresented: $isShowingCustomFood) {
                    NavigationStack {
                        Form {
                            Section("基本信息") {
                                TextField("食物名称", text: $customFoodName)
                                TextField("热量 (kcal)", text: $customFoodKcal).keyboardType(.numberPad)
                            }
                            Section("营养素 (可选)") {
                                TextField("蛋白质 (g)", text: $customFoodP).keyboardType(.decimalPad)
                                TextField("碳水 (g)", text: $customFoodC).keyboardType(.decimalPad)
                                TextField("脂肪 (g)", text: $customFoodF).keyboardType(.decimalPad)
                            }
                        }
                        .navigationTitle("自定义添加")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { isShowingCustomFood = false } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("添加") {
                                    nutritionMeals.append(.init(
                                        name: customFoodName,
                                        time: "12:00",
                                        kcal: Int(customFoodKcal) ?? 0,
                                        macros: "P\(customFoodP)/C\(customFoodC)/F\(customFoodF)",
                                        desc: "自定义添加"
                                    ))
                                    isShowingCustomFood = false
                                }
                            }
                        }
                    }
                }
                .sheet(item: $selectedFoodForImport) { food in
                    NavigationStack {
                        let ratio = importFoodAmount / 100.0
                        let kcal = Int((Double(food.kcalPer100g) * ratio).rounded())
                        let p = food.p * ratio
                        let c = food.c * ratio
                        let f = food.f * ratio

                        Form {
                            Section("食物") {
                                Text(food.name)
                                Text("每100g: \(food.kcalPer100g) kcal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Section("摄入量") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(Int(importFoodAmount)) g")
                                        .font(.headline)
                                    Slider(value: $importFoodAmount, in: 20...500, step: 10)
                                }
                            }

                            Section("本次摄入估算") {
                                Text("热量: \(kcal) kcal")
                                Text(String(format: "蛋白 %.1fg · 碳水 %.1fg · 脂肪 %.1fg", p, c, f))
                            }
                        }
                        .navigationTitle("按摄入量导入")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("取消") { selectedFoodForImport = nil }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("添加") {
                                    nutritionMeals.append(
                                        .init(
                                            name: food.name,
                                            time: "12:00",
                                            kcal: kcal,
                                            macros: String(format: "P%.1f/C%.1f/F%.1f", p, c, f),
                                            desc: "食物库导入 · \(Int(importFoodAmount))g"
                                        )
                                    )
                                    selectedFoodForImport = nil
                                }
                            }
                        }
                    }
                }
            }
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

    private func tinyAction(_ title: String, action: @escaping () -> Void = {}) -> some View {
        Button(title, action: action)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
            .buttonStyle(.plain)
    }
}


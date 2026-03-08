import SwiftUI

struct CoachUICard: Identifiable {
    let id: String
    let title: String
    let value: String
    let priority: String?
}

struct CoachUIAction: Identifiable {
    let id: String
    let label: String
    let risk: String?
    let kind: String?
}

struct CoachUIState {
    let protocolVersion: String
    let module: String
    let subState: String
    let title: String
    let coachMessage: String
    let cards: [CoachUICard]
    let actions: [CoachUIAction]
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var uiState: CoachUIState?
    @Published var isLoading = false
    @Published var error: String?

    private var apiClient: APIClient?
    private var threadId: String?

    func setAPIClient(_ client: APIClient) {
        apiClient = client
    }

    func loadHomeUIState() {
        guard !isLoading, let client = apiClient else { return }
        isLoading = true
        error = nil
        Task { @MainActor in
            defer { self.isLoading = false }
            do {
                let tid = try await ensureThread(using: client)
                let msg = buildHumanMessage(text: "打开首页模块，返回当前页面状态")
                let output = try await client.waitRun(threadId: tid, messages: [msg])
                let rawMessages = extractMessages(from: output)
                if let parsed = parseLatestUIState(from: rawMessages) {
                    self.uiState = parsed
                } else {
                    self.error = "未解析到页面状态，请稍后重试"
                }
            } catch {
                self.error = error.localizedDescription
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

    private func parseLatestUIState(from messages: [[String: Any]]) -> CoachUIState? {
        for msg in messages.reversed() {
            guard (msg["type"] as? String) == "ai" else { continue }
            if let state = parseUIState(from: msg) {
                return state
            }
        }
        return nil
    }

    private func parseUIState(from aiMessage: [String: Any]) -> CoachUIState? {
        // 兼容 top-level additional_kwargs
        if let kwargs = aiMessage["additional_kwargs"] as? [String: Any],
           let ui = kwargs["ui_state"] as? [String: Any],
           let parsed = mapToState(ui) {
            return parsed
        }
        // 兼容 LangGraph 序列化到 kwargs.additional_kwargs
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

    private func mapToState(_ raw: [String: Any]) -> CoachUIState? {
        guard let protocolVersion = raw["protocol_version"] as? String,
              let module = raw["module"] as? String,
              let subState = raw["sub_state"] as? String,
              let title = raw["title"] as? String,
              let coachMessage = raw["coach_message"] as? String else {
            return nil
        }

        let cards: [CoachUICard] = (raw["cards"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String,
                  let cardTitle = item["title"] as? String,
                  let value = item["value"] as? String else {
                return nil
            }
            return CoachUICard(id: id, title: cardTitle, value: value, priority: item["priority"] as? String)
        }

        let actions: [CoachUIAction] = (raw["actions"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String,
                  let label = item["label"] as? String else {
                return nil
            }
            return CoachUIAction(id: id, label: label, risk: item["risk"] as? String, kind: item["kind"] as? String)
        }

        return CoachUIState(
            protocolVersion: protocolVersion,
            module: module,
            subState: subState,
            title: title,
            coachMessage: coachMessage,
            cards: cards,
            actions: actions
        )
    }
}

struct DashboardView: View {
    let onOpenChat: () -> Void
    @EnvironmentObject private var auth: AuthService
    @StateObject private var viewModel = DashboardViewModel()
    @AppStorage("apiBaseURL") private var apiBaseURL = "http://139.196.181.42:8000"

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("AI 操作系统")
                                .font(.title2)
                                .fontWeight(.bold)
                            Spacer()
                            Button {
                                viewModel.loadHomeUIState()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let err = viewModel.error {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if let ui = viewModel.uiState {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(ui.title)
                                    .font(.headline)
                                Text("模块：\(ui.module) · 状态：\(ui.subState)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(ui.coachMessage)
                                    .font(.subheadline)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                            ForEach(ui.cards) { card in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(card.title).font(.headline)
                                        Spacer()
                                        if let priority = card.priority {
                                            Text(priority.uppercased())
                                                .font(.caption2)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.orange.opacity(0.15), in: Capsule())
                                        }
                                    }
                                    Text(card.value)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            }

                            if !ui.actions.isEmpty {
                                Text("可操作动作")
                                    .font(.headline)
                                    .padding(.top, 4)
                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                    ForEach(ui.actions) { action in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(action.label).font(.subheadline)
                                            Text(action.kind ?? "execute")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                            }
                        } else if viewModel.isLoading {
                            ProgressView("加载页面状态...")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 20)
                        } else {
                            Text("点击右上角刷新，获取 AI 当前页面状态")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }

                Button {
                    onOpenChat()
                } label: {
                    CoachAvatar(size: 58, isSpeaking: viewModel.isLoading)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "bubble.left.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Color.orange, in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("首页")
            .onAppear {
                guard auth.isLoggedIn else { return }
                let url = apiBaseURL.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
                viewModel.setAPIClient(APIClient(baseURL: url, authToken: auth.token))
                if viewModel.uiState == nil {
                    viewModel.loadHomeUIState()
                }
            }
        }
    }
}

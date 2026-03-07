import Foundation
import Combine

struct ChatMessage: Identifiable {
    let id: String
    let isHuman: Bool
    let text: String
    var timestamp: Date?
}

/// 工具结果项（用于折叠展示）
struct ToolResultItem: Identifiable {
    let id: String
    let name: String
    let result: String
}

/// 展示块：用户消息 | AI 块（含文本 + 可折叠的工具调用/结果）
enum ChatDisplayBlock: Identifiable {
    case human(id: String, text: String, timestamp: Date?)
    case aiBlock(id: String, aiText: String, toolCalls: [(name: String, args: String)], toolResults: [ToolResultItem], timestamp: Date?)

    var id: String {
        switch self {
        case .human(let id, _, _), .aiBlock(let id, _, _, _, _): return id
        }
    }
}

private let threadIdKey = "fit-swift-thread-id"

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var displayBlocks: [ChatDisplayBlock] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var currentAIResponse = ""
    @Published var isRestoringHistory = false

    private var threadId: String? {
        didSet {
            if let id = threadId {
                UserDefaults.standard.set(id, forKey: threadIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: threadIdKey)
            }
        }
    }

    private var apiClient: APIClient
    private var streamTask: Task<Void, Never>?
    private var sendInProgress = false
    private var hasLiveMessages = false
    var useWaitMode = false  // true: 用 wait 非流式，稳定；false: 用 stream 流式

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
        self.threadId = UserDefaults.standard.string(forKey: threadIdKey)
    }

    func setAPIClient(_ client: APIClient) {
        apiClient = client
    }

    /// 恢复历史状态（fetchStateHistory），在登录后调用。
    /// 始终调用 get-or-create 以服务端 users.active_thread_id 为准，与 Web 行为一致。
    func restoreStateIfNeeded() async {
        DebugLogger.shared.log("restoreState: 开始")
        do {
            threadId = try await apiClient.getOrCreateThread()
            DebugLogger.shared.log("restoreState: getOrCreateThread 完成")
        } catch {
            threadId = nil
            DebugLogger.shared.log("restoreState: getOrCreateThread 失败 \(error)")
            return
        }
        guard let tid = threadId, !tid.isEmpty else { return }
        isRestoringHistory = true
        defer { isRestoringHistory = false }
        do {
            DebugLogger.shared.log("restoreState: getThreadState 开始")
            let state = try await apiClient.getThreadState(threadId: tid)
            DebugLogger.shared.log("restoreState: getThreadState 完成")
            if let values = state["values"] as? [String: Any],
               let rawMsgs = values["messages"] as? [[String: Any]], !rawMsgs.isEmpty {
                DebugLogger.shared.log("restoreState: 解析 \(rawMsgs.count) 条消息")
                displayBlocks = buildDisplayBlocks(from: rawMsgs)
                messages = rawMsgs.compactMap { m -> ChatMessage? in
                    let type = m["type"] as? String ?? ""
                    let text = extractText(from: m)
                    guard !text.isEmpty else { return nil }
                    let id = m["id"] as? String ?? UUID().uuidString
                    let ts = (m["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                        ?? (m["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                    return ChatMessage(id: id, isHuman: type == "human", text: text, timestamp: ts)
                }
            }
        } catch {
            DebugLogger.shared.log("restoreState: getThreadState 失败 \(error)")
            threadId = nil
            UserDefaults.standard.removeObject(forKey: threadIdKey)
        }
        DebugLogger.shared.log("restoreState: 结束")
    }

    /// 用户登出时清除 threadId（下次登录会 get-or-create 拿回同一 thread）
    func onLogout() {
        streamTask?.cancel()
        streamTask = nil
        sendInProgress = false
        threadId = nil
        messages = []
        displayBlocks = []
        currentAIResponse = ""
        error = nil
    }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLoading, !sendInProgress else { return }
        sendInProgress = true
        DebugLogger.shared.log("send: 用户发送消息")

        let now = Date()
        let humanMsg = ChatMessage(id: UUID().uuidString, isHuman: true, text: trimmed, timestamp: now)
        messages.append(humanMsg)
        displayBlocks.append(.human(id: humanMsg.id, text: trimmed, timestamp: now))
        currentAIResponse = ""
        hasLiveMessages = false
        error = nil

        streamTask = Task { @MainActor in
            await runStream(humanMessage: trimmed, timestamp: now)
        }
    }

    /// 将原始消息分组为展示块：human 独立；ai + 其后的 tool 归为一个 aiBlock
    /// 使用消息 id 保持稳定，避免流式更新时闪烁
    nonisolated private func buildDisplayBlocks(from rawMsgs: [[String: Any]]) -> [ChatDisplayBlock] {
        var blocks: [ChatDisplayBlock] = []
        var i = 0
        while i < rawMsgs.count {
            let m = rawMsgs[i]
            let msgType = m["type"] as? String ?? ""
            let msgId = m["id"] as? String ?? UUID().uuidString
            switch msgType {
            case "human":
                let t = extractText(from: m)
                if !t.isEmpty {
                    let ts = (m["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                        ?? (m["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                    blocks.append(.human(id: "h-\(msgId)", text: t, timestamp: ts))
                }
                i += 1
            case "ai":
                let aiText = extractText(from: m)
                var toolCalls: [(name: String, args: String)] = []
                if let tcs = m["tool_calls"] as? [[String: Any]] {
                    for tc in tcs {
                        let name = tc["name"] as? String ?? "tool"
                        let args = (tc["args"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        toolCalls.append((name, args))
                    }
                }
                var toolResults: [ToolResultItem] = []
                i += 1
                while i < rawMsgs.count, (rawMsgs[i]["type"] as? String) == "tool" {
                    let tm = rawMsgs[i]
                    let name = tm["name"] as? String ?? "tool"
                    let result = tm["content"] as? String ?? extractText(from: tm)
                    let trId = (tm["id"] as? String) ?? UUID().uuidString
                    toolResults.append(ToolResultItem(id: trId, name: name, result: result))
                    i += 1
                }
                let ts = (m["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                    ?? (m["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                blocks.append(.aiBlock(id: "a-\(msgId)", aiText: aiText, toolCalls: toolCalls, toolResults: toolResults, timestamp: ts))
            case "tool":
                let last = blocks.last
                if case .aiBlock(let id, let aiText, let tcs, var trs, let ts) = last {
                    let name = m["name"] as? String ?? "tool"
                    let result = m["content"] as? String ?? extractText(from: m)
                    let trId = (m["id"] as? String) ?? UUID().uuidString
                    trs.append(ToolResultItem(id: trId, name: name, result: result))
                    blocks[blocks.count - 1] = .aiBlock(id: id, aiText: aiText, toolCalls: tcs, toolResults: trs, timestamp: ts)
                }
                i += 1
            default:
                i += 1
            }
        }
        return blocks
    }

    nonisolated private func extractText(from msg: [String: Any]) -> String {
        if let content = msg["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        if let content = msg["content"] as? String { return content }
        if let kwargs = msg["kwargs"] as? [String: Any], let c = kwargs["content"] as? String { return c }
        if let text = msg["text"] as? String { return text }
        return ""
    }

    nonisolated private func extractAIText(from msg: [String: Any]) -> String? {
        if let type = msg["type"] as? String, type != "ai" {
            return nil
        }
        let text = extractText(from: msg)
        return text.isEmpty ? nil : text
    }

    private func runStream(humanMessage: String, timestamp: Date) async {
        isLoading = true
        DebugLogger.shared.log("runStream: 开始")
        defer {
            isLoading = false
            sendInProgress = false
            DebugLogger.shared.log("runStream: 结束")
        }

        do {
            if threadId == nil {
                DebugLogger.shared.log("runStream: getOrCreateThread 开始")
                threadId = try await apiClient.getOrCreateThread()
                DebugLogger.shared.log("runStream: getOrCreateThread 完成")
            }
            guard let tid = threadId else { return }

            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone.current
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let ts = formatter.string(from: timestamp)
            let tz = TimeZone.current.identifier
            let inputMessages: [[String: Any]] = [
                [
                    "type": "human",
                    "content": [["type": "text", "text": humanMessage]],
                    "timestamp": ts,
                    "timezone": tz,
                ],
            ]

            if useWaitMode {
                await runWait(threadId: tid, inputMessages: inputMessages)
                return
            }

            DebugLogger.shared.log("runStream: streamRun 请求开始")
            var eventCount = 0
            hasLiveMessages = false

            for try await evt in try await apiClient.streamRun(threadId: tid, messages: inputMessages) {
                if Task.isCancelled { break }
                eventCount += 1
                
                guard let data = evt.data else { continue }

                // 使用异步后台解析，避免阻塞读取循环，降低 CPU 压力
                let eventType = evt.event
                let eventData = data
                Task.detached(priority: .userInitiated) { [weak self] in
                    guard let self = self else { return }
                    if let update = self.parseStreamEvent(event: eventType, data: eventData) {
                        await MainActor.run { self.applyStreamUpdate(update) }
                    }
                }
            }

            DebugLogger.shared.log("runStream: 流结束，共 \(eventCount) 个事件")
            await MainActor.run {
                // 流结束后，确保最终回复被持久化到 messages 列表
                if !currentAIResponse.isEmpty {
                    let alreadyExists = messages.contains { $0.text == currentAIResponse && !$0.isHuman }
                    if !alreadyExists {
                        let aiMsg = ChatMessage(id: UUID().uuidString, isHuman: false, text: currentAIResponse, timestamp: Date())
                        messages.append(aiMsg)
                    }
                }
                currentAIResponse = ""
                hasLiveMessages = false
            }
            // 使用 updates 时，流结束后同步全量历史，避免只剩最新一条
            await refreshThreadStateIfPossible()
        } catch {
            self.error = error.localizedDescription
            DebugLogger.shared.log("runStream: 错误 \(error)")
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isLoading = false
        sendInProgress = false
    }

    /// 非流式：等待 run 完成，解析 values.messages 更新展示
    private func runWait(threadId: String, inputMessages: [[String: Any]]) async {
        DebugLogger.shared.log("runWait: 开始")
        do {
            let output = try await apiClient.waitRun(threadId: threadId, messages: inputMessages)
            DebugLogger.shared.log("runWait: 响应收到 keys=\(Array(output.keys))")
            let rawMsgs: [[String: Any]]
            if let m = output["messages"] as? [[String: Any]] {
                rawMsgs = m
            } else if let vals = output["values"] as? [String: Any], let m = vals["messages"] as? [[String: Any]] {
                rawMsgs = m
            } else if let out = output["output"] as? [String: Any], let m = out["messages"] as? [[String: Any]] {
                rawMsgs = m
            } else if let out = output["output"] as? [String: Any], let vals = out["values"] as? [String: Any], let m = vals["messages"] as? [[String: Any]] {
                rawMsgs = m
            } else {
                DebugLogger.shared.log("runWait: 无 messages, keys=\(Array(output.keys))")
                return
            }
            let blocks = buildDisplayBlocks(from: rawMsgs)
            displayBlocks = blocks
            if let lastAI = blocks.compactMap({ b -> String? in
                if case .aiBlock(_, let t, _, _, _) = b { return t }; return nil
            }).last {
                let aiMsg = ChatMessage(id: UUID().uuidString, isHuman: false, text: lastAI, timestamp: Date())
                messages.append(aiMsg)
            }
            DebugLogger.shared.log("runWait: 完成")
        } catch {
            self.error = error.localizedDescription
            DebugLogger.shared.log("runWait: 失败 \(error)")
        }
    }

    private enum StreamKind {
        case values
        case updates
        case messagesPartial
        case messagesComplete
    }

    private struct StreamUpdate {
        let kind: StreamKind
        let text: String?
        let blocks: [ChatDisplayBlock]?
    }

    nonisolated private func parseStreamEvent(event: String, data: [String: Any]) -> StreamUpdate? {
        var newAIText: String? = nil
        var newBlocks: [ChatDisplayBlock]? = nil

        if event == "values" || event.hasPrefix("values") {
            let rawMsgs: [[String: Any]]
            if let m = data["messages"] as? [[String: Any]] {
                rawMsgs = m
            } else if let vals = data["values"] as? [String: Any], let m = vals["messages"] as? [[String: Any]] {
                rawMsgs = m
            } else {
                return nil
            }

            let streamBlocks = buildDisplayBlocks(from: rawMsgs)
            let lastAI = streamBlocks.compactMap { b -> String? in
                if case .aiBlock(_, let t, _, _, _) = b { return t }; return nil
            }.last

            newBlocks = streamBlocks
            newAIText = lastAI
        } else if event == "updates" || event.hasPrefix("updates") {
            // updates 可能只包含增量，避免覆盖完整历史
            if let rawMsgs = extractMessagesFromUpdates(data) {
                // 仅用于取最新 AI 文本，不更新 blocks
                let streamBlocks = buildDisplayBlocks(from: rawMsgs)
                let lastAI = streamBlocks.compactMap { b -> String? in
                    if case .aiBlock(_, let t, _, _, _) = b { return t }; return nil
                }.last
                newAIText = lastAI
            } else {
                return nil
            }
        } else if event == "messages/partial" || event.hasPrefix("messages/partial") {
            if let array = data["messages"] as? [[String: Any]] {
                for msg in array {
                    if let t = extractAIText(from: msg) { newAIText = t }
                }
            } else if let t = extractAIText(from: data) {
                newAIText = t
            }
        } else if event == "messages/complete" || event.hasPrefix("messages/complete") {
            if let t = extractAIText(from: data) {
                newAIText = t
            }
        } else if event == "on_custom_event" {
            if let name = data["name"] as? String, name == "memory_debug",
               let payload = data["data"] as? [String: Any],
               let msg = payload["message"] as? String {
                Task { @MainActor in
                    DebugLogger.shared.log(msg)
                }
            }
            return nil
        } else {
            return nil
        }

        let kind: StreamKind
        if event == "values" || event.hasPrefix("values") {
            kind = .values
        } else if event == "updates" || event.hasPrefix("updates") {
            kind = .updates
        } else if event == "messages/complete" || event.hasPrefix("messages/complete") {
            kind = .messagesComplete
        } else {
            kind = .messagesPartial
        }
        return StreamUpdate(kind: kind, text: newAIText, blocks: newBlocks)
    }

    private func applyStreamUpdate(_ update: StreamUpdate) {
        if let blocks = update.blocks {
            displayBlocks = blocks
        }

        // 只有 messages 流才驱动实时文本，values/updates 仅用于结构更新
        if update.kind == .messagesPartial || update.kind == .messagesComplete {
            hasLiveMessages = true
        }

        if let rawText = update.text {
            let cleanText = sanitizeAIText(rawText)
            if !cleanText.isEmpty {
                // values/updates 永不覆盖实时文本，避免回闪/混杂
                if update.kind == .messagesPartial || update.kind == .messagesComplete {
                    if currentAIResponse != cleanText {
                        currentAIResponse = cleanText
                    }
                }
            }
        }
    }

    nonisolated private func sanitizeAIText(_ text: String) -> String {
        var cleaned = text
        // 移除 <think>...</think> 段落（兼容多段）
        if let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: []) {
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.utf16.count), withTemplate: "")
        }
        cleaned = cleaned.replacingOccurrences(of: "</think>", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshThreadStateIfPossible() async {
        guard let tid = threadId, !tid.isEmpty else { return }
        do {
            let state = try await apiClient.getThreadState(threadId: tid)
            if let values = state["values"] as? [String: Any],
               let rawMsgs = values["messages"] as? [[String: Any]], !rawMsgs.isEmpty {
                let blocks = buildDisplayBlocks(from: rawMsgs)
                let msgs = rawMsgs.compactMap { m -> ChatMessage? in
                    let type = m["type"] as? String ?? ""
                    let text = extractText(from: m)
                    guard !text.isEmpty else { return nil }
                    let id = m["id"] as? String ?? UUID().uuidString
                    let ts = (m["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                        ?? (m["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                    return ChatMessage(id: id, isHuman: type == "human", text: text, timestamp: ts)
                }
                await MainActor.run {
                    displayBlocks = blocks
                    messages = msgs
                }
            }
        } catch {
            DebugLogger.shared.log("refreshThreadState: 失败 \(error)")
        }
    }

    nonisolated private func extractMessagesFromUpdates(_ data: [String: Any]) -> [[String: Any]]? {
        // updates 可能是 {node: {messages: [...]}} 或嵌套在 values/updates 字段中
        if let direct = data["messages"] as? [[String: Any]] {
            return direct
        }
        if let updates = data["updates"] as? [String: Any] {
            return extractMessagesFromUpdates(updates)
        }
        for (_, value) in data {
            if let dict = value as? [String: Any] {
                if let msgs = dict["messages"] as? [[String: Any]] {
                    return msgs
                }
            }
        }
        return nil
    }
}

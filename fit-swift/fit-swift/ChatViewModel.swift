import Foundation
import Combine

struct ChatMessage: Identifiable {
    let id: String
    let isHuman: Bool
    let text: String
}

/// 工具结果项（用于折叠展示）
struct ToolResultItem: Identifiable {
    let id: String
    let name: String
    let result: String
}

/// 展示块：用户消息 | AI 块（含文本 + 可折叠的工具调用/结果）
enum ChatDisplayBlock: Identifiable {
    case human(id: String, text: String)
    case aiBlock(id: String, aiText: String, toolCalls: [(name: String, args: String)], toolResults: [ToolResultItem])

    var id: String {
        switch self {
        case .human(let id, _), .aiBlock(let id, _, _, _): return id
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
        do {
            threadId = try await apiClient.getOrCreateThread()
        } catch {
            threadId = nil
            return
        }
        guard let tid = threadId, !tid.isEmpty else { return }
        isRestoringHistory = true
        defer { isRestoringHistory = false }
        do {
            let state = try await apiClient.getThreadState(threadId: tid)
            if let values = state["values"] as? [String: Any],
               let rawMsgs = values["messages"] as? [[String: Any]], !rawMsgs.isEmpty {
                displayBlocks = buildDisplayBlocks(from: rawMsgs)
                messages = rawMsgs.compactMap { m -> ChatMessage? in
                    let type = m["type"] as? String ?? ""
                    let text = extractText(from: m)
                    guard !text.isEmpty else { return nil }
                    let id = m["id"] as? String ?? UUID().uuidString
                    return ChatMessage(id: id, isHuman: type == "human", text: text)
                }
            }
        } catch {
            // Token 失效或线程不存在，清除持久化
            threadId = nil
            UserDefaults.standard.removeObject(forKey: threadIdKey)
        }
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

        let humanMsg = ChatMessage(id: UUID().uuidString, isHuman: true, text: trimmed)
        messages.append(humanMsg)
        if threadId == nil {
            displayBlocks = [.human(id: humanMsg.id, text: trimmed)]
        } else {
            displayBlocks.append(.human(id: humanMsg.id, text: trimmed))
        }
        currentAIResponse = ""
        error = nil

        streamTask = Task {
            await runStream(humanMessage: trimmed)
        }
    }

    /// 将原始消息分组为展示块：human 独立；ai + 其后的 tool 归为一个 aiBlock
    /// 使用消息 id 保持稳定，避免流式更新时闪烁
    private func buildDisplayBlocks(from rawMsgs: [[String: Any]]) -> [ChatDisplayBlock] {
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
                    blocks.append(.human(id: "h-\(msgId)", text: t))
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
                blocks.append(.aiBlock(id: "a-\(msgId)", aiText: aiText, toolCalls: toolCalls, toolResults: toolResults))
            case "tool":
                let last = blocks.last
                if case .aiBlock(let id, let aiText, let tcs, var trs) = last {
                    let name = m["name"] as? String ?? "tool"
                    let result = m["content"] as? String ?? extractText(from: m)
                    let trId = (m["id"] as? String) ?? UUID().uuidString
                    trs.append(ToolResultItem(id: trId, name: name, result: result))
                    blocks[blocks.count - 1] = .aiBlock(id: id, aiText: aiText, toolCalls: tcs, toolResults: trs)
                }
                i += 1
            default:
                i += 1
            }
        }
        return blocks
    }

    private func extractText(from msg: [String: Any]) -> String {
        if let content = msg["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        if let content = msg["content"] as? String { return content }
        if let kwargs = msg["kwargs"] as? [String: Any], let c = kwargs["content"] as? String { return c }
        return ""
    }

    private func runStream(humanMessage: String) async {
        isLoading = true
        defer {
            isLoading = false
            sendInProgress = false
        }

        do {
            if threadId == nil {
                threadId = try await apiClient.getOrCreateThread()
            }
            guard let tid = threadId else { return }

            // 只发送本条新消息，thread 已有历史；避免重复发送
            let inputMessages: [[String: Any]] = [
                ["type": "human", "content": [["type": "text", "text": humanMessage]]],
            ]

            var fullAI = ""
            var streamBlocks: [ChatDisplayBlock] = []

            for try await chunk in try await apiClient.streamRun(threadId: tid, messages: inputMessages) {
                if Task.isCancelled { break }
                // 支持 values（快照）和 messages（增量）两种格式
                let rawMsgs: [[String: Any]]
                if let vals = chunk["values"] as? [String: Any], let m = vals["messages"] as? [[String: Any]] {
                    rawMsgs = m
                } else if let m = chunk["messages"] as? [[String: Any]] {
                    rawMsgs = m
                } else {
                    continue
                }

                streamBlocks = buildDisplayBlocks(from: rawMsgs)
                if let lastAI = streamBlocks.compactMap({ b -> String? in
                    if case .aiBlock(_, let t, _, _) = b { return t }; return nil
                }).last {
                    fullAI = lastAI
                    currentAIResponse = lastAI
                }
                // 避免用旧状态覆盖：若 stream 返回的块数少于当前（如首帧尚未包含新 human），不替换
                if streamBlocks.count >= displayBlocks.count {
                    displayBlocks = streamBlocks
                }
            }

            if !fullAI.isEmpty {
                let aiMsg = ChatMessage(id: UUID().uuidString, isHuman: false, text: fullAI)
                messages.append(aiMsg)
                // aiText 已在 stream 循环中按顺序添加，此处仅更新 messages
            }
            currentAIResponse = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isLoading = false
        sendInProgress = false
    }
}

# iOS 流式对话实现说明

## 两种模式

| 模式 | 接口 | 说明 |
|------|------|------|
| **流式 (stream)** | POST /threads/{id}/runs/stream | SSE 流式，默认启用 |
| **非流式 (wait)** | POST /threads/{id}/runs/wait | 等待完成一次性返回，稳定可靠 |

设置 → 齿轮 → 勾选「非流式(wait)」即用 wait 模式。

### 请求 payload (stream_mode)

```json
{
  "assistant_id": "agent",
  "input": {"messages": [...]},
  "stream": true,
  "stream_mode": ["values", "messages"],
  "stream_subgraphs": false
}
```

- `values`：完整 state 快照，每节点执行后发送
- `messages`：逐 token 流式，发送 `messages/partial`、`messages/complete`

## Aegra 流式协议（实测 wire 格式）

参考 [Streaming](https://docs.aegra.dev/guides/streaming)，mock 实测输出：

```
event: metadata
data: {"run_id": "mock-run-1"}

event: messages/partial
data: {"content": [{"type": "text", "text": "你"}]}

event: messages/partial
data: {"content": [{"type": "text", "text": "好"}]}
...（逐字）

event: messages/complete
data: {"type": "ai", "content": [{"type": "text", "text": "你好！你说了：hi"}]}

event: values
data: {"messages": [{"type":"human",...}, {"type":"ai",...}]}

event: end
data: {}
```

- **messages/partial**：`data.content` 为 `[{type:"text", text:"x"}]`，每次一个 token
- **values**：`data.messages` 直接是消息数组（不是 `data.values.messages`）

## 理想中的简单流程

```
用户发送 → 后端流式返回 SSE → 每收到一块就更新 UI
```

## 当前实现流程

### 1. 发送 (send)
- 用户输入 → `send(text)` 
- 立即把 human 消息加入 `displayBlocks` 和 `messages`
- 启动 `streamTask` 调用 `runStream(humanMessage)`

### 2. 流式请求 (runStream)
- 若没有 threadId，先 `getOrCreateThread()`
- 调用 `apiClient.streamRun(threadId, inputMessages)` 
- `inputMessages` 只含本条新消息：`[{ type: "human", content: [...] }]`
- 后端会把新消息追加到 thread 的 messages 里

### 3. SSE 解析 (APIClient.streamRun)
- POST `/threads/{id}/runs/stream`，`stream_mode: ["values", "messages"]`
- 用 `URLSession.bytes` 逐字节读，按 SSE 格式解析（`event:`、`data:`、空行）
- 每解析完一个事件就 `yield(StreamEvent)` 给调用方

### 4. 消费流 (runStream 的 for-await)
- `for try await evt in stream`
- **metadata**：跳过（仅 run_id 等元信息）
- **messages/partial**：逐 token 流式，累积到 `currentAIResponse` 并更新 UI
- **messages/complete**：完整消息，更新 `currentAIResponse`
- **values**：完整 state，用 `buildDisplayBlocks` 更新 `displayBlocks`
- 从 `evt.data` 取 messages：
  - `data["messages"]` 或
  - `data["values"]["messages"]`
- 用 `buildDisplayBlocks(rawMsgs)` 转成展示块
- 用 `MainActor.run` 更新 `displayBlocks` 和 `currentAIResponse`

### 5. 展示 (ChatView)
- `displayBlocks` 非空 → `ForEach(displayBlocks)` 展示
- `displayBlocks` 为空 → `ForEach(messages)` 展示（兜底）
- `currentAIResponse` 非空且最后一块不是 aiBlock → 额外显示流式气泡

## 可能的问题点

1. **只处理 values**：若后端主要靠 `messages` 事件做逐 token 流式，我们收不到
2. **values 结构**：若 `messages` 不在 `data["messages"]` 或 `data["values"]["messages"]`，会 `continue` 跳过
3. **主线程更新**：已用 `MainActor.run`，但 `runStream` 在 `Task {}` 里，可能仍有线程问题
4. **展示逻辑**：`displayBlocks` 与 `messages` 双轨，条件复杂，可能漏展示

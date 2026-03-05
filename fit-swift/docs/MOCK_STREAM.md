# Mock 流式接口测试

用于验证 iOS 端 SSE 解析逻辑，不依赖真实后端。

## 启动 Mock

```bash
cd /path/to/fit-agent
uvicorn scripts.mock_stream_server:app --port 8765 --reload
```

## iOS 配置

1. **API 地址**：设置 → API 地址 → `http://localhost:8765`（模拟器）或 `http://<Mac IP>:8765`（真机）
2. **登录**：任意邮箱密码（mock 不校验）
3. **流式模式**：设置 → 关闭「非流式(wait)」

## Mock 返回格式（对齐 Aegra）

```
event: metadata
data: {"run_id": "mock-run-1"}

event: messages/partial
data: {"content": [{"type": "text", "text": "你"}]}

event: messages/partial
data: {"content": [{"type": "text", "text": "好"}]}
...

event: messages/complete
data: {"type": "ai", "content": [{"type": "text", "text": "你好！你说了：xxx"}]}

event: values
data: {"messages": [human_msg, ai_msg]}

event: end
data: {}
```

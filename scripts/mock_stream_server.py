#!/usr/bin/env python3
"""
Mock Aegra 流式接口，用于验证 iOS 端 SSE 解析逻辑。

按 https://docs.aegra.dev/guides/streaming 的格式返回事件：
  metadata -> messages/partial (逐字) -> messages/complete -> values -> end

运行:
  uvicorn scripts.mock_stream_server:app --port 8765 --reload
  或: python scripts/mock_stream_server.py

iOS 测试:
  1. 在「我的」→ 设置 → API 地址 改为 http://localhost:8765 (模拟器)
  2. 真机用 http://<Mac IP>:8765，需 Mac 与手机同网
  3. 可用任意邮箱密码登录（mock 不校验）
  4. 关闭「非流式(wait)」以测试流式
"""
import asyncio
import json
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse

@asynccontextmanager
async def lifespan(app: FastAPI):
    print("Mock stream server: http://0.0.0.0:8765")
    print("iOS: 设置 API 地址为 http://localhost:8765 (模拟器)")
    yield


# 无需认证，仅用于本地调试
app = FastAPI(title="Mock Aegra Stream", lifespan=lifespan)


@app.post("/auth/login")
async def mock_login(request: Request):
    """Mock: 接受任意邮箱密码，返回假 token（仅用于本地调试）"""
    body = await request.json()
    email = body.get("email", "test@mock.local")
    return {
        "access_token": f"mock-token-{email}",
        "token_type": "bearer",
        "user": {"id": "mock-user-1", "email": email, "display_name": "Mock User"},
    }


@app.post("/auth/register")
async def mock_register(request: Request):
    """Mock: 接受任意注册，返回假 token"""
    body = await request.json()
    email = body.get("email", "test@mock.local")
    return {
        "access_token": f"mock-token-{email}",
        "token_type": "bearer",
        "user": {"id": "mock-user-1", "email": email, "display_name": body.get("display_name", "Mock User")},
    }


@app.post("/threads/get-or-create")
async def get_or_create():
    """Mock: 返回固定 thread_id"""
    return {"thread_id": "mock-thread-1"}


@app.get("/threads/{thread_id}/state")
async def get_state(thread_id: str):
    """Mock: 返回空历史"""
    return {"values": {"messages": []}}


@app.post("/threads/{thread_id}/runs/stream")
async def stream_run(thread_id: str, request: Request):
    """
    Mock: 按 Aegra 格式返回 SSE 流。
    事件顺序: metadata -> messages/partial (逐字) -> messages/complete -> values -> end
    """
    body = await request.json()
    messages = body.get("input", {}).get("messages", [])
    user_text = ""
    for m in messages:
        if m.get("type") == "human":
            content = m.get("content", [])
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "text":
                        user_text = c.get("text", "")
                        break
            break

    reply = f"你好！你说了：{user_text}" if user_text else "你好！"

    async def generate():
        # 1. metadata
        yield f"event: metadata\ndata: {json.dumps({'run_id': 'mock-run-1'})}\n\n"
        await asyncio.sleep(0.05)

        # 2. messages/partial (逐字流式)
        for char in reply:
            chunk = {"content": [{"type": "text", "text": char}]}
            yield f"event: messages/partial\ndata: {json.dumps(chunk, ensure_ascii=False)}\n\n"
            await asyncio.sleep(0.05)

        # 3. messages/complete
        complete = {
            "type": "ai",
            "content": [{"type": "text", "text": reply}],
        }
        yield f"event: messages/complete\ndata: {json.dumps(complete, ensure_ascii=False)}\n\n"
        await asyncio.sleep(0.05)

        # 4. values (完整 state)
        human_msg = {
            "type": "human",
            "id": "msg-1",
            "content": [{"type": "text", "text": user_text or "（空）"}],
        }
        ai_msg = {
            "type": "ai",
            "id": "msg-2",
            "content": [{"type": "text", "text": reply}],
        }
        values = {"messages": [human_msg, ai_msg]}
        yield f"event: values\ndata: {json.dumps(values, ensure_ascii=False)}\n\n"
        await asyncio.sleep(0.05)

        # 5. end
        yield "event: end\ndata: {}\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.post("/threads/{thread_id}/runs/wait")
async def wait_run(thread_id: str, request: Request):
    """Mock: 非流式，一次性返回"""
    body = await request.json()
    messages = body.get("input", {}).get("messages", [])
    user_text = ""
    for m in messages:
        if m.get("type") == "human":
            content = m.get("content", [])
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "text":
                        user_text = c.get("text", "")
                        break
            break

    reply = f"你好！你说了：{user_text}" if user_text else "你好！"
    human_msg = {"type": "human", "id": "msg-1", "content": [{"type": "text", "text": user_text or "（空）"}]}
    ai_msg = {"type": "ai", "id": "msg-2", "content": [{"type": "text", "text": reply}]}
    return {"values": {"messages": [human_msg, ai_msg]}}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8765)

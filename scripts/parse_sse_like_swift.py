#!/usr/bin/env python3
"""
模拟 Swift 端 SSE 解析逻辑，用 mock 输出验证。
运行 mock 后执行此脚本，确认解析结果。
"""
import json
import sys

RAW = """event: metadata
data: {"run_id": "mock-run-1"}

event: messages/partial
data: {"content": [{"type": "text", "text": "你"}]}

event: messages/partial
data: {"content": [{"type": "text", "text": "好"}]}

event: messages/complete
data: {"type": "ai", "content": [{"type": "text", "text": "你好"}]}

event: values
data: {"messages": [{"type": "human", "id": "msg-1", "content": [{"type": "text", "text": "hi"}]}, {"type": "ai", "id": "msg-2", "content": [{"type": "text", "text": "你好"}]}]}

event: end
data: {}
"""


def extract_text(data: dict) -> str:
    """与 Swift extractText 一致"""
    if content := data.get("content"):
        if isinstance(content, list):
            return " ".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("text"))
    if isinstance(data.get("content"), str):
        return data["content"]
    if text := data.get("text"):
        return text
    return ""


def parse_sse(raw: str):
    """模拟 Swift APIClient 的 SSE 解析"""
    buffer = ""
    current_event = ""
    data_lines = []
    events = []

    def flush():
        nonlocal current_event, data_lines
        if data_lines:
            joined = "\n".join(data_lines)
            try:
                data = json.loads(joined)
            except json.JSONDecodeError:
                data = None
            event_type = current_event if current_event else "values"
            events.append((event_type, data))
        current_event = ""
        data_lines = []

    for line in raw.split("\n"):
        trimmed = line.strip()
        if trimmed == "":
            flush()
            continue
        if trimmed.startswith("event:"):
            current_event = trimmed[6:].strip()
        elif trimmed.startswith("data:"):
            data_lines.append(trimmed[5:].strip())
        elif trimmed.startswith("{"):
            data = json.loads(trimmed)
            events.append(("values", data))

    flush()
    return events


def main():
    events = parse_sse(RAW)
    full_ai = ""
    display_blocks = []

    for i, (event_type, data) in enumerate(events):
        print(f"#{i+1} event={event_type} data_keys={list(data.keys()) if data else []}")

        if not data:
            continue

        if event_type == "metadata":
            print("  -> skip metadata")
            continue
        if event_type == "end":
            print("  -> skip end")
            continue

        if event_type == "messages/partial":
            chunk = extract_text(data)
            if chunk:
                full_ai += chunk
                print(f"  -> partial chunk='{chunk}' full_ai='{full_ai}'")
            continue

        if event_type == "messages/complete":
            text = extract_text(data)
            if text:
                full_ai = text
                print(f"  -> complete full_ai='{full_ai}'")
            continue

        if event_type == "values":
            raw_msgs = data.get("messages") or (data.get("values") or {}).get("messages")
            if raw_msgs:
                display_blocks = raw_msgs
                last_ai = None
                for m in reversed(raw_msgs):
                    if m.get("type") == "ai":
                        last_ai = extract_text(m)
                        break
                if last_ai:
                    full_ai = last_ai
                print(f"  -> values display_blocks={len(display_blocks)} last_ai='{full_ai}'")
            else:
                print(f"  -> values 无 messages!")

    print("\n=== 最终 ===")
    print(f"full_ai: {full_ai}")
    print(f"display_blocks: {len(display_blocks)} 条")


if __name__ == "__main__":
    main()

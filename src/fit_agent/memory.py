"""Memory utilities for context compression and long-term storage."""

from __future__ import annotations

import asyncio
import json
import os
import random
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Iterable, List, Tuple

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage, ToolMessage

from fit_agent.database import get_db
from fit_agent.db import MemorySummary, MessageMemory

MEMORY_WINDOW_SIZE = int(os.environ.get("MEMORY_WINDOW_SIZE", "10"))
FORGET_BASE = float(os.environ.get("MEMORY_FORGET_BASE", "0.08"))
FORGET_TIME_FACTOR = float(os.environ.get("MEMORY_FORGET_TIME_FACTOR", "0.35"))
FORGET_IMPORTANCE_FACTOR = float(os.environ.get("MEMORY_FORGET_IMPORTANCE_FACTOR", "0.25"))
FORGET_MAX = float(os.environ.get("MEMORY_FORGET_MAX", "0.75"))


@dataclass
class MemorySnapshot:
    summary: str | None
    key_facts: list[str]
    scenarios: list[str]
    global_background: str | None
    meta_data: dict[str, Any]
    updated_at: datetime | None


def _role_of(msg: Any) -> str:
    if isinstance(msg, HumanMessage):
        return "human"
    if isinstance(msg, AIMessage):
        return "ai"
    if isinstance(msg, ToolMessage):
        return "tool"
    if isinstance(msg, BaseMessage):
        return msg.type
    if isinstance(msg, dict):
        return msg.get("type") or msg.get("role") or "unknown"
    return "unknown"


def _text_of(msg: Any) -> str:
    if isinstance(msg, BaseMessage):
        content = msg.content
    elif isinstance(msg, dict):
        content = msg.get("content", "")
    else:
        content = ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        # langchain content blocks
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
        return " ".join([p for p in parts if p])
    return str(content)


def _tool_name_of(msg: Any) -> str | None:
    if isinstance(msg, ToolMessage):
        return getattr(msg, "name", None)
    if isinstance(msg, dict):
        return msg.get("name")
    return None


def get_memory_snapshot(user_id: str) -> MemorySnapshot:
    # 强制不使用缓存，每次直接从数据库读取最新状态
    from fit_agent.database import SessionLocal
    with SessionLocal() as db:
        row = db.query(MemorySummary).filter_by(user_id=user_id).first()
        if not row:
            return MemorySnapshot(
                summary=None,
                key_facts=[],
                scenarios=[],
                global_background=None,
                meta_data={},
                updated_at=None,
            )
        
        # 确保读取的是最原始的数据库值
        key_facts = row.key_facts or []
        if isinstance(key_facts, dict):
            key_facts = list(key_facts.values())
        scenarios = row.scenarios or []
        if isinstance(scenarios, dict):
            scenarios = list(scenarios.values())
            
        return MemorySnapshot(
            summary=row.summary_text,
            key_facts=key_facts,
            scenarios=scenarios,
            global_background=row.global_background,
            meta_data=row.meta_data or {},
            updated_at=row.updated_at,
        )


def build_memory_context(user_id: str) -> str:
    snap = get_memory_snapshot(user_id)
    parts = []
    if snap.global_background:
        parts.append(f"【长期背景】\n{snap.global_background}")
    if snap.scenarios:
        scenarios = "\n".join(f"- {s}" for s in snap.scenarios if s)
        parts.append(f"【当前活跃情境】\n{scenarios}")
    if snap.summary:
        parts.append(f"【近期对话摘要】\n{snap.summary}")
    if snap.key_facts:
        facts = "\n".join(f"- {f}" for f in snap.key_facts if f)
        parts.append(f"【教练注意点】\n{facts}")
    return "\n\n".join(parts).strip()


def apply_forgetting_to_messages(user_id: str, messages: list[Any]) -> list[Any]:
    if not messages:
        return messages
    keep_last = MEMORY_WINDOW_SIZE
    total = len(messages)
    cutoff = max(total - keep_last, 0)
    if cutoff <= 0:
        return messages

    snap = get_memory_snapshot(user_id)
    hours_gap = 0.0
    if snap.updated_at:
        hours_gap = max(0.0, (datetime.now(timezone.utc) - snap.updated_at).total_seconds() / 3600.0)
    time_boost = min(0.2, hours_gap / 72.0)  # 最多 +0.2

    new_messages: list[Any] = []
    with get_db() as db:
        seen: dict[str, MessageMemory] = {}
        for idx, msg in enumerate(messages):
            role = _role_of(msg)
            tool_name = _tool_name_of(msg)
            msg_id = getattr(msg, "id", None)
            
            if role not in ("human", "ai"):
                # 最近窗口外的 mark_task_done 工具消息直接过滤
                if role == "tool" and tool_name == "mark_task_done" and idx < cutoff:
                    continue
                new_messages.append(msg)
                continue
            text = _text_of(msg)
            if idx >= cutoff:
                new_messages.append(msg)
                continue

            if not msg_id:
                new_messages.append(msg)
                continue

            record = seen.get(msg_id)
            if record is None:
                record = db.query(MessageMemory).filter_by(user_id=user_id, message_id=msg_id).first()
                if record:
                    seen[msg_id] = record
            importance = record.importance_score if record else 3
            if record and record.memory_state == "forgotten":
                new_messages.append(_replace_content(msg, "已忘记"))
                continue

            time_weight = (cutoff - idx) / max(cutoff, 1)
            importance_weight = (importance - 1) / 4.0
            forget_prob = FORGET_BASE + (FORGET_TIME_FACTOR * time_weight) + time_boost - (
                FORGET_IMPORTANCE_FACTOR * importance_weight
            )
            forget_prob = min(max(forget_prob, 0.0), FORGET_MAX)

            if random.random() < forget_prob:
                if record:
                    record.memory_state = "forgotten"
                    record.updated_at = datetime.now(timezone.utc)
                else:
                    record = MessageMemory(
                        user_id=user_id,
                        message_id=msg_id,
                        role=role,
                        content=text,
                        importance_score=importance,
                        memory_state="forgotten",
                    )
                    db.add(record)
                    seen[msg_id] = record
                new_messages.append(_replace_content(msg, "已忘记"))
            else:
                new_messages.append(msg)
    return new_messages


def _replace_content(msg: Any, content: str) -> Any:
    if isinstance(msg, BaseMessage):
        return msg.copy(update={"content": content})
    if isinstance(msg, dict):
        new_msg = dict(msg)
        new_msg["content"] = content
        return new_msg
    return msg


async def update_memory_for_window(user_id: str, messages: list[Any], model, on_debug_log=None) -> None:
    # 1. 获取当前记忆状态
    snap = get_memory_snapshot(user_id)
    last_id = snap.meta_data.get("last_summarized_message_id")
    
    async def log(msg: str):
        full_msg = f"[MEMORY DEBUG] {msg}"
        print(full_msg, flush=True)
        if on_debug_log:
            await on_debug_log(msg)

    await log(f"用户: {user_id} | 锚点 ID: {last_id or '无'}")

    # 2. 定位新增消息
    new_msgs = []
    if last_id:
        found_last = False
        for msg in messages:
            msg_id = getattr(msg, "id", None)
            if found_last:
                new_msgs.append(msg)
            elif msg_id == last_id:
                found_last = True
        
        if not found_last:
            await log("未找到锚点 ID，回退截取。")
            if len(messages) >= MEMORY_WINDOW_SIZE:
                new_msgs = messages[-MEMORY_WINDOW_SIZE:]
            else:
                await log(f"消息总数 {len(messages)} 未达窗口阈值，跳过。")
                return
    else:
        await log("首次摘要触发检查。")
        if len(messages) >= MEMORY_WINDOW_SIZE:
            new_msgs = messages[-MEMORY_WINDOW_SIZE:]
        else:
            await log(f"消息总数 {len(messages)} 未达窗口阈值，跳过。")
            return

    # 3. 强制限制：无论新增多少，只取最后 MEMORY_WINDOW_SIZE 条进行摘要
    if len(new_msgs) > MEMORY_WINDOW_SIZE:
        await log(f"新增消息数 {len(new_msgs)} 超过窗口，截取最后 {MEMORY_WINDOW_SIZE} 条。")
        new_msgs = new_msgs[-MEMORY_WINDOW_SIZE:]

    await log(f"当前窗口计数: {len(new_msgs)} / {MEMORY_WINDOW_SIZE}")

    # 4. 严格检查：只有当真正的新消息数量达到窗口大小时才触发
    if len(new_msgs) < MEMORY_WINDOW_SIZE:
        await log(f"增量不足 ({len(new_msgs)} < {MEMORY_WINDOW_SIZE})，等待下一轮。")
        return

    await log("触发摘要与打分任务...")

    # 5. 准备序列化数据：使用短 ID (m1, m2...) 映射大幅精简 Prompt
    short_id_map = {}
    slim_items = []
    for idx, msg in enumerate(new_msgs):
        role = _role_of(msg)
        if role == "tool": continue
        text = _text_of(msg).strip()
        if not text: continue
        
        short_id = f"m{len(slim_items) + 1}"
        msg_id = getattr(msg, "id", None)
        
        # 存储原始映射
        short_id_map[short_id] = {
            "message_id": msg_id,
            "role": role,
            "content": text
        }
        # 精简后的项：r=role, c=content
        slim_items.append({
            "id": short_id,
            "r": "u" if role == "human" else "a",
            "c": text
        })

    if not slim_items:
        await log("无效消息内容，跳过。")
        return

    # 6. 调用 LLM 进行增量摘要和打分
    summary_payload = await _summarize_and_score(model, snap, slim_items)
    if not summary_payload:
        await log("LLM 响应解析失败。")
        return

    summary_text = summary_payload.get("summary")
    key_facts = summary_payload.get("key_facts") or []
    scenarios = summary_payload.get("scenarios") or []
    global_background = summary_payload.get("global_background")
    
    # 7. 逆向映射：将短 ID 映射回真实 ID 和内容
    scores = []
    id_to_score = summary_payload.get("scores") or {} # 格式 {"m1": 5, "m2": 3}
    
    # 兼容旧格式或数组格式
    if isinstance(id_to_score, list):
        # 如果模型返回了列表 [{"id": "m1", "s": 5}]
        temp_list = id_to_score
        id_to_score = {}
        for item in temp_list:
            sid = item.get("id") or item.get("message_id")
            score = item.get("s") or item.get("importance") or 3
            if sid: id_to_score[sid] = score

    for short_id, score in id_to_score.items():
        if short_id in short_id_map:
            original = short_id_map[short_id]
            scores.append({
                "message_id": original["message_id"],
                "role": original["role"],
                "content": original["content"],
                "importance": score
            })

    embeddings = None # 移除 embedding 生成

    # 8. 记录最后一条已摘要的消息 ID
    new_last_id = getattr(new_msgs[-1], "id", None)
    new_meta = dict(snap.meta_data)
    if new_last_id:
        new_meta["last_summarized_message_id"] = new_last_id
        await log(f"更新锚点 ID 为: {new_last_id}")

    # 9. 持久化到数据库
    from fit_agent.database import SessionLocal
    from sqlalchemy.orm.attributes import flag_modified
    import json
    try:
        with SessionLocal() as db:
            row = db.query(MemorySummary).filter_by(user_id=user_id).first()
            
            # 彻底解决 psycopg3 无法适配 dict 的问题：
            # 既然驱动无法自动适配，我们手动序列化为 JSON 字符串
            # SQLAlchemy 会在发送给数据库时将其视为合法的 JSONB 输入
            def ensure_json_string(val):
                if val is None:
                    return None
                if isinstance(val, (dict, list)):
                    return json.dumps(val, ensure_ascii=False)
                return val

            processed_key_facts = ensure_json_string(key_facts)
            processed_scenarios = ensure_json_string(scenarios)
            processed_meta = ensure_json_string(new_meta)
            processed_global_background = ensure_json_string(global_background)

            if not row:
                row = MemorySummary(
                    user_id=user_id,
                    summary_text=summary_text,
                    key_facts=processed_key_facts,
                    scenarios=processed_scenarios,
                    global_background=processed_global_background,
                    meta_data=processed_meta,
                )
                db.add(row)
            else:
                row.summary_text = summary_text
                row.key_facts = processed_key_facts
                row.scenarios = processed_scenarios
                row.global_background = processed_global_background
                
                row.meta_data = processed_meta
                # 注意：当手动传入 JSON 字符串给 JSONB 字段时，通常不需要 flag_modified
                # 但为了保险起见，我们保留它
                flag_modified(row, "meta_data")
                flag_modified(row, "key_facts")
                flag_modified(row, "scenarios")
                row.updated_at = datetime.now(timezone.utc)
            
            db.commit()
            # 再次确认数据库中的值
            db.refresh(row)
            await log(f"数据库更新成功。新锚点已持久化: {row.meta_data.get('last_summarized_message_id') if isinstance(row.meta_data, dict) else '已更新'}")

            # 处理消息打分
            for idx, item in enumerate(scores):
                msg_id = item.get("message_id")
                score = item.get("importance", 3)
                role = item.get("role")
                content = item.get("content", "")
                if not msg_id:
                    continue
                
                record = db.query(MessageMemory).filter_by(user_id=user_id, message_id=msg_id).first()
                if record:
                    record.importance_score = score
                    record.updated_at = datetime.now(timezone.utc)
                else:
                    record = MessageMemory(
                        user_id=user_id,
                        message_id=msg_id,
                        role=role,
                        content=content,
                        importance_score=score,
                        memory_state="active",
                    )
                    db.add(record)
            db.commit()
            await log("消息打分持久化成功。")
    except Exception as e:
        await log(f"数据库持久化失败: {str(e)}")
        import traceback
        print(traceback.format_exc())


def _serialize_messages(messages: Iterable[Any]) -> list[dict[str, Any]]:
    items = []
    for msg in messages:
        role = _role_of(msg)
        if role == "tool":
            continue
        text = _text_of(msg).strip()
        if not text:
            continue
        message_hash = _hash_message(role, text)
        items.append({"message_hash": message_hash, "role": role, "content": text})
    return items


async def _summarize_and_score(model, snap: MemorySnapshot, items: list[dict[str, Any]]) -> dict[str, Any] | None:
    prompt = _build_memory_prompt(snap, items)
    # 显式传入空 callbacks 列表，确保该后台调用产生的事件不会被推送到主对话的 SSE 流中，
    # 同时也避免在 LangSmith 中干扰主对话的显示。
    response = await model.ainvoke(prompt, config={"callbacks": []})
    content = getattr(response, "content", "")
    if isinstance(content, list):
        content = " ".join(
            block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text"
        )
    parsed = _extract_json(content)
    return parsed


def _build_memory_prompt(snap: MemorySnapshot, items: list[dict[str, Any]]) -> list[BaseMessage]:
    summary = snap.summary or "无"
    key_facts = snap.key_facts or []
    scenarios = snap.scenarios or []
    global_background = snap.global_background or "无"

    system_msg = SystemMessage(
        content=(
            "你是健身教练的长期记忆系统。你的任务是维护用户的【情境模型列表】和【长期背景】。\n\n"
            "核心概念：\n"
            "1. 【长期背景 (Global Background)】：用户的基本信息（如：姓名、健身目标、身体状况、偏好）。\n"
            "2. 【情境模型 (Scenarios)】：当前正在进行的具体话题或任务（如：[制定下周计划]、[讨论膝盖疼痛]）。每个情境应包含其当前状态或最新进展。\n"
            "3. 【近期摘要 (Summary)】：对最近几轮对话的简要流向描述。\n\n"
            "你的任务：\n"
            "- 根据新增消息，更新或新增情境模型。如果某个情境已结束，请将其核心信息移入长期背景并从列表中移除。\n"
            "- 更新长期背景（如果有新发现的硬信息）。\n"
            "- 更新近期摘要。\n"
            "- 为新增消息打分（1-5分，5分最重要）。\n\n"
            "输出要求：严格 JSON 格式，禁止任何解释性文字。"
        )
    )

    user_msg = HumanMessage(
        content=(
            f"--- 现有记忆状态 ---\n"
            f"长期背景：{global_background}\n"
            f"当前情境：{scenarios}\n"
            f"近期摘要：{summary}\n"
            f"关键事实：{key_facts}\n\n"
            f"--- 新增消息列表 (r=role, c=content) ---\n"
            f"{json.dumps(items, ensure_ascii=False, indent=2)}\n\n"
            "请输出更新后的状态。注意：打分列表 scores 采用 {id: score} 格式，如 {\"m1\": 5, \"m2\": 3}。\n\n"
            "输出格式示例：\n"
            "{\n"
            '  "global_background": "...",\n'
            '  "scenarios": ["[情境A]: 进展...", "[情境B]: 进展..."],\n'
            '  "summary": "...",\n'
            '  "key_facts": ["事实1", "事实2"],\n'
            '  "scores": {"m1": 5, "m2": 3}\n'
            "}\n"
        )
    )
    return [system_msg, user_msg]


def _extract_json(text: str) -> dict[str, Any] | None:
    if not text:
        return None
    text = text.strip()
    # 去除代码块
    text = re.sub(r"^```json", "", text, flags=re.IGNORECASE).strip()
    text = re.sub(r"```$", "", text).strip()
    # 尝试找到 JSON 对象
    match = re.search(r"\{[\s\S]*\}", text)
    if not match:
        return None
    try:
        return json.loads(match.group(0))
    except json.JSONDecodeError:
        return None

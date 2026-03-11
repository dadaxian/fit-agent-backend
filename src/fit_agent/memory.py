"""Memory utilities for context compression and long-term storage."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
import random
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Iterable, List, Tuple

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage, ToolMessage

from fit_agent.database import SessionLocal
from fit_agent.db import MemorySummary, MessageMemory

logger = logging.getLogger(__name__)

# --- Configuration ---
MEMORY_WINDOW_SIZE = int(os.environ.get("MEMORY_WINDOW_SIZE", "10"))
MEMORY_MAX_WINDOW = int(os.environ.get("MEMORY_MAX_WINDOW", "20"))
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

# --- Message Helpers ---

def _role_of(msg: Any) -> str:
    if isinstance(msg, HumanMessage): return "human"
    if isinstance(msg, AIMessage): return "ai"
    if isinstance(msg, ToolMessage): return "tool"
    if isinstance(msg, BaseMessage): return msg.type
    if isinstance(msg, dict): return msg.get("type") or msg.get("role") or "unknown"
    return "unknown"

def _text_of(msg: Any) -> str:
    if isinstance(msg, BaseMessage): content = msg.content
    elif isinstance(msg, dict): content = msg.get("content", "")
    else: content = ""
    
    if isinstance(content, str): return content
    if isinstance(content, list):
        parts = [block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text"]
        return " ".join([p for p in parts if p])
    return str(content)

def _tool_name_of(msg: Any) -> str | None:
    if isinstance(msg, ToolMessage): return getattr(msg, "name", None)
    if isinstance(msg, dict): return msg.get("name")
    return None

def _replace_content(msg: Any, content: str) -> Any:
    if isinstance(msg, BaseMessage): return msg.copy(update={"content": content})
    if isinstance(msg, dict):
        new_msg = dict(msg)
        new_msg["content"] = content
        return new_msg
    return msg

# --- Database Operations ---

def get_memory_snapshot(user_id: str) -> MemorySnapshot:
    """从数据库获取最新的记忆快照，强制不使用缓存。"""
    t0 = time.perf_counter()
    with SessionLocal() as db:
        row = db.query(MemorySummary).filter_by(user_id=user_id).first()
        if not row:
            logger.info("[TIMING] memory: get_memory_snapshot %.3fs (no row)", time.perf_counter() - t0)
            return MemorySnapshot(None, [], [], None, {}, None)
        
        def _parse_json(val, default):
            if val is None: return default
            if isinstance(val, (dict, list)): return val
            try: return json.loads(val)
            except: return default

        out = MemorySnapshot(
            summary=row.summary_text,
            key_facts=_parse_json(row.key_facts, []),
            scenarios=_parse_json(row.scenarios, []),
            global_background=row.global_background,
            meta_data=_parse_json(row.meta_data, {}),
            updated_at=row.updated_at,
        )
        logger.info("[TIMING] memory: get_memory_snapshot %.3fs", time.perf_counter() - t0)
        return out

async def _save_memory_state(user_id: str, payload: dict, new_meta: dict, scores: list, log_fn):
    """持久化摘要、背景、情境及消息评分。"""
    from sqlalchemy.orm.attributes import flag_modified
    
    def _to_json(val):
        return json.dumps(val, ensure_ascii=False) if isinstance(val, (dict, list)) else val

    try:
        with SessionLocal() as db:
            # 1. 更新摘要表
            row = db.query(MemorySummary).filter_by(user_id=user_id).first()
            data = {
                "summary_text": payload.get("summary"),
                "key_facts": _to_json(payload.get("key_facts", [])),
                "scenarios": _to_json(payload.get("scenarios", [])),
                "global_background": _to_json(payload.get("global_background")),
                "meta_data": _to_json(new_meta),
                "updated_at": datetime.now(timezone.utc)
            }
            
            if not row:
                row = MemorySummary(user_id=user_id, **data)
                db.add(row)
            else:
                for k, v in data.items(): setattr(row, k, v)
                for field in ["meta_data", "key_facts", "scenarios"]: flag_modified(row, field)
            
            db.commit()
            db.refresh(row)
            await log_fn(f"数据库更新成功。新锚点: {new_meta.get('last_summarized_message_id')}")

            # 2. 更新消息评分表
            for item in scores:
                msg_id = item.get("message_id")
                if not msg_id: continue
                record = db.query(MessageMemory).filter_by(user_id=user_id, message_id=msg_id).first()
                if record:
                    record.importance_score = item.get("importance", 3)
                    record.updated_at = datetime.now(timezone.utc)
                else:
                    db.add(MessageMemory(
                        user_id=user_id, message_id=msg_id, role=item.get("role"),
                        content=item.get("content"), importance_score=item.get("importance", 3),
                        memory_state="active"
                    ))
            db.commit()
            await log_fn("消息打分持久化成功。")
    except Exception as e:
        await log_fn(f"数据库持久化失败: {str(e)}")

# --- Core Logic ---

def build_memory_context(user_id: str) -> str:
    snap = get_memory_snapshot(user_id)
    parts = []
    if snap.global_background: parts.append(f"【长期背景】\n{snap.global_background}")
    if snap.scenarios: parts.append(f"【当前活跃情境】\n" + "\n".join(f"- {s}" for s in snap.scenarios))
    if snap.summary: parts.append(f"【近期对话摘要】\n{snap.summary}")
    if snap.key_facts: parts.append(f"【教练注意点】\n" + "\n".join(f"- {f}" for f in snap.key_facts))
    return "\n\n".join(parts).strip()

def apply_forgetting_to_messages(user_id: str, messages: list[Any]) -> list[Any]:
    t0 = time.perf_counter()
    if not messages: return messages
    # 临时方案：仅保留最近 20 条，旧的遗忘逻辑先保留但暂不启用
    if len(messages) > 20:
        logger.info("[TIMING] memory: apply_forgetting_to_messages %.3fs (trim only, msgs=%d)", time.perf_counter() - t0, len(messages))
        return messages[-20:]
    cutoff = max(len(messages) - MEMORY_WINDOW_SIZE, 0)
    if cutoff <= 0:
        logger.info("[TIMING] memory: apply_forgetting_to_messages %.3fs (no cutoff, msgs=%d)", time.perf_counter() - t0, len(messages))
        return messages

    snap = get_memory_snapshot(user_id)
    time_boost = min(0.2, (datetime.now(timezone.utc) - snap.updated_at).total_seconds() / 259200.0) if snap.updated_at else 0
    
    new_messages = []
    with SessionLocal() as db:
        for idx, msg in enumerate(messages):
            role, msg_id = _role_of(msg), getattr(msg, "id", None)
            if role not in ("human", "ai") or idx >= cutoff or not msg_id:
                if role == "tool" and _tool_name_of(msg) == "mark_task_done" and idx < cutoff: continue
                new_messages.append(msg); continue

            record = db.query(MessageMemory).filter_by(user_id=user_id, message_id=msg_id).first()
            if record and record.memory_state == "forgotten":
                new_messages.append(_replace_content(msg, "已忘记")); continue

            importance = record.importance_score if record else 3
            prob = min(FORGET_BASE + (FORGET_TIME_FACTOR * (cutoff-idx)/cutoff) + time_boost - (FORGET_IMPORTANCE_FACTOR * (importance-1)/4.0), FORGET_MAX)
            
            if random.random() < prob:
                if record: record.memory_state, record.updated_at = "forgotten", datetime.now(timezone.utc)
                else: db.add(MessageMemory(user_id=user_id, message_id=msg_id, role=role, content=_text_of(msg), importance_score=importance, memory_state="forgotten"))
                new_messages.append(_replace_content(msg, "已忘记"))
            else: new_messages.append(msg)
        db.commit()
    logger.info("[TIMING] memory: apply_forgetting_to_messages %.3fs (msgs=%d, cutoff=%d)", time.perf_counter() - t0, len(messages), cutoff)
    return new_messages

async def update_memory_for_window(user_id: str, messages: list[Any], model, on_debug_log=None) -> None:
    snap = get_memory_snapshot(user_id)
    last_id = snap.meta_data.get("last_summarized_message_id")
    
    async def log(msg: str):
        print(f"[MEMORY DEBUG] {msg}", flush=True)
        if on_debug_log: await on_debug_log(msg)

    await log(f"用户: {user_id} | 锚点 ID: {last_id or '无'}")

    # 1. 弹性截取增量消息
    new_msgs = []
    if last_id:
        found = False
        for msg in messages:
            if found: new_msgs.append(msg)
            elif getattr(msg, "id", None) == last_id: found = True
        if not found:
            await log(f"未找到锚点，可能已被裁剪。当前历史: {len(messages)}")
            if len(messages) >= MEMORY_WINDOW_SIZE: new_msgs = messages[-MEMORY_WINDOW_SIZE:]
            else: return
    else:
        if len(messages) >= MEMORY_WINDOW_SIZE: new_msgs = messages[-MEMORY_WINDOW_SIZE:]
        else: return

    # 2. 检查触发与上限限制
    count = len(new_msgs)
    if count < MEMORY_WINDOW_SIZE:
        await log(f"增量不足 ({count} < {MEMORY_WINDOW_SIZE})，等待下一轮。"); return
    
    if count > MEMORY_MAX_WINDOW:
        await log(f"增量过多 ({count} > {MEMORY_MAX_WINDOW})，截取最后 {MEMORY_MAX_WINDOW} 条。")
        new_msgs = new_msgs[-MEMORY_MAX_WINDOW:]

    await log(f"触发摘要任务 (处理 {len(new_msgs)} 条)...")

    # 3. 准备 Prompt 数据 (短 ID 映射)
    short_id_map, slim_items = {}, []
    for msg in new_msgs:
        role = _role_of(msg)
        if role == "tool": continue
        text = _text_of(msg).strip()
        if not text: continue
        sid = f"m{len(slim_items) + 1}"
        mid = getattr(msg, "id", None)
        short_id_map[sid] = {"message_id": mid, "role": role, "content": text}
        slim_items.append({"id": sid, "r": "u" if role == "human" else "a", "c": text})

    if not slim_items: return

    # 4. 调用 LLM
    payload = await _summarize_and_score(model, snap, slim_items)
    if not payload: await log("LLM 响应解析失败。"); return

    # 5. 逆向映射评分
    scores = []
    id_scores = payload.get("scores") or {}
    if isinstance(id_scores, list): # 兼容列表格式
        id_scores = {it.get("id"): it.get("s") or it.get("importance") for it in id_scores if it.get("id")}
    
    for sid, s in id_scores.items():
        if sid in short_id_map:
            scores.append({**short_id_map[sid], "importance": s})

    # 6. 持久化
    new_meta = {**snap.meta_data, "last_summarized_message_id": getattr(new_msgs[-1], "id", None)}
    await _save_memory_state(user_id, payload, new_meta, scores, log)

async def _summarize_and_score(model, snap: MemorySnapshot, items: list[dict]) -> dict | None:
    prompt = _build_memory_prompt(snap, items)
    response = await model.ainvoke(prompt, config={"callbacks": []})
    content = getattr(response, "content", "")
    if isinstance(content, list):
        content = " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return _extract_json(content)

def _build_memory_prompt(snap: MemorySnapshot, items: list[dict]) -> list[BaseMessage]:
    sys_msg = SystemMessage(content=(
        "你是健身教练的长期记忆系统。维护用户的【情境模型列表】和【长期背景】。\n"
        "1.【长期背景】：基本健身数据、目标、偏好。\n"
        "2.【情境模型】：当前活跃话题（如：[制定计划]、[讨论伤病]）及其进展。\n"
        "3.【近期摘要】：最近几轮对话流向描述。\n"
        "任务：根据新增消息更新上述状态，并为消息打分(1-5)。输出严格 JSON。"
    ))
    user_msg = HumanMessage(content=(
        f"背景：{snap.global_background or '无'}\n情境：{snap.scenarios}\n摘要：{snap.summary or '无'}\n"
        f"新增消息(r=role, c=content)：\n{json.dumps(items, ensure_ascii=False, indent=2)}\n"
        "输出格式：{\"global_background\": \"...\", \"scenarios\": [\"...\"], \"summary\": \"...\", \"key_facts\": [...], \"scores\": {\"m1\": 5}}"
    ))
    return [sys_msg, user_msg]

def _extract_json(text: str) -> dict | None:
    text = re.sub(r"^```json|```$", "", text.strip(), flags=re.IGNORECASE).strip()
    match = re.search(r"\{[\s\S]*\}", text)
    try: return json.loads(match.group(0)) if match else None
    except: return None

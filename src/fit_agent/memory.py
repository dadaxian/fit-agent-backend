"""Memory utilities for context compression and long-term storage."""

from __future__ import annotations

import asyncio
import json
import os
import random
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from hashlib import sha256
from typing import Any, Iterable, List, Tuple

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage, ToolMessage

from fit_agent.database import get_db
from fit_agent.db import MemorySummary, MessageMemory

MEMORY_WINDOW_SIZE = int(os.environ.get("MEMORY_WINDOW_SIZE", "10"))
MEMORY_EMBEDDING_MODEL = os.environ.get("MEMORY_EMBEDDING_MODEL", "").strip()
FORGET_BASE = float(os.environ.get("MEMORY_FORGET_BASE", "0.08"))
FORGET_TIME_FACTOR = float(os.environ.get("MEMORY_FORGET_TIME_FACTOR", "0.35"))
FORGET_IMPORTANCE_FACTOR = float(os.environ.get("MEMORY_FORGET_IMPORTANCE_FACTOR", "0.25"))
FORGET_MAX = float(os.environ.get("MEMORY_FORGET_MAX", "0.75"))


@dataclass
class MemorySnapshot:
    summary: str | None
    key_facts: list[str]
    last_message_count: int
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


def _hash_message(role: str, text: str) -> str:
    payload = f"{role}::{text}".encode("utf-8")
    return sha256(payload).hexdigest()


def get_memory_snapshot(user_id: str) -> MemorySnapshot:
    with get_db() as db:
        seen: dict[str, MessageMemory] = {}
        row = db.get(MemorySummary, user_id)
        if not row:
            return MemorySnapshot(summary=None, key_facts=[], last_message_count=0, updated_at=None)
        key_facts = row.key_facts or []
        if isinstance(key_facts, dict):
            key_facts = list(key_facts.values())
        return MemorySnapshot(
            summary=row.summary_text,
            key_facts=key_facts,
            last_message_count=row.last_message_count or 0,
            updated_at=row.updated_at,
        )


def build_memory_context(user_id: str) -> str:
    snap = get_memory_snapshot(user_id)
    parts = []
    if snap.summary:
        parts.append(f"【长期记忆摘要】{snap.summary}")
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

            message_hash = _hash_message(role, text)
            record = seen.get(message_hash)
            if record is None:
                record = db.query(MessageMemory).filter_by(user_id=user_id, message_hash=message_hash).first()
                if record:
                    seen[message_hash] = record
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
                        message_hash=message_hash,
                        role=role,
                        content=text,
                        importance_score=importance,
                        memory_state="forgotten",
                    )
                    db.add(record)
                    seen[message_hash] = record
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


async def update_memory_for_window(user_id: str, messages: list[Any], model) -> None:
    # 仅在消息数量达到窗口触发
    snap = get_memory_snapshot(user_id)
    message_count = len(messages)
    if message_count - snap.last_message_count < MEMORY_WINDOW_SIZE:
        return

    window_msgs = messages[snap.last_message_count : message_count]
    scored_items = _serialize_messages(window_msgs)
    if not scored_items:
        return

    summary_payload = await _summarize_and_score(model, snap, scored_items)
    if not summary_payload:
        return

    summary_text = summary_payload.get("summary")
    key_facts = summary_payload.get("key_facts") or []
    scores = summary_payload.get("message_scores") or []
    embeddings = await _embed_messages(scores)

    with get_db() as db:
        row = db.get(MemorySummary, user_id)
        if not row:
            row = MemorySummary(
                user_id=user_id,
                summary_text=summary_text,
                key_facts=key_facts,
                last_message_count=message_count,
            )
            db.add(row)
        else:
            if summary_text:
                row.summary_text = summary_text
            row.key_facts = key_facts
            row.last_message_count = message_count
            row.updated_at = datetime.now(timezone.utc)

        for idx, item in enumerate(scores):
            msg_hash = item.get("message_hash")
            score = item.get("importance", 3)
            role = item.get("role")
            content = item.get("content", "")
            if not msg_hash:
                continue
            embedding = embeddings[idx] if embeddings else None
            record = seen.get(msg_hash)
            if record is None:
                record = db.query(MessageMemory).filter_by(user_id=user_id, message_hash=msg_hash).first()
                if record:
                    seen[msg_hash] = record
            if record:
                record.importance_score = score
                if embedding is not None:
                    record.embedding = embedding
                record.updated_at = datetime.now(timezone.utc)
            else:
                record = MessageMemory(
                    user_id=user_id,
                    message_hash=msg_hash,
                    role=role,
                    content=content,
                    importance_score=score,
                    memory_state="active",
                    embedding=embedding,
                )
                db.add(record)
                seen[msg_hash] = record


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
    response = await model.ainvoke(prompt)
    content = getattr(response, "content", "")
    if isinstance(content, list):
        content = " ".join(
            block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text"
        )
    parsed = _extract_json(content)
    return parsed


def _build_memory_prompt(snap: MemorySnapshot, items: list[dict[str, Any]]) -> list[BaseMessage]:
    summary = snap.summary or ""
    key_facts = snap.key_facts or []
    system_msg = SystemMessage(
        content=(
            "你是健身教练的长期记忆系统。"
            "任务：基于新增对话片段，更新一段摘要，并给每条消息打重要性分数（1-5）。"
            "输出严格的 JSON，禁止多余解释。"
        )
    )
    user_msg = HumanMessage(
        content=(
            f"现有摘要：{summary}\n"
            f"现有关键事实：{key_facts}\n\n"
            "新增消息列表（含 message_hash）：\n"
            f"{json.dumps(items, ensure_ascii=False, indent=2)}\n\n"
            "输出格式：\n"
            "{\n"
            '  "summary": "...",\n'
            '  "key_facts": ["..."],\n'
            '  "message_scores": [\n'
            '     {"message_hash": "...", "importance": 1-5, "role": "human|ai", "content": "..."}\n'
            "  ]\n"
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


async def _embed_messages(scores: list[dict[str, Any]]) -> list[list[float]] | None:
    if not MEMORY_EMBEDDING_MODEL:
        return None
    texts = [s.get("content", "") for s in scores]
    if not any(texts):
        return None
    # 延迟导入，避免无配置时报错
    from langchain.embeddings import init_embeddings

    embeddings = init_embeddings(MEMORY_EMBEDDING_MODEL)
    # 避免阻塞事件循环
    return await asyncio.to_thread(embeddings.embed_documents, texts)

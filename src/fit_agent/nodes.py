"""fit-agent 节点：brain（LLM）与 executor（tools）。"""

import asyncio
import json
import logging
import time
from datetime import datetime
from typing import Any, Dict, List

from langchain_core.messages import AIMessage, RemoveMessage, SystemMessage, ToolMessage
from langchain_core.runnables import RunnableConfig
from langgraph.runtime import Runtime

from fit_agent.context import Context
from fit_agent.prompts import get_system_prompt
from fit_agent.memory import apply_forgetting_to_messages, build_memory_context, update_memory_for_window
from fit_agent.time_utils import now_with_tz
from fit_agent.tools import get_tool_by_name, get_tools, set_current_user_id
from fit_agent.skills_loader import ensure_workspace_skills, get_skill_list
from fit_agent.ui_protocol import build_ui_state

logger = logging.getLogger(__name__)

# ── 终端彩色输出（无需额外依赖）──────────────────────────────────────────────
_C = {
    "reset": "\033[0m",
    "bold": "\033[1m",
    "cyan": "\033[36m",
    "yellow": "\033[33m",
    "green": "\033[32m",
    "red": "\033[31m",
    "magenta": "\033[35m",
    "blue": "\033[34m",
    "gray": "\033[90m",
}


def _ts() -> str:
    """返回当前绝对时间字符串 HH:MM:SS.mmm"""
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def _log(label: str, msg: str, color: str = "cyan", elapsed: float | None = None) -> None:
    """向终端打印带时间戳、颜色的结构化日志，同时写 logger.info。"""
    ts = _ts()
    c = _C.get(color, "")
    reset = _C["reset"]
    bold = _C["bold"]
    elapsed_str = f"  {_C['gray']}+{elapsed*1000:.0f}ms{reset}" if elapsed is not None else ""
    line = f"{_C['gray']}{ts}{reset}  {bold}{c}{label:<20}{reset}  {msg}{elapsed_str}"
    print(line, flush=True)
    logger.info("[TRACE] %s | %s", label, msg)


# ── 请求序列号（每次 agent_node 入口递增，便于区分并发请求）────────────────────
_req_counter = 0

# brain 节点退出的绝对时间（perf_counter），用于在 executor 入口计算 checkpoint 写入耗时
_brain_exit_time: float | None = None

# 缓存主线程 event loop，在首次 async 调用时由 agent_node 设置，
# 供路由函数（运行在线程池中，无法直接获取 loop）使用。
_main_event_loop: asyncio.AbstractEventLoop | None = None

# state 里 messages 最多保留条数，超出部分用 RemoveMessage 从 checkpoint 删除
# 调低到 10 条：每次对话只有 human+ai+tool 各 1 条，10 条覆盖约 3 轮完整对话
# 旧消息已经不影响 LLM（LLM 层用 messages[-20:]），只是 checkpoint 的历史备份
STATE_MESSAGES_MAX = int(__import__('os').environ.get('STATE_MESSAGES_MAX', '10'))

# ToolMessage content 最大长度，超出部分截断，避免大文件输出撑大 checkpoint
TOOL_CONTENT_MAX = int(__import__('os').environ.get('TOOL_CONTENT_MAX', '500'))

MAX_ITERATIONS = 50
REMINDER_AFTER_CONSECUTIVE = 1  # 首次无 tool_call 即提醒
MAX_CONSECUTIVE_NO_TOOL_CALLS = 2  # 最多重试 1 次后强制结束

REMINDER_NO_CHOICE = """【系统提醒】你上一条消息没有调用工具。你必须在本轮的同一条消息里完成所有输出，不允许再分多轮。

必须选择以下之一，并在同一条消息里一次输出所有 tool_call：
- 直接回答（无需切页、无需读写）：输出文字 content + mark_task_done(...)
- 需要切页（无需读数据）：输出文字 content + ui_command(...) + mark_task_done(...)，三个合并，一次输出，不要分开。
- 需要读/写数据：调用 run_command(...)，等结果再继续。

注意：ui_command 是 fire-and-forget 指令，不需要等它的返回值，必须和 mark_task_done 合并在同一条消息输出。
"""


def _extract_latest_human_text(messages: List[Any]) -> str:
    for m in reversed(messages):
        if getattr(m, "type", "") != "human":
            continue
        content = getattr(m, "content", "")
        if isinstance(content, str):
            text = content.strip()
            if text:
                return text
        elif isinstance(content, list):
            parts: List[str] = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    t = str(block.get("text") or "").strip()
                    if t:
                        parts.append(t)
            if parts:
                return " ".join(parts)
    return ""


async def agent_node(
    state: Dict[str, Any],
    config: RunnableConfig,
    *,
    runtime: Runtime[Context],
) -> Dict[str, Any]:
    """Brain 节点：调用 LLM，返回 AIMessage（可能带 tool_calls）。"""
    from fit_agent.utils import load_chat_model

    # 在 async 上下文中缓存主 event loop，供路由函数（线程池中）使用
    global _main_event_loop, _req_counter
    _main_event_loop = asyncio.get_running_loop()
    _req_counter += 1
    req_id = _req_counter  # 当次请求序号，便于 grep 过滤

    t0 = time.perf_counter()
    messages = list(state.get("messages") or [])
    configurable = (config or {}).get("configurable") or {}
    auth_user = configurable.get("langgraph_auth_user") or {}
    user_id = auth_user.get("identity") or configurable.get("user_id") or "dev"

    # ── 提取最新用户消息做日志摘要 ─────────────────────────────────────────────
    latest_human_preview = _extract_latest_human_text(messages)
    preview = (latest_human_preview[:40] + "…") if len(latest_human_preview) > 40 else latest_human_preview

    _log(f"[#{req_id}] BRAIN-ENTER",
         f"user={user_id}  msgs={len(messages)}  q='{preview}'",
         color="cyan")

    ensure_workspace_skills(user_id)
    _log(f"[#{req_id}] BRAIN-SKILLS",
         f"workspace skills ready  +{(time.perf_counter()-t0)*1000:.0f}ms",
         color="gray")

    t1 = time.perf_counter()
    system_prompt = get_system_prompt(user_id=user_id)
    _log(f"[#{req_id}] BRAIN-PROMPT",
         f"system prompt built  elapsed={time.perf_counter()-t1:.3f}s",
         color="gray")

    from fit_agent.context import Context

    ctx = runtime.context if runtime.context is not None else Context()
    model = load_chat_model(ctx.model)
    tools = get_tools()
    llm_with_tools = model.bind_tools(tools)

    # --- 记忆系统暂时关闭，跳过两次 DB 读以减少延迟 ---
    # t2 = time.perf_counter()
    # memory_context = build_memory_context(user_id)
    # logger.info("[TIMING] brain: build_memory_context %.3fs", time.perf_counter() - t2)

    # t3 = time.perf_counter()
    # messages = apply_forgetting_to_messages(user_id, messages)
    # logger.info("[TIMING] brain: apply_forgetting_to_messages %.3fs (msgs=%d)", time.perf_counter() - t3, len(messages))

    # 直接取最近 20 条，不走 DB
    messages = messages[-20:] if len(messages) > 20 else messages

    all_messages = [SystemMessage(content=system_prompt)]
    all_messages += messages

    # ── LLM 调用 ────────────────────────────────────────────────────────────────
    t_llm = time.perf_counter()
    _log(f"[#{req_id}] LLM-CALL",
         f"→ invoking model={ctx.model}  input_msgs={len(all_messages)}",
         color="yellow")

    response = await llm_with_tools.ainvoke(all_messages, config=config or {})

    llm_elapsed = time.perf_counter() - t_llm
    tool_calls = getattr(response, "tool_calls", None) or []
    tool_names = [tc.get("name") if isinstance(tc, dict) else getattr(tc, "name", "") for tc in tool_calls]
    _log(f"[#{req_id}] LLM-DONE",
         f"elapsed={llm_elapsed:.3f}s  tool_calls={tool_names or 'none'}",
         color="green", elapsed=llm_elapsed)

    if isinstance(response, AIMessage):
        extra = dict(getattr(response, "additional_kwargs", {}) or {})
        extra.setdefault("timestamp", now_with_tz().isoformat())
        # ⚠️  ui_state 不再写进 additional_kwargs/checkpoint，改为 custom event 流出
        # 这样每条 AIMessage 体积减少 ~1KB，checkpoint 写入从 ~500ms 降到 ~50ms
        response = response.copy(update={"additional_kwargs": extra})

    # 把 ui_state 作为独立 custom event 发出（不进 state，不写 PG）
    latest_human = _extract_latest_human_text(messages)
    ui_state_payload = build_ui_state(latest_human)
    try:
        from langchain_core.callbacks.manager import adispatch_custom_event
        await adispatch_custom_event(
            "ui_state",
            ui_state_payload,
            config=config or {},
        )
        _log(f"[#{req_id}] UI-STATE",
             f"dispatched custom event  module={ui_state_payload.get('module')}",
             color="gray")
    except Exception as _e:
        _log(f"[#{req_id}] UI-STATE",
             f"dispatch skipped: {_e}",
             color="gray")

    consecutive = 0 if tool_calls else (state.get("consecutive_no_tool_calls", 0) + 1)

    need_reminder = (
        isinstance(response, AIMessage)
        and not tool_calls
        and not state.get("task_complete")
        and consecutive >= REMINDER_AFTER_CONSECUTIVE
    )
    if need_reminder:
        _log(f"[#{req_id}] LLM-RETRY",
             f"no tool_calls → injecting reminder, retrying LLM",
             color="magenta")
        system_prompt = system_prompt + "\n\n" + REMINDER_NO_CHOICE
        all_messages = [SystemMessage(content=system_prompt)] + messages
        t_retry = time.perf_counter()
        response = await llm_with_tools.ainvoke(all_messages, config=config or {})
        tool_calls = getattr(response, "tool_calls", None) or []
        retry_names = [tc.get("name") if isinstance(tc, dict) else getattr(tc, "name", "") for tc in tool_calls]
        _log(f"[#{req_id}] LLM-RETRY-DONE",
             f"elapsed={time.perf_counter()-t_retry:.3f}s  tool_calls={retry_names or 'none'}",
             color="green", elapsed=time.perf_counter()-t_retry)
        consecutive = 0 if tool_calls else consecutive

    # 裁剪 state 里的历史消息，避免 checkpoint 无限增长
    all_state_messages = list(state.get("messages") or [])
    to_delete: list[RemoveMessage] = []
    if len(all_state_messages) > STATE_MESSAGES_MAX:
        cutoff = len(all_state_messages) - STATE_MESSAGES_MAX
        for old_msg in all_state_messages[:cutoff]:
            msg_id = getattr(old_msg, "id", None)
            if msg_id:
                to_delete.append(RemoveMessage(id=msg_id))
        if to_delete:
            _log(f"[#{req_id}] TRIM",
                 f"删除 {len(to_delete)} 条旧消息，保留最近 {STATE_MESSAGES_MAX} 条",
                 color="gray")

    # 估算本次写入 checkpoint 的数据量（用于诊断 checkpoint 慢的原因）
    try:
        remaining = all_state_messages[len(to_delete):] + [response]
        payload_bytes = sum(
            len(json.dumps(
                getattr(m, "content", "") or "",
                ensure_ascii=False
            ).encode()) + len(json.dumps(
                getattr(m, "additional_kwargs", {}) or {},
                ensure_ascii=False
            ).encode())
            for m in remaining
        )
        _log(f"[#{req_id}] CHECKPOINT-SIZE",
             f"~{payload_bytes // 1024}KB  ({len(remaining)} msgs after trim)",
             color="gray" if payload_bytes < 20_000 else "yellow" if payload_bytes < 50_000 else "red")
    except Exception:
        pass

    total_brain = time.perf_counter() - t0
    _log(f"[#{req_id}] BRAIN-EXIT",
         f"total={total_brain:.3f}s  → route_after_agent  (checkpoint write begins)",
         color="cyan", elapsed=total_brain)

    # 记录 brain 退出时间，供 executor 入口计算 checkpoint 写入耗时
    global _brain_exit_time
    _brain_exit_time = time.perf_counter()

    return {"messages": [response] + to_delete, "consecutive_no_tool_calls": consecutive}


def _route_after_agent(state: Dict[str, Any], config: RunnableConfig) -> str:
    """Agent 之后：有 tool_calls → tools；无且 task_complete → end；否则继续或强制 end。"""
    t0 = time.perf_counter()
    messages = state.get("messages") or []
    if not messages:
        _log("ROUTE-AGENT", "→ end  (no messages)", color="gray")
        return "end"

    last = messages[-1]

    if not isinstance(last, AIMessage):
        _log("ROUTE-AGENT", "→ end  (last msg not AIMessage)", color="gray")
        return "end"

    tool_calls = getattr(last, "tool_calls", None) or []
    if tool_calls:
        names = [tc.get("name") if isinstance(tc, dict) else getattr(tc, "name", "") for tc in tool_calls]
        _log("ROUTE-AGENT", f"→ executor  tools={names}", color="blue", elapsed=time.perf_counter()-t0)
        return "tools"

    if state.get("task_complete"):
        _log("ROUTE-AGENT", "→ end  (task_complete flag)", color="green", elapsed=time.perf_counter()-t0)
        return "end"

    # 兜底：Agent 已给出文本回复但未调用 mark_task_done，视为隐式完成
    content = getattr(last, "content", "") or ""
    text = ""
    if isinstance(content, str):
        text = content.strip()
    elif isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = (block.get("text") or "").strip()
                break
    if text:
        _log("ROUTE-AGENT", "→ end  (has text, implicit done)", color="green", elapsed=time.perf_counter()-t0)
        return "end"

    consecutive = state.get("consecutive_no_tool_calls", 0)
    if consecutive >= MAX_CONSECUTIVE_NO_TOOL_CALLS:
        _log("ROUTE-AGENT", f"→ end  (max consecutive={consecutive}, forced)", color="red", elapsed=time.perf_counter()-t0)
        return "end"

    _log("ROUTE-AGENT", "→ brain  (loop back)", color="yellow", elapsed=time.perf_counter()-t0)
    return "agent"


def route_after_agent(state: Dict[str, Any], config: RunnableConfig) -> str:
    return _route_after_agent(state, config)


async def _execute_single_tool(
    tool_call: Any,
    tools: List,
    config: RunnableConfig,
) -> ToolMessage:
    """执行单次工具调用。"""
    name = tool_call.get("name") if isinstance(tool_call, dict) else getattr(tool_call, "name", None)
    args = tool_call.get("args", {}) if isinstance(tool_call, dict) else getattr(tool_call, "args", {}) or {}
    call_id = tool_call.get("id") if isinstance(tool_call, dict) else getattr(tool_call, "id", None)
    try:
        tool_instance = get_tool_by_name(name, tools)
        if hasattr(tool_instance, "ainvoke"):
            result = await tool_instance.ainvoke(args, config=config or {})
        else:
            result = tool_instance.invoke(args, config=config or {})
        extra = {"timestamp": now_with_tz().isoformat()}
        content = str(result)
        if name == "ui_command" and isinstance(result, dict):
            extra["ui_command"] = result
            content = json.dumps(result, ensure_ascii=False)
        # 截断超大输出，避免 run_command 返回长文本撑大 checkpoint
        if len(content) > TOOL_CONTENT_MAX:
            extra["truncated"] = True
            extra["original_length"] = len(content)
            content = content[:TOOL_CONTENT_MAX] + f"\n…[截断, 原始长度={len(content)}]"
        return ToolMessage(
            content=content,
            tool_call_id=call_id,
            name=name,
            additional_kwargs=extra,
        )
    except Exception as e:
        logger.exception(f"工具调用失败 {name}")
        return ToolMessage(
            content=f"工具调用失败: {str(e)}",
            tool_call_id=call_id,
            name=name,
            additional_kwargs={"timestamp": now_with_tz().isoformat()},
        )


async def tools_node(state: Dict[str, Any], config: RunnableConfig) -> Dict[str, Any]:
    """Executor 节点：执行 tool_calls。"""
    t0 = time.perf_counter()
    configurable = (config or {}).get("configurable") or {}
    auth_user = configurable.get("langgraph_auth_user") or {}
    user_id = auth_user.get("identity") or configurable.get("user_id") or "dev"
    set_current_user_id(user_id)

    messages = list(state.get("messages") or [])
    last_ai = None
    for m in reversed(messages):
        if isinstance(m, AIMessage) and getattr(m, "tool_calls", None):
            last_ai = m
            break
    if not last_ai:
        _log("EXECUTOR", "no tool_calls found, skip", color="gray")
        return {}
    tool_calls = getattr(last_ai, "tool_calls", []) or []
    if not tool_calls:
        return {}
    if not isinstance(tool_calls[0], dict):
        tool_calls = [
            {"id": getattr(tc, "id", ""), "name": getattr(tc, "name", ""), "args": getattr(tc, "args", {})}
            for tc in tool_calls
        ]

    names = [tc.get("name") if isinstance(tc, dict) else getattr(tc, "name", "") for tc in tool_calls]

    # 计算 checkpoint 写入耗时（brain 退出 → executor 入口 的空白时间就是 Aegra 写 PG 的耗时）
    checkpoint_gap_ms = (time.perf_counter() - _brain_exit_time) * 1000 if _brain_exit_time else 0
    gap_color = "red" if checkpoint_gap_ms > 300 else ("yellow" if checkpoint_gap_ms > 100 else "gray")
    _log("CHECKPOINT-GAP",
         f"brain→executor gap = {checkpoint_gap_ms:.0f}ms  (Aegra checkpoint write)",
         color=gap_color)

    _log("EXECUTOR-ENTER", f"executing tools={names}  (concurrent)", color="blue")

    tools_list = get_tools()
    t_exec = time.perf_counter()
    results = await asyncio.gather(
        *[_execute_single_tool(tc, tools_list, config) for tc in tool_calls],
        return_exceptions=True,
    )
    tool_messages = []
    for i, r in enumerate(results):
        if isinstance(r, Exception):
            tc = tool_calls[i]
            _log("EXECUTOR-ERR", f"tool={tc.get('name')}  err={r}", color="red")
            tool_messages.append(
                ToolMessage(
                    content=f"工具调用失败: {str(r)}",
                    tool_call_id=tc.get("id", "err"),
                    name=tc.get("name", "run_command"),
                )
            )
        else:
            tool_messages.append(r)

    task_complete = any(
        (tc.get("name") if isinstance(tc, dict) else getattr(tc, "name", "")) == "mark_task_done"
        for tc in tool_calls
    )

    # executor 也做 TRIM：新增 tool_messages 后再次裁剪，保证 executor checkpoint 同样紧凑
    all_state_messages = list(state.get("messages") or [])
    # 预计加入 tool_messages 后的总数
    projected_total = len(all_state_messages) + len(tool_messages)
    exec_to_delete: list[RemoveMessage] = []
    if projected_total > STATE_MESSAGES_MAX:
        cutoff = projected_total - STATE_MESSAGES_MAX
        for old_msg in all_state_messages[:cutoff]:
            msg_id = getattr(old_msg, "id", None)
            if msg_id:
                exec_to_delete.append(RemoveMessage(id=msg_id))

    exec_elapsed = time.perf_counter() - t_exec
    total_elapsed = time.perf_counter() - t0
    _log("EXECUTOR-DONE",
         f"tools={names}  task_complete={task_complete}  exec={exec_elapsed:.3f}s  total={total_elapsed:.3f}s"
         + (f"  trim={len(exec_to_delete)}" if exec_to_delete else ""),
         color="blue", elapsed=exec_elapsed)
    return {"messages": tool_messages + exec_to_delete, "task_complete": task_complete}


def route_after_tools(state: Dict[str, Any]) -> str:
    t0 = time.perf_counter()
    out = "end" if state.get("task_complete") else "agent"
    color = "green" if out == "end" else "yellow"
    _log("ROUTE-TOOLS", f"→ {out}  (task_complete={state.get('task_complete')})",
         color=color, elapsed=time.perf_counter()-t0)
    return out

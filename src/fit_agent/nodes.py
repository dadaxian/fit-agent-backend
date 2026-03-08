"""fit-agent 节点：brain（LLM）与 executor（tools）。"""

import asyncio
import logging
from typing import Any, Dict, List
from datetime import datetime

from langchain_core.messages import AIMessage, SystemMessage, ToolMessage
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

MAX_ITERATIONS = 50
REMINDER_AFTER_CONSECUTIVE = 1  # 首次无 tool_call 即提醒
MAX_CONSECUTIVE_NO_TOOL_CALLS = 2  # 最多重试 1 次后强制结束

REMINDER_NO_CHOICE = """【系统提醒】你上一条消息只输出了文字，没有调用工具。你只能使用两个工具：run_command（执行命令）、mark_task_done（结束任务）。请在本轮必须二选一：继续则调用 run_command，结束则调用 mark_task_done。禁止只输出文字，禁止调用其他工具。"""


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

    messages = list(state.get("messages") or [])
    configurable = (config or {}).get("configurable") or {}
    # 优先从 auth 获取 identity（登录用户 id），否则 user_id 或匿名
    auth_user = configurable.get("langgraph_auth_user") or {}
    user_id = auth_user.get("identity") or configurable.get("user_id") or "dev"

    ensure_workspace_skills(user_id)
    system_prompt = get_system_prompt(user_id=user_id)
    from fit_agent.context import Context

    ctx = runtime.context if runtime.context is not None else Context()
    model = load_chat_model(ctx.model)
    tools = get_tools()
    # ChatZhipuAI 仅支持 tool_choice="auto"，无法强制；需用支持工具调用的模型（如 glm-4.7-flash）
    llm_with_tools = model.bind_tools(tools)

    memory_context = build_memory_context(user_id)
    messages = apply_forgetting_to_messages(user_id, messages)

    all_messages = [SystemMessage(content=system_prompt)]
    if memory_context:
        all_messages.append(SystemMessage(content=memory_context))
    all_messages += messages
    response = await llm_with_tools.ainvoke(all_messages, config=config or {})
    if isinstance(response, AIMessage):
        extra = dict(getattr(response, "additional_kwargs", {}) or {})
        extra.setdefault("timestamp", now_with_tz().isoformat())
        # 新增：平台无关 UI 协议（给 iOS/Android/Web 各自渲染）
        latest_human = _extract_latest_human_text(messages)
        extra["ui_state"] = build_ui_state(latest_human)
        response = response.copy(update={"additional_kwargs": extra})

    tool_calls = getattr(response, "tool_calls", None) or []
    consecutive = 0 if tool_calls else (state.get("consecutive_no_tool_calls", 0) + 1)

    need_reminder = (
        isinstance(response, AIMessage)
        and not tool_calls
        and not state.get("task_complete")
        and consecutive >= REMINDER_AFTER_CONSECUTIVE
    )
    if need_reminder:
        system_prompt = system_prompt + "\n\n" + REMINDER_NO_CHOICE
        all_messages = [SystemMessage(content=system_prompt)] + messages
        response = await llm_with_tools.ainvoke(all_messages, config=config or {})
        tool_calls = getattr(response, "tool_calls", None) or []
        consecutive = 0 if tool_calls else consecutive

    return {"messages": [response], "consecutive_no_tool_calls": consecutive}


def _route_after_agent(state: Dict[str, Any], config: RunnableConfig) -> str:
    """Agent 之后：有 tool_calls → tools；无且 task_complete → end；否则继续或强制 end。"""
    messages = state.get("messages") or []
    if not messages:
        return "end"
    
    # 提取 user_id 用于后台任务
    configurable = (config or {}).get("configurable") or {}
    auth_user = configurable.get("langgraph_auth_user") or {}
    user_id = auth_user.get("identity") or configurable.get("user_id") or "dev"

    last = messages[-1]
    
    def trigger_memory_task():
        """在对话彻底结束时，异步触发记忆更新任务。"""
        from fit_agent.utils import load_chat_model
        from langchain_core.callbacks.manager import adispatch_custom_event
        from fit_agent.memory import update_memory_for_window
        import os
        import sys

        memory_model_name = os.environ.get("MEMORY_MODEL") or "zhipuai/glm-4-flash"
        background_model = load_chat_model(memory_model_name)
        bg_messages = list(messages)

        async def _bg_task():
            print(f"\n[DEBUG] 对话结束，启动后台记忆任务: 用户={user_id}, 消息数={len(bg_messages)}", file=sys.stderr, flush=True)
            async def on_debug_log(msg: str):
                await adispatch_custom_event("memory_debug", {"message": msg}, config=config)
            try:
                await update_memory_for_window(user_id, bg_messages, background_model, on_debug_log=on_debug_log)
            except Exception as e:
                print(f"[DEBUG] 后台记忆任务崩溃: {str(e)}", file=sys.stderr, flush=True)
        
        # 修复：在路由函数（可能在线程池运行）中安全地启动异步任务
        try:
            loop = asyncio.get_running_loop()
            loop.create_task(_bg_task())
        except RuntimeError:
            # 如果当前没有运行中的 loop，说明可能在同步线程中，尝试获取主线程 loop 或直接创建新任务
            # 在 LangGraph 路由中通常会有 loop，但为了稳健性：
            asyncio.run_coroutine_threadsafe(_bg_task(), asyncio.get_event_loop())

    if not isinstance(last, AIMessage):
        trigger_memory_task()
        return "end"
    
    tool_calls = getattr(last, "tool_calls", None) or []
    if tool_calls:
        return "tools"
    
    if state.get("task_complete"):
        trigger_memory_task()
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
        logger.info("Agent 已输出结论但未调用 mark_task_done，视为完成并结束")
        trigger_memory_task()
        return "end"
    
    consecutive = state.get("consecutive_no_tool_calls", 0)
    if consecutive >= MAX_CONSECUTIVE_NO_TOOL_CALLS:
        logger.warning(f"连续 {consecutive} 轮无 tool_calls 且未 mark_task_done，强制结束")
        trigger_memory_task()
        return "end"
    
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
        return ToolMessage(
            content=str(result),
            tool_call_id=call_id,
            name=name,
            additional_kwargs={"timestamp": now_with_tz().isoformat()},
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
        return {}
    tool_calls = getattr(last_ai, "tool_calls", []) or []
    if not tool_calls:
        return {}
    if not isinstance(tool_calls[0], dict):
        tool_calls = [
            {"id": getattr(tc, "id", ""), "name": getattr(tc, "name", ""), "args": getattr(tc, "args", {})}
            for tc in tool_calls
        ]
    tools_list = get_tools()
    results = await asyncio.gather(
        *[_execute_single_tool(tc, tools_list, config) for tc in tool_calls],
        return_exceptions=True,
    )
    tool_messages = []
    for i, r in enumerate(results):
        if isinstance(r, Exception):
            tc = tool_calls[i]
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
    return {"messages": tool_messages, "task_complete": task_complete}


def route_after_tools(state: Dict[str, Any]) -> str:
    return "end" if state.get("task_complete") else "agent"

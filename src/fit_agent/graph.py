"""fit-agent — brain ↔ executor 循环，支持 run_command + Skills。"""

import time
from datetime import datetime
from typing import Any, Dict, List, Optional, Union
from uuid import UUID

from langchain_core.callbacks import BaseCallbackHandler
from langchain_core.outputs import LLMResult
from langgraph.graph import END, StateGraph
from langgraph.runtime import Runtime

from fit_agent.context import Context
from fit_agent.nodes import _C, agent_node, route_after_agent, route_after_tools, tools_node
from fit_agent.state import InputState, State


# ── Graph 级别的 Callback，打印请求起止分隔线 ──────────────────────────────────
class _GraphTraceCallback(BaseCallbackHandler):
    """在 LLM call 开始/结束时打印额外的分隔与耗时（补充 nodes.py 里的节点日志）。"""

    def __init__(self) -> None:
        super().__init__()
        self._llm_start: Dict[str, float] = {}  # run_id -> t0

    def _ts(self) -> str:
        return datetime.now().strftime("%H:%M:%S.%f")[:-3]

    def _print(self, label: str, msg: str, color: str = "cyan", elapsed: float | None = None) -> None:
        ts = self._ts()
        c = _C.get(color, "")
        reset = _C["reset"]
        bold = _C["bold"]
        gray = _C["gray"]
        elapsed_str = f"  {gray}+{elapsed*1000:.0f}ms{reset}" if elapsed is not None else ""
        print(f"{gray}{ts}{reset}  {bold}{c}{label:<22}{reset}  {msg}{elapsed_str}", flush=True)

    # ── chain（graph run）的开始 / 结束 ────────────────────────────────────────
    def on_chain_start(
        self,
        serialized: Dict[str, Any],
        inputs: Dict[str, Any],
        *,
        run_id: UUID,
        parent_run_id: Optional[UUID] = None,
        **kwargs: Any,
    ) -> None:
        # 只打印顶层 graph run（无 parent）
        if parent_run_id is None:
            sep = "─" * 60
            self._print("", f"{_C['bold']}{_C['cyan']}{sep}{_C['reset']}")
            self._print("▶ GRAPH-START", f"run_id={str(run_id)[:8]}…", color="cyan")

    def on_chain_end(
        self,
        outputs: Dict[str, Any],
        *,
        run_id: UUID,
        parent_run_id: Optional[UUID] = None,
        **kwargs: Any,
    ) -> None:
        if parent_run_id is None:
            sep = "─" * 60
            self._print("◀ GRAPH-END", f"run_id={str(run_id)[:8]}…  ✓ done", color="green")
            self._print("", f"{_C['bold']}{_C['green']}{sep}{_C['reset']}")

    def on_chain_error(
        self,
        error: BaseException,
        *,
        run_id: UUID,
        parent_run_id: Optional[UUID] = None,
        **kwargs: Any,
    ) -> None:
        if parent_run_id is None:
            self._print("✖ GRAPH-ERROR", f"run_id={str(run_id)[:8]}…  err={error}", color="red")


_trace_cb = _GraphTraceCallback()

workflow = StateGraph(State, input_schema=InputState, context_schema=Context)
workflow.add_node("brain", agent_node)
workflow.add_node("executor", tools_node)
workflow.set_entry_point("brain")

workflow.add_conditional_edges("brain", route_after_agent, {"tools": "executor", "agent": "brain", "end": END})
workflow.add_conditional_edges("executor", route_after_tools, {"agent": "brain", "end": END})

graph = workflow.compile()

"""State definitions for fit-agent."""

from __future__ import annotations

from typing import Annotated, TypedDict

from langchain_core.messages import AnyMessage
from langgraph.graph import add_messages


class InputState(TypedDict, total=False):
    """Input schema — only the fields the caller may provide."""

    messages: Annotated[list[AnyMessage], add_messages]


class State(InputState, total=False):
    """Internal state — extends InputState with runtime-managed fields."""

    task_complete: bool
    consecutive_no_tool_calls: int

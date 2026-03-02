"""fit-agent — brain ↔ executor 循环，支持 run_command + Skills。"""

from langgraph.graph import END, StateGraph
from langgraph.runtime import Runtime

from fit_agent.context import Context
from fit_agent.nodes import agent_node, route_after_agent, route_after_tools, tools_node
from fit_agent.state import InputState, State

workflow = StateGraph(State, input_schema=InputState, context_schema=Context)
workflow.add_node("brain", agent_node)
workflow.add_node("executor", tools_node)
workflow.set_entry_point("brain")

workflow.add_conditional_edges("brain", route_after_agent, {"tools": "executor", "agent": "brain", "end": END})
workflow.add_conditional_edges("executor", route_after_tools, {"agent": "brain", "end": END})

graph = workflow.compile()

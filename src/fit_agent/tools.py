"""fit-agent 工具：run_command + mark_task_done，参考 biagent agent_meta。"""

import contextvars
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional

from langchain_core.tools import BaseTool, tool

# 项目根目录（fit-agent/），run_command 的 cwd，确保可创建目录、读写文件
PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
# 用户工作区（用于 skills 同步等），按 user_id 隔离
WORKSPACE_BASE = PROJECT_ROOT / "workspace"
WORKSPACE_BASE.mkdir(parents=True, exist_ok=True)

# 当前请求的 user_id，由 nodes 在执行工具前设置
_current_user_id: contextvars.ContextVar[Optional[str]] = contextvars.ContextVar(
    "fit_agent_user_id", default=None
)


def _sanitize_user_id(uid: str) -> str:
    """将 user_id 转为可作目录名的字符串。"""
    if not uid:
        return "dev"
    return re.sub(r"[^\w\-]", "_", str(uid).strip()) or "dev"


def set_current_user_id(user_id: Optional[str]) -> None:
    """设置当前 user_id，供 run_command 解析工作目录。"""
    _current_user_id.set(user_id)


def get_current_user_id() -> Optional[str]:
    """获取当前 user_id。"""
    return _current_user_id.get(None)


def get_user_workspace_dir(user_id: Optional[str] = None) -> Path:
    """返回该用户的独立工作目录（workspace/<user_id>/），不存在则创建。"""
    uid = user_id or get_current_user_id()
    safe = _sanitize_user_id(uid) if uid else "dev"
    d = WORKSPACE_BASE / safe
    d.mkdir(parents=True, exist_ok=True)
    return d


@tool(
    description="""【必须调用】当你话讲完了（给出结论、或移交句柄等待用户回复）时，必须在本条消息中调用本工具，否则系统无法结束、会一直循环。与文字同条输出（content + 本 tool_call）。任务未完成时用 run_command，讲完时用本工具。"""
)
def mark_task_done(reason: str = "") -> str:
    """标记任务完成，由 tools 节点检测后设置 state.task_complete，路由据此结束。"""
    return "已标记任务完成，本轮将结束。" + (f" 原因：{reason}" if reason else "")


@tool(
    description="""用于控制前端页面（Coach OS）。当需要切页或触发前端交互时调用。

参数：
- action: 动作类型，如 navigate / show_message
- module: 目标模块（home/plans/training/assessment/workspace），仅 action=navigate 时需要
- sub_state: 可选子页（today/session/blackboard 等）。也可放在 payload.sub_state（推荐）
- payload: 可选的附加信息（如提示文本）
"""
)
def ui_command(
    action: str,
    module: Optional[str] = None,
    sub_state: Optional[str] = None,
    payload: Any = None,
) -> Dict[str, Any]:
    """返回结构化 UI 控制指令，由前端解析执行。"""
    p: Dict[str, Any] = {}
    if payload is None:
        p = {}
    elif isinstance(payload, dict):
        p = dict(payload)
    elif isinstance(payload, str):
        # 兼容模型把 JSON dict 当作字符串传入的情况
        s = payload.strip()
        try:
            obj = json.loads(s) if s else {}
            if isinstance(obj, dict):
                p = dict(obj)
        except Exception:
            p = {"text": payload}
    else:
        # 兜底：尽量保留信息
        p = {"value": payload}
    if sub_state and "sub_state" not in p:
        p["sub_state"] = sub_state
    return {
        "type": action,
        "module": module,
        "sub_state": sub_state,
        "payload": p,
    }


@tool(
    description="""在**项目根目录**中执行一条 shell 命令，并返回该命令的标准输出或错误信息。

**本质**：你在与项目终端交互——传入一条命令字符串，机器在项目根目录下执行后把结果文本返回给你。你可以据此继续推理或再发下一条命令。

**能力**：可执行任意 shell 命令（如 mkdir、ls、pwd、cat、echo、jq、python 等）。一次调用只执行你传入的这一条 cmd；如需多条，可在一轮中多次调用本工具。

**工作目录**：命令的**当前工作目录**为项目根目录（fit-agent/），你可在此目录及子目录下创建目录、读写文件、执行脚本。单次执行超时 300 秒。"""
)
def run_command(cmd: str) -> str:
    """在项目根目录下执行一条 shell 命令，返回标准输出或错误信息。"""
    if not (cmd and cmd.strip()):
        return "(无命令)"
    cwd = PROJECT_ROOT
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=300,
            env=os.environ.copy(),
        )
        out = (result.stdout or "").strip()
        err = (result.stderr or "").strip()
        if out and err:
            return f"{out}\n\n--- stderr ---\n{err}"
        return out or err or "(无输出)"
    except subprocess.TimeoutExpired:
        return "(命令执行超时 300s)"
    except Exception as e:
        return f"(执行失败: {str(e)})"


def get_tools() -> List[BaseTool]:
    """返回 fit-agent 可用工具列表。"""
    return [run_command, mark_task_done, ui_command]


def get_tool_by_name(tool_name: str, tools: List[BaseTool]) -> BaseTool:
    """按名称获取工具实例。"""
    for t in tools:
        if t.name == tool_name:
            return t
    raise ValueError(
        f"工具 '{tool_name}' 不存在。你只能使用 run_command、ui_command、mark_task_done。"
    )

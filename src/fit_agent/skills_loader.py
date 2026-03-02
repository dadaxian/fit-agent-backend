"""Skills 加载：将 skills 源目录同步到用户工作区，供 run_command 读取。"""

import shutil
from pathlib import Path
from typing import Optional

from fit_agent.tools import get_user_workspace_dir

# 技能源目录：fit_agent/skills/
SKILLS_SOURCE_DIR = Path(__file__).resolve().parent.parent / "skills"


def ensure_workspace_skills(user_id: Optional[str] = None) -> None:
    """将技能源目录同步到当前用户工作区的 skills/，便于 run_command 通过 cat 读取。"""
    workspace_skills_dir = get_user_workspace_dir(user_id) / "skills"
    if not SKILLS_SOURCE_DIR.is_dir():
        workspace_skills_dir.mkdir(parents=True, exist_ok=True)
        return
    workspace_skills_dir.mkdir(parents=True, exist_ok=True)
    for path in SKILLS_SOURCE_DIR.iterdir():
        if not path.is_dir():
            continue
        dest = workspace_skills_dir / path.name
        try:
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(path, dest)
        except Exception:
            pass


def get_skill_list() -> list[dict]:
    """扫描技能源目录，返回 [{name, dir}, ...]。"""
    if not SKILLS_SOURCE_DIR.is_dir():
        return []
    result = []
    for path in sorted(SKILLS_SOURCE_DIR.iterdir()):
        if not path.is_dir():
            continue
        if (path / "SKILL.md").is_file():
            result.append({"name": path.name, "dir": path.name})
    return result

"""Platform-agnostic UI protocol for Coach OS."""

from __future__ import annotations

from typing import Any, Dict, List


def _contains_any(text: str, keywords: List[str]) -> bool:
    lowered = text.lower()
    return any(k.lower() in lowered for k in keywords)


def _module_from_query(user_text: str) -> str:
    if _contains_any(user_text, ["计划", "安排", "课程表", "周期"]):
        return "plans"
    if _contains_any(user_text, ["评估", "视频", "动作", "照片", "体态"]):
        return "assessment"
    if _contains_any(user_text, ["饮食", "热量", "蛋白", "吃", "营养"]):
        return "plans"
    if _contains_any(user_text, ["训练", "开始练", "组", "次数"]):
        return "training"
    if _contains_any(user_text, ["笔记", "黑板", "markdown", "记录"]):
        return "workspace"
    return "home"




def _sub_state_from_query(module: str, user_text: str) -> str:
    if module == "plans":
        if _contains_any(user_text, ["饮食计划", "今日饮食", "吃什么", "营养计划", "饮食"]):
            return "nutrition_detail"
        if _contains_any(user_text, ["今日训练计划", "今天训练", "训练计划", "练什么"]):
            return "training_detail"
    if module == "training" and _contains_any(user_text, ["开始训练", "带我练", "开始今天训练"]):
        return "session"
    if module == "workspace" and _contains_any(user_text, ["黑板", "markdown", "长内容"]):
        return "blackboard"
    return "overview"

def normalize_module(module: str) -> str:
    """Normalize module aliases to coach-ui canonical names."""
    m = (module or "").strip().lower()
    if m in {"home", "dashboard"}:
        return "home"
    if m in {"plans", "plan", "nutrition", "diet"}:
        return "plans"
    if m in {"training", "workout", "train"}:
        return "training"
    if m in {"assessment", "evaluate", "evaluation"}:
        return "assessment"
    if m in {"workspace", "other", "others"}:
        return "workspace"
    return "home"


def _default_cards(module: str) -> List[Dict[str, Any]]:
    if module in {"training", "workout"}:
        return [
            {"id": "today_plan", "title": "今日训练", "value": "胸肩三头（45 分钟）", "priority": "high"},
            {"id": "next_action", "title": "建议下一步", "value": "开始热身，肩部激活 5 分钟"},
        ]
    if module in {"plans", "nutrition"}:
        return [
            {"id": "daily_target", "title": "今日目标", "value": "2200 kcal / 蛋白 160g", "priority": "high"},
            {"id": "status", "title": "当前进度", "value": "早餐未记录"},
        ]
    if module == "assessment":
        return [
            {"id": "movement_eval", "title": "动作评估", "value": "上传视频检查动作标准度", "priority": "high"},
            {"id": "physique_eval", "title": "体态评估", "value": "上传肌肉照片进行阶段评估"},
        ]
    if module == "workspace":
        return [
            {"id": "blackboard", "title": "训练黑板", "value": "可用 Markdown 记录本周重点", "priority": "medium"},
            {"id": "notes", "title": "教练笔记", "value": "记录疲劳感、恢复和调整建议"},
        ]
    return [
        {"id": "overview", "title": "今日总览", "value": "训练 / 饮食 / 评估 一站式管理", "priority": "high"},
        {"id": "coach_tip", "title": "教练建议", "value": "先完成训练，再补充饮食记录"},
    ]


def _default_sections(module: str) -> List[Dict[str, Any]]:
    if module in {"training", "workout"}:
        return [
            {
                "id": "training_panel",
                "type": "training_panel",
                "title": "专业训练面板",
                "fields": {
                    "exercise": "杠铃卧推",
                    "set_progress": "第 2 组 / 共 4 组",
                    "target": "8-10 次，建议 60kg",
                    "rest_seconds": 90,
                    "tip": "下放 2 秒，底部停顿 0.5 秒，稳定推起",
                },
            }
        ]
    if module in {"plans", "nutrition"}:
        return [
            {
                "id": "plan_overview",
                "type": "plan_overview",
                "title": "计划概览",
                "items": [
                    {"id": "training", "title": "训练计划概览", "subtitle": "本周 4 练，当前第 2 周"},
                    {"id": "nutrition", "title": "饮食计划概览", "subtitle": "2200 kcal，蛋白 160g"},
                    {"id": "changes", "title": "最近调整记录", "subtitle": "卧推工作组 4 -> 3"},
                ],
            }
        ]
    if module == "home":
        return [
            {
                "id": "home_metrics",
                "type": "metrics",
                "title": "今日总览",
                "items": [
                    {"id": "sessions", "title": "本周完成", "value": "3 / 4", "hint": "训练次数"},
                    {"id": "streak", "title": "连续打卡", "value": "6 天", "hint": "保持不错"},
                ],
            },
            {
                "id": "home_focus",
                "type": "focus",
                "title": "今日重点",
                "text": "胸肩三头训练 + 高蛋白饮食，建议先训练再补饮食记录。",
            },
        ]
    return [
        {
            "id": "default_list",
            "type": "list",
            "title": "模块信息",
            "items": _default_cards(module),
        }
    ]


def _default_actions(module: str) -> List[Dict[str, Any]]:
    common = [{"id": "open_chat", "label": "和教练聊聊", "risk": "low", "kind": "navigate"}]
    if module in {"training", "workout"}:
        return [
            {"id": "start_workout", "label": "开始训练", "risk": "low", "kind": "execute"},
            {"id": "adjust_plan", "label": "调整计划", "risk": "medium", "kind": "confirm_execute"},
        ] + common
    if module in {"plans", "nutrition"}:
        return [
            {"id": "log_meal", "label": "记录饮食", "risk": "low", "kind": "execute"},
            {"id": "adjust_macros", "label": "调整营养目标", "risk": "medium", "kind": "confirm_execute"},
        ] + common
    if module == "assessment":
        return [
            {"id": "upload_video", "label": "上传动作视频", "risk": "low", "kind": "execute"},
            {"id": "upload_photo", "label": "上传肌肉照片", "risk": "low", "kind": "execute"},
        ] + common
    if module == "workspace":
        return [
            {"id": "open_blackboard", "label": "打开黑板", "risk": "low", "kind": "navigate"},
            {"id": "new_note", "label": "新建笔记", "risk": "low", "kind": "execute"},
        ] + common
    return [
        {"id": "go_workout", "label": "进入训练模块", "risk": "low", "kind": "navigate"},
        {"id": "go_nutrition", "label": "进入饮食模块", "risk": "low", "kind": "navigate"},
        {"id": "go_assessment", "label": "进入评估模块", "risk": "low", "kind": "navigate"},
    ] + common


def build_ui_state(last_user_text: str) -> Dict[str, Any]:
    """Build a stable, cross-platform UI state protocol."""
    module = normalize_module(_module_from_query(last_user_text))
    sub_state = _sub_state_from_query(module, last_user_text)
    return build_ui_state_for_module(module, sub_state=sub_state, last_user_text=last_user_text)


def build_ui_state_for_module(module: str, sub_state: str = "overview", last_user_text: str = "") -> Dict[str, Any]:
    """Build ui_state for a specific module."""
    module = normalize_module(module)
    coach_message = "我已根据你的当前意图准备页面，你可以手动操作，也可以让我代你操作。"
    if module == "plans":
        coach_message = "当前计划已经展示在页面上了，你可以继续查看详情或让我直接调整。"
    elif module == "training":
        coach_message = "已切到训练页，我可以直接带你完成当前训练。"
    return {
        "protocol_version": "coach-ui/1.0",
        "module": module,
        "sub_state": sub_state,
        "title": "FitFlow AI 操作系统",
        "coach_message": coach_message,
        "data": {"sections": _default_sections(module)},
        "cards": _default_cards(module),
        "actions": _default_actions(module),
    }


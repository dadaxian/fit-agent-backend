"""
Custom routes for Aegra: Auth, TTS, ASR, threads get-or-create.
Mounted alongside Agent Protocol. See: https://docs.aegra.dev/guides/custom-routes
"""
import os
import re
import json
from io import BytesIO
from pathlib import Path

import httpx
from fastapi import APIRouter, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, EmailStr

from fit_agent.auth_service import (
    create_access_token,
    create_user,
    authenticate_user,
    decode_token,
)
from fit_agent.database import get_db
from fit_agent.db import User
from fit_agent.ui_protocol import build_ui_state_for_module, normalize_module

ZHIPU_BASE = "https://open.bigmodel.cn/api/paas/v4"

router = APIRouter(prefix="/voice", tags=["voice"])
auth_router = APIRouter(prefix="/auth", tags=["auth"])

# Export app for Aegra http.app (https://docs.aegra.dev/guides/custom-routes)
app = FastAPI()

# --- Threads: 同一用户持久使用同一 thread ---
threads_router = APIRouter(prefix="/threads", tags=["threads"])
coach_os_router = APIRouter(prefix="/coach-os", tags=["coach-os"])
AEGRA_BASE = os.environ.get("AEGRA_BASE_URL", "http://127.0.0.1:8000").rstrip("/")
PROJECT_ROOT = Path(__file__).resolve().parent
WORKSPACE_BASE = PROJECT_ROOT / "workspace"


def _get_user_id_from_request(request: Request) -> str:
    """从 Authorization 头解析 JWT，返回 user_id。未登录则 401。"""
    auth = request.headers.get("Authorization") or request.headers.get("authorization") or ""
    token = auth.replace("Bearer ", "").strip()
    if not token:
        raise HTTPException(401, "请先登录（缺少 Authorization 头）")
    user_id = decode_token(token)
    if not user_id:
        raise HTTPException(401, "Token 无效或已过期，请重新登录")
    return user_id


def _sanitize_user_id(uid: str) -> str:
    return re.sub(r"[^\w\-]", "_", str(uid).strip()) or "dev"


def _workspace_dir(user_id: str) -> Path:
    return WORKSPACE_BASE / _sanitize_user_id(user_id)


def _load_json(path: Path) -> dict | list | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _extract_plan_days(plan: dict) -> list[dict]:
    """
    Normalize different plan schemas into:
    [{"day": "周一", "focus": "胸背", "exercise_count": 6}, ...]
    """
    days: list[dict] = []

    weekly = plan.get("weekly_schedule")
    # Schema A: {"周一": {"部位": "...", "动作": [...]}, ...}
    if isinstance(weekly, dict):
        for day, detail in list(weekly.items())[:7]:
            d = detail or {}
            focus = d.get("部位") or d.get("focus") or "训练"
            actions = d.get("动作") or d.get("exercises") or []
            exercise_count = len(actions) if isinstance(actions, list) else 0
            days.append({"day": day, "focus": focus, "exercise_count": exercise_count})
        return days

    # Schema B: [{"day":"周一","focus":"胸","exercises":[...]}]
    if isinstance(weekly, list):
        for item in weekly[:7]:
            if not isinstance(item, dict):
                continue
            day = item.get("day") or "训练日"
            focus = item.get("focus") or item.get("部位") or "训练"
            actions = item.get("exercises") or item.get("动作") or []
            exercise_count = len(actions) if isinstance(actions, list) else 0
            days.append({"day": day, "focus": focus, "exercise_count": exercise_count})
        return days

    # Schema C: {"schedule": {"monday":"胸背训练"}, "workouts":{"胸背训练":[...]}}
    schedule = plan.get("schedule")
    workouts = plan.get("workouts")
    if isinstance(schedule, dict):
        weekday_map = {
            "monday": "周一",
            "tuesday": "周二",
            "wednesday": "周三",
            "thursday": "周四",
            "friday": "周五",
            "saturday": "周六",
            "sunday": "周日",
        }
        for key, focus in list(schedule.items())[:7]:
            day = weekday_map.get(str(key).lower(), str(key))
            focus_text = str(focus or "训练")
            exercises = []
            if isinstance(workouts, dict):
                exercises = workouts.get(focus_text) or []
            exercise_count = len(exercises) if isinstance(exercises, list) else 0
            days.append({"day": day, "focus": focus_text, "exercise_count": exercise_count})
        return days

    return days


def _plan_sections_from_workspace(user_id: str) -> list[dict]:
    plan_path = _workspace_dir(user_id) / "workout" / "plans" / "current.json"
    plan = _load_json(plan_path)
    if not isinstance(plan, dict):
        return []
    plan_days = _extract_plan_days(plan)
    goal = plan.get("goal", "")
    freq = plan.get("frequency", "") or (f"每周{len(plan_days)}次" if plan_days else "")
    items = []
    for p in plan_days[:7]:
        day = p.get("day", "训练日")
        part = p.get("focus", "训练")
        count = p.get("exercise_count", 0)
        items.append(
            {
                "id": f"day_{day}",
                "title": f"{day} · {part or '训练'}",
                "subtitle": f"{count} 个动作",
            }
        )
    return [
        {
            "id": "plan_overview",
            "type": "plan_overview",
            "title": "计划概览",
            "items": items or [{"id": "empty", "title": "暂无计划", "subtitle": "请先创建训练计划"}],
        },
        {
            "id": "plan_meta",
            "type": "focus",
            "title": "计划信息",
            "text": f"目标：{goal or '未设置'}；频率：{freq or '未设置'}",
        },
    ]


def _training_sections_from_workspace(user_id: str) -> list[dict]:
    state_path = _workspace_dir(user_id) / "workout" / "session_state.json"
    state = _load_json(state_path)
    if not isinstance(state, dict):
        return []
    exercises = state.get("exercises", []) or []
    idx = int(state.get("current_exercise_index", 0) or 0)
    if idx < 0:
        idx = 0
    if idx >= len(exercises):
        idx = max(0, len(exercises) - 1)
    current = exercises[idx] if exercises else {}
    total_sets = current.get("target_sets", 0)
    completed_sets = current.get("completed_sets", 0)
    return [
        {
            "id": "training_panel",
            "type": "training_panel",
            "title": "专业训练面板",
            "fields": {
                "exercise": current.get("name", "当前无动作"),
                "set_progress": f"第 {completed_sets + 1} 组 / 共 {total_sets} 组" if total_sets else "暂无组次信息",
                "target": f"{current.get('target_reps', '--')} 次",
                "rest_seconds": 90,
                "tip": f"当前状态：{current.get('status', '待开始')}",
            },
        }
    ]


def _weekday_cn() -> str:
    from datetime import datetime

    mapping = {
        0: "周一",
        1: "周二",
        2: "周三",
        3: "周四",
        4: "周五",
        5: "周六",
        6: "周日",
    }
    return mapping[datetime.now().weekday()]


def _home_sections_from_workspace(user_id: str) -> list[dict]:
    ws = _workspace_dir(user_id)
    plan = _load_json(ws / "workout" / "plans" / "current.json") or {}
    session = _load_json(ws / "workout" / "session_state.json") or {}

    plan_days = _extract_plan_days(plan)
    total_days = len(plan_days)
    today = _weekday_cn()
    today_plan = next((p for p in plan_days if p.get("day") == today), None) or {}
    today_part = today_plan.get("focus", "今日计划待确认")
    today_actions_count = int(today_plan.get("exercise_count", 0) or 0)

    # 简单估算完成度：当前 session 中已完成组数 / 目标组数
    exercises = session.get("exercises", []) or []
    target_sets = 0
    completed_sets = 0
    for ex in exercises:
        try:
            target_sets += int(ex.get("target_sets", 0) or 0)
            completed_sets += int(ex.get("completed_sets", 0) or 0)
        except Exception:
            continue
    completion = "0%"
    if target_sets > 0:
        completion = f"{int(completed_sets * 100 / target_sets)}%"

    return [
        {
            "id": "home_metrics",
            "type": "metrics",
            "title": "今日总览",
            "items": [
                {
                    "id": "plan_days",
                    "title": "本周计划",
                    "value": f"{total_days} 天",
                    "hint": "已配置训练天数",
                },
                {
                    "id": "session_completion",
                    "title": "当前进度",
                    "value": completion,
                    "hint": f"{completed_sets}/{target_sets} 组",
                },
            ],
        },
        {
            "id": "home_focus",
            "type": "focus",
            "title": "今日重点",
            "text": f"{today} · {today_part}，共 {today_actions_count} 个动作。你可以直接进入训练模块开始。",
        },
    ]


@threads_router.post("/get-or-create")
def threads_get_or_create(request: Request):
    """
    获取或创建当前用户的 thread。同一用户始终返回同一 thread_id。
    需要登录（Bearer JWT）。
    """
    user_id = _get_user_id_from_request(request)
    auth_header = request.headers.get("Authorization") or request.headers.get("authorization") or ""

    with get_db() as db:
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            raise HTTPException(404, "用户不存在")
        if user.active_thread_id:
            return {"thread_id": user.active_thread_id}

        # 创建新 thread：调用 Aegra 的 POST /threads
        with httpx.Client(timeout=10.0) as client:
            r = client.post(
                f"{AEGRA_BASE}/threads",
                json={},
                headers={"Content-Type": "application/json", "Authorization": auth_header},
            )

        if r.status_code not in (200, 201):
            raise HTTPException(r.status_code, r.text or "创建 thread 失败")

        data = r.json()
        thread_id = data.get("thread_id")
        if not thread_id:
            raise HTTPException(500, "创建 thread 返回格式异常")

        user.active_thread_id = thread_id
        return {"thread_id": thread_id}


# --- Coach OS: 独立页面数据接口（不依赖 agent 流） ---
@coach_os_router.get("/modules/{module}")
def coach_os_get_module(module: str, request: Request):
    """
    获取 Coach OS 某个模块的数据快照。
    需要登录（Bearer JWT）。
    """
    user_id = _get_user_id_from_request(request)
    normalized = normalize_module(module)
    ui_state = build_ui_state_for_module(normalized, last_user_text=f"打开{normalized}模块")
    if normalized == "home":
        sections = _home_sections_from_workspace(user_id)
        if sections:
            ui_state["data"] = {"sections": sections}
            ui_state["coach_message"] = "已同步你的计划与训练进度，首页数据已更新。"
    elif normalized == "plans":
        sections = _plan_sections_from_workspace(user_id)
        if sections:
            ui_state["data"] = {"sections": sections}
            ui_state["coach_message"] = "已读取你的训练计划数据，页面已更新。"
    elif normalized == "training":
        sections = _training_sections_from_workspace(user_id)
        if sections:
            ui_state["data"] = {"sections": sections}
            ui_state["coach_message"] = "已读取你的训练进度，正在按当前动作展示。"
    # 预留权限位：后续可由后端基于状态控制模块阻断
    ui_state["permissions"] = {"blocked_modules": []}
    return {"user_id": user_id, "ui_state": ui_state}


# --- Auth ---
class RegisterRequest(BaseModel):
    email: EmailStr
    password: str
    display_name: str | None = None


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


@auth_router.post("/register")
def register(req: RegisterRequest):
    """注册新用户。"""
    if len(req.password) < 6:
        raise HTTPException(400, "密码至少 6 位")
    with get_db() as db:
        try:
            user = create_user(db, req.email, req.password, req.display_name)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        user_id = user.id
        user_email = user.email
        user_display_name = user.display_name
    return {
        "access_token": create_access_token(user_id),
        "user": {"id": user_id, "email": user_email, "display_name": user_display_name},
    }


@auth_router.post("/login")
def login(req: LoginRequest):
    """登录，返回 JWT。"""
    with get_db() as db:
        user = authenticate_user(db, req.email, req.password)
        if not user:
            raise HTTPException(401, "邮箱或密码错误")
        user_id = user.id
        user_email = user.email
        user_display_name = user.display_name
    return {
        "access_token": create_access_token(user_id),
        "user": {"id": user_id, "email": user_email, "display_name": user_display_name},
    }


def _get_api_key():
    key = os.environ.get("ZHIPUAI_API_KEY")
    if not key:
        raise HTTPException(503, "ZHIPUAI_API_KEY not configured")
    return key


def _ensure_wav(content: bytes, content_type: str) -> tuple[bytes, str]:
    """Convert webm/ogg/caf to wav if needed. 智谱 ASR only accepts wav/mp3."""
    if content_type and "wav" in content_type:
        return content, "audio/wav"
    if content_type and "mp3" in content_type:
        return content, "audio/mpeg"
    try:
        from pydub import AudioSegment

        bio = BytesIO(content)
        ct = (content_type or "").lower()
        if "webm" in ct:
            fmt = "webm"
        elif "caf" in ct or "caff" in ct:
            fmt = "caf"
        else:
            fmt = "ogg"
        seg = AudioSegment.from_file(bio, format=fmt)
        out = BytesIO()
        seg.export(out, format="wav")
        return out.getvalue(), "audio/wav"
    except Exception as e:
        raise HTTPException(
            400, f"Unsupported audio format (need wav/mp3). Conversion failed: {e}"
        ) from e


@router.post("/tts")
async def tts(
    text: str = Form(...),
    voice: str = Form("female"),
    speed: float = Form(1.5),
    volume: float = Form(1.0),
):
    """Text-to-Speech via GLM-TTS. Returns WAV audio. use_cache=True, speed 1.5 default."""
    api_key = _get_api_key()
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"{ZHIPU_BASE}/audio/speech",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": "glm-tts",
                "input": text,
                "voice": voice,
                "speed": speed,
                "volume": volume,
                "response_format": "wav",
                "use_cache": True,
            },
            timeout=30.0,
        )
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    return Response(content=r.content, media_type="audio/wav")


@router.post("/asr")
async def asr(file: UploadFile = File(...), prompt: str = Form(None)):
    """Speech-to-Text via GLM-ASR-2512. Accepts WAV/MP3/WebM, returns text.
    prompt: 可选，提供前文对话作为上下文纠偏（智谱文档建议小于 8000 字）。
    """
    api_key = _get_api_key()
    content = await file.read()
    if len(content) > 25 * 1024 * 1024:
        raise HTTPException(400, "File too large (max 25 MB)")
    content, ctype = _ensure_wav(content, file.content_type or "")
    data = {"model": "glm-asr-2512", "stream": "false"}
    if prompt and prompt.strip():
        data["prompt"] = prompt.strip()[:8000]
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"{ZHIPU_BASE}/audio/transcriptions",
            headers={"Authorization": f"Bearer {api_key}"},
            files={"file": ("audio.wav", content, ctype)},
            data=data,
            timeout=30.0,
        )
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    data = r.json()
    return {"text": data.get("text", "")}


app.include_router(threads_router)
app.include_router(coach_os_router)
app.include_router(auth_router)
app.include_router(router)

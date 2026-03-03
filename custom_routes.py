"""
Custom routes for Aegra: Auth, TTS, ASR, threads get-or-create.
Mounted alongside Agent Protocol. See: https://docs.aegra.dev/guides/custom-routes
"""
import os
from io import BytesIO

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

ZHIPU_BASE = "https://open.bigmodel.cn/api/paas/v4"

router = APIRouter(prefix="/voice", tags=["voice"])
auth_router = APIRouter(prefix="/auth", tags=["auth"])

# Export app for Aegra http.app (https://docs.aegra.dev/guides/custom-routes)
app = FastAPI()

# --- Threads: 同一用户持久使用同一 thread ---
threads_router = APIRouter(prefix="/threads", tags=["threads"])
AEGRA_BASE = os.environ.get("AEGRA_BASE_URL", "http://127.0.0.1:8000").rstrip("/")


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
app.include_router(auth_router)
app.include_router(router)

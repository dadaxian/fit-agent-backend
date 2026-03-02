"""
Custom routes for Aegra: Auth, TTS, ASR.
Mounted alongside Agent Protocol. See: https://docs.aegra.dev/guides/custom-routes
"""
import os
from io import BytesIO

import httpx
from fastapi import APIRouter, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, EmailStr

from fit_agent.auth_service import (
    create_access_token,
    create_user,
    authenticate_user,
)
from fit_agent.database import get_db

ZHIPU_BASE = "https://open.bigmodel.cn/api/paas/v4"

router = APIRouter(prefix="/voice", tags=["voice"])
auth_router = APIRouter(prefix="/auth", tags=["auth"])

# Export app for Aegra http.app (https://docs.aegra.dev/guides/custom-routes)
app = FastAPI()


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
async def asr(file: UploadFile = File(...)):
    """Speech-to-Text via GLM-ASR-2512. Accepts WAV/MP3/WebM, returns text."""
    api_key = _get_api_key()
    content = await file.read()
    if len(content) > 25 * 1024 * 1024:
        raise HTTPException(400, "File too large (max 25 MB)")
    content, ctype = _ensure_wav(content, file.content_type or "")
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"{ZHIPU_BASE}/audio/transcriptions",
            headers={"Authorization": f"Bearer {api_key}"},
            files={"file": ("audio.wav", content, ctype)},
            data={"model": "glm-asr-2512", "stream": "false"},
            timeout=30.0,
        )
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    data = r.json()
    return {"text": data.get("text", "")}


app.include_router(auth_router)
app.include_router(router)

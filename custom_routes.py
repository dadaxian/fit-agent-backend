"""
Custom routes for Aegra: TTS and ASR via 智谱 GLM-TTS / GLM-ASR-2512.
Mounted alongside Agent Protocol. See: https://docs.aegra.dev/guides/custom-routes
"""
import os
from io import BytesIO

import httpx
from fastapi import APIRouter, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import Response

ZHIPU_BASE = "https://open.bigmodel.cn/api/paas/v4"

router = APIRouter(prefix="/voice", tags=["voice"])

# Export app for Aegra http.app (https://docs.aegra.dev/guides/custom-routes)
app = FastAPI()


def _get_api_key():
    key = os.environ.get("ZHIPUAI_API_KEY")
    if not key:
        raise HTTPException(503, "ZHIPUAI_API_KEY not configured")
    return key


def _ensure_wav(content: bytes, content_type: str) -> tuple[bytes, str]:
    """Convert webm/ogg to wav if needed. 智谱 ASR only accepts wav/mp3."""
    if content_type and "wav" in content_type:
        return content, "audio/wav"
    if content_type and "mp3" in content_type:
        return content, "audio/mpeg"
    try:
        from pydub import AudioSegment

        bio = BytesIO(content)
        fmt = "webm" if (content_type or "").lower().find("webm") >= 0 else "ogg"
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
    speed: float = Form(1.0),
    volume: float = Form(1.0),
):
    """Text-to-Speech via GLM-TTS. Returns WAV audio."""
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


app.include_router(router)

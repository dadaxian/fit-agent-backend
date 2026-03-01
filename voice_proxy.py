#!/usr/bin/env python3
"""
Voice proxy for FitFlow: TTS (GLM-TTS) and ASR (GLM-ASR-2512) via 智谱 API.
Run: uv run python voice_proxy.py
"""
import os
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response

ZHIPU_BASE = "https://open.bigmodel.cn/api/paas/v4"


@asynccontextmanager
async def lifespan(app: FastAPI):
    api_key = os.environ.get("ZHIPUAI_API_KEY")
    if not api_key:
        print("Warning: ZHIPUAI_API_KEY not set, TTS/ASR will fail")
    yield


app = FastAPI(title="FitFlow Voice Proxy", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _get_api_key():
    key = os.environ.get("ZHIPUAI_API_KEY")
    if not key:
        raise HTTPException(503, "ZHIPUAI_API_KEY not configured")
    return key


@app.post("/tts")
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


def _ensure_wav(content: bytes, content_type: str) -> tuple[bytes, str]:
    """Convert webm/ogg to wav if needed. 智谱 ASR only accepts wav/mp3."""
    if content_type and "wav" in content_type:
        return content, "audio/wav"
    if content_type and "mp3" in content_type:
        return content, "audio/mpeg"
    # webm/ogg -> wav via pydub
    try:
        from io import BytesIO
        from pydub import AudioSegment
        bio = BytesIO(content)
        seg = AudioSegment.from_file(bio, format="webm" if "webm" in (content_type or "") else "ogg")
        out = BytesIO()
        seg.export(out, format="wav")
        return out.getvalue(), "audio/wav"
    except Exception as e:
        raise HTTPException(400, f"Unsupported audio format (need wav/mp3). Conversion failed: {e}") from e


@app.post("/asr")
async def asr(file: UploadFile = File(...)):
    """Speech-to-Text via GLM-ASR-2512. Accepts WAV/MP3/WebM, returns text."""
    api_key = _get_api_key()
    content = await file.read()
    if len(content) > 25 * 1024 * 1024:  # 25 MB
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


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("VOICE_PROXY_PORT", "8001"))
    uvicorn.run(app, host="0.0.0.0", port=port)

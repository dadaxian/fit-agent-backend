"""Voice API: ASR (GLM-ASR-2512) and TTS (GLM-TTS) proxy.

Run: uvicorn fit_agent.voice_api:app --port 8001 --reload
"""

import os
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from pydantic import BaseModel

ZHIPU_BASE = "https://open.bigmodel.cn/api/paas/v4"
ASR_URL = f"{ZHIPU_BASE}/audio/transcriptions"
TTS_URL = f"{ZHIPU_BASE}/audio/speech"


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    # shutdown


app = FastAPI(title="FitFlow Voice API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_api_key() -> str:
    key = os.environ.get("ZHIPUAI_API_KEY", "").strip()
    if not key:
        raise HTTPException(
            status_code=500,
            detail="ZHIPUAI_API_KEY not configured",
        )
    return key


class TTSRequest(BaseModel):
    text: str
    voice: str = "female"
    speed: float = 1.0
    volume: float = 1.0


@app.post("/asr")
async def asr(file: UploadFile = File(...)):
    """Speech-to-text: upload audio, get transcribed text."""
    api_key = get_api_key()
    content = await file.read()
    if len(content) == 0:
        raise HTTPException(status_code=400, detail="Empty audio file")

    # 智谱 ASR: multipart/form-data
    files = {"file": (file.filename or "audio.webm", content, file.content_type or "audio/webm")}
    data = {"model": "glm-asr-2512", "stream": "false"}

    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(
            ASR_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            files=files,
            data=data,
        )

    if resp.status_code != 200:
        err = resp.text
        try:
            j = resp.json()
            err = j.get("error", {}).get("message", err)
        except Exception:
            pass
        raise HTTPException(status_code=resp.status_code, detail=err)

    j = resp.json()
    # 智谱返回格式: {"text": "..."} 或类似
    text = j.get("text", "")
    return {"text": text}


@app.post("/tts")
async def tts(req: TTSRequest):
    """Text-to-speech: send text, get audio bytes."""
    api_key = get_api_key()
    if not req.text.strip():
        raise HTTPException(status_code=400, detail="Empty text")

    payload = {
        "model": "glm-tts",
        "input": req.text,
        "voice": req.voice,
        "speed": req.speed,
        "volume": req.volume,
        "response_format": "mp3",
    }

    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(
            TTS_URL,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json=payload,
        )

    if resp.status_code != 200:
        err = resp.text
        try:
            j = resp.json()
            err = j.get("error", {}).get("message", err)
        except Exception:
            pass
        raise HTTPException(status_code=resp.status_code, detail=err)

    return Response(content=resp.content, media_type="audio/mpeg")


@app.get("/health")
async def health():
    return {"status": "ok"}

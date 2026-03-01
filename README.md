# fit-agent

Built with [Aegra](https://github.com/ibbybuilds/aegra) -- a self-hosted LangGraph Platform alternative.

## Setup

```bash
cp .env.example .env       # Configure your environment
uv sync                    # Install dependencies
uv run aegra dev           # Start developing!
```

### Voice API (ASR + TTS)

语音转文字（智谱 GLM-ASR-2512）和文字转语音（智谱 GLM-TTS）需单独启动：

```bash
uv run uvicorn fit_agent.voice_api:app --port 8001 --reload
```

需配置 `ZHIPUAI_API_KEY`（与聊天共用）。

## Project Structure

```
fit_agent/
|-- aegra.json            # Graph configuration
|-- pyproject.toml        # Project dependencies
|-- .env.example          # Environment variable template
|-- src/fit_agent/
|   |-- __init__.py
|   |-- graph.py          # Your agent graph
|   |-- state.py          # Input and internal state
|   |-- prompts.py        # System prompt templates
|   |-- context.py        # Runtime configuration
|   |-- utils.py          # Utility functions
|   +-- voice_api.py     # Voice API (ASR/TTS proxy)
|-- docker-compose.yml    # Docker Compose (PostgreSQL + API)
+-- Dockerfile
```

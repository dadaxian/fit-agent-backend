# fit-agent

Built with [Aegra](https://github.com/ibbybuilds/aegra) -- a self-hosted LangGraph Platform alternative.

## Setup

```bash
cp .env.example .env       # Configure your environment
uv sync                    # Install dependencies
uv run aegra dev           # Start developing!
```

### 语音代理（TTS/ASR）

如需语音输入和朗读（智谱 GLM-TTS / GLM-ASR），需单独启动语音代理：

```bash
uv run python voice_proxy.py   # 默认端口 8001
```

需安装 ffmpeg（用于 webm→wav 转换）：`brew install ffmpeg`

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
|   +-- utils.py          # Utility functions
|-- docker-compose.yml    # Docker Compose (PostgreSQL + API)
+-- Dockerfile
```

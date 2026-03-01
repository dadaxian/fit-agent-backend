# fit-agent

Built with [Aegra](https://github.com/ibbybuilds/aegra) -- a self-hosted LangGraph Platform alternative.

## Setup

```bash
cp .env.example .env       # Configure your environment
uv sync                    # Install dependencies
uv run aegra dev           # Start developing!
```

### 语音（TTS/ASR）

语音输入和朗读通过 [Aegra custom routes](https://docs.aegra.dev/guides/custom-routes) 提供，与主服务同端口，无需单独启动。需配置 `ZHIPUAI_API_KEY`，并安装 ffmpeg（webm→wav 转换）：`brew install ffmpeg`

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

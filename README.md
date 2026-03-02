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

## 原生 iOS App（fit-swift）

若需原生 Swift 体验，可使用 `fit-swift/` 目录下的 iOS 项目：

```bash
cd fit-swift && open fit-swift.xcodeproj
```

详见 [fit-swift/README.md](fit-swift/README.md)。

## 文档

- [docs/README.md](docs/README.md) — 项目启动与迭代规范、AI 编码要求
- [docs/CHANGELOG.md](docs/CHANGELOG.md) — 变更记录
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 架构说明（Agent、工作区、Skills）

## Project Structure

```
fit_agent/
|-- aegra.json            # Graph configuration
|-- pyproject.toml        # Project dependencies
|-- .env.example          # Environment variable template
|-- docs/                 # 项目文档
|-- skills/               # Agent Skills（SKILL.md）
|-- workspace/            # 用户工作区（run_command cwd）
|-- src/fit_agent/
|   |-- graph.py          # brain ↔ executor 图
|   |-- nodes.py          # agent_node, tools_node
|   |-- tools.py          # run_command, mark_task_done
|   |-- skills_loader.py   # Skills 同步
|   |-- state.py, prompts.py, context.py, utils.py
|-- docker-compose.yml    # Docker Compose (PostgreSQL + API)
+-- Dockerfile
```

# fit-agent 项目文档

本目录为项目文档中心，供 AI 编码与人工查阅。

---

## 文档索引

| 文档 | 用途 |
|------|------|
| [README.md](README.md) | 本文档，项目启动与迭代规范 |
| [CHANGELOG.md](CHANGELOG.md) | 项目变更记录（每次修改必更新） |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 架构说明（Agent、工作区、Skills） |
| [LESSONS_LEARNED.md](LESSONS_LEARNED.md) | 踩坑记录（避免重复浪费时间） |
| [SESSION_ARCHITECTURE.md](SESSION_ARCHITECTURE.md) | 多会话 vs 单会话架构说明 |

---

## 一、项目启动与迭代

### 1.1 项目简介

**fit-agent** 是 AI 私教后端，基于 [Aegra](https://github.com/ibbybuilds/aegra) + LangGraph，为 fitter（React/Capacitor）和 fit-swift（原生 iOS）提供对话与能力支持。

**核心能力**：
- 对话 Agent（支持训练、饮食、评估、档案等长期支持）
- 语音 TTS/ASR（智谱，通过 custom routes）
- 工作区 + run_command + Skills（参考 biagent agent_meta）

### 1.2 迭代描述文档的读写

- **CHANGELOG.md**：每次有代码或配置变更时，在文件顶部追加一条记录，格式见下方。
- **ARCHITECTURE.md**：架构有调整时更新；新增模块、工具、Skill 时补充说明。
- **本文档**：迭代流程、aicoding 要求变更时更新。

### 1.3 变更记录格式（CHANGELOG）

每次变更在 `CHANGELOG.md` 顶部追加：

```markdown
## [YYYY-MM-DD] 变更简述

- **变更类型**：新增 | 修改 | 修复 | 重构
- **涉及模块**：graph / tools / skills / custom_routes / fitter / fit-swift / docs
- **变更内容**：
  - 具体改动 1
  - 具体改动 2
- **备注**：（可选）
```

### 1.4 AI 编码（aicoding）要求

进行 AI 辅助开发时，请遵循：

1. **变更前**：阅读 `docs/ARCHITECTURE.md` 了解当前架构；阅读 `docs/CHANGELOG.md` 了解近期变更。
2. **变更后**：在 `docs/CHANGELOG.md` 顶部追加本次变更记录。
3. **新增能力**：在 `ARCHITECTURE.md` 中补充说明；若为 Skill，在 `skills/<name>/SKILL.md` 中写清用法。
4. **保持文档与代码同步**：代码结构、配置、环境变量变更时，同步更新 README、.env.example、本文档等。
5. **中文优先**：用户-facing 文案、注释、文档以中文为主；代码标识符可英文。

---

## 二、快速启动

```bash
cp .env.example .env   # 配置环境变量
uv sync                # 安装依赖
uv run aegra dev       # 启动服务（含语音 custom routes）
```

详见根目录 [README.md](../README.md)。

### 2.1 模型与工具调用

智谱 GLM 需使用**支持工具调用**的模型。若 LangSmith 显示模型一直不调用 tool：

1. 将 `MODEL` 改为 `zhipuai/glm-4.7-flash` 或 `zhipuai/glm-4-flash`（勿用 `glm-4-flashx`）
2. ChatZhipuAI 仅支持 `tool_choice="auto"`，无法强制；若仍无效，多为模型兼容问题

**thinking 模式**：fit-agent 默认关闭智谱 thinking（`thinking: {"type": "disabled"}`），以加快 tool calling 等场景的响应。GLM-4.7 等模型默认开启 thinking 会显著增加延迟。

---

## 三、目录结构速览

```
fit-agent/
├── docs/                 # 项目文档（本目录）
├── src/fit_agent/       # Agent 核心
├── custom_routes.py     # 语音 TTS/ASR
├── skills/              # Agent Skills（SKILL.md）
├── workspace/           # 用户工作区（run_command cwd）
├── fitter/              # React 前端
├── fit-swift/           # 原生 iOS
└── aegra.json           # Aegra 配置
```

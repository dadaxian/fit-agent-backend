# 项目变更记录

每次代码或配置变更后，在**本文件顶部**追加一条记录。格式见 [docs/README.md](README.md#13-变更记录格式changelog)。

---

## [2026-03-02] 跨会话共享 + 主动记录训练进度

- **变更类型**：新增/修改
- **涉及模块**：skills、prompts、docs
- **变更内容**：
  - 新增 session_state 技能：`workout/session_state.json` 记录训练进度，跨会话共享
  - 强化 planning 技能：跨会话共享原则，不要为每个会话新建计划
  - 强化 training 技能：用户提到进度时主动更新 session_state，不等用户说「帮我记录」
  - 更新 prompt：同一用户所有会话共享 workspace，主动记录进度
  - 新增 SESSION_ARCHITECTURE.md：多会话 vs 单会话架构说明，当前采用多会话共享
- **备注**：解决「信息分散」「不主动记录」「多会话数据共享」问题

---

## [2026-03-02] 用户体系与登录

- **变更类型**：新增
- **涉及模块**：db、auth、alembic、custom_routes、nodes
- **变更内容**：
  - 新增 users 表（Alembic 迁移），id 为 UUID 主键，供其他表作外键引用
  - 新增 auth 模块：POST /auth/register、POST /auth/login，返回 JWT
  - Aegra auth 配置：JWT 验证，identity=user_id 传入 graph configurable
  - nodes 从 langgraph_auth_user.identity 获取 user_id
  - Alembic 使用独立 version 表 fit_agent_alembic_version，避免与 LangGraph 冲突
- **备注**：需设置 JWT_SECRET。前端需在请求头携带 Authorization: Bearer <token>

---

## [2025-03-02] 修复 iOS Swift 消息重复发送与展示顺序

- **变更类型**：修复
- **涉及模块**：fit-swift/ChatViewModel.swift
- **变更内容**：
  - 只发送本条新消息到 API，thread 已有历史，避免重复
  - 按 rawMsgs 顺序构建 displayItems，aiText 在处理 ai 消息时按序插入
  - 新增 sendInProgress 防止双击重复发送
- **备注**：LangGraph Platform thread 会合并 input 与现有 state，故只需传新消息

---

## [2025-03-02] 气泡支持 Markdown 渲染

- **变更类型**：新增/修改
- **涉及模块**：fitter、fit-swift
- **变更内容**：
  - Fitter：新增 MarkdownText 组件（react-markdown + remark-gfm），HumanBubble、AIBubble、ToolBubble 使用 Markdown 渲染
  - Swift：新增 MarkdownText 视图（AttributedString markdown），ChatBubble、ChatDisplayItemView 使用 Markdown 渲染
- **备注**：AI 回复默认 Markdown 格式，现正确渲染粗体、列表、代码等

---

## [2025-03-02] iOS 流式显示 + Agent 思考过程展示

- **变更类型**：新增/修改
- **涉及模块**：fit-swift、fitter
- **变更内容**：
  - Swift：stream_mode 改为 ["values", "messages"]，解析 data.values.messages，支持流式更新
  - Swift：新增 ChatDisplayItem（human/aiText/toolCall/toolResult），展示 Agent 思考过程（run_command、mark_task_done 等）
  - Fitter：AIBubble 展示 tool_calls，新增 ToolBubble 展示工具结果
- **备注**：后端 values 模式按步推送状态，messages 模式可提供 token 流（若 LLM 开启 streaming）

---

## [2025-03-02] 关闭智谱 thinking 模式以加快响应

- **变更类型**：修改
- **涉及模块**：src/fit_agent/_zhipu.py
- **变更内容**：新增 FitZhipuAI 子类，在 _default_params 中注入 `thinking: {"type": "disabled"}`，关闭 GLM-4.7 等模型的默认 thinking 模式
- **备注**：thinking 开启会显著增加延迟；关闭后可加快 tool calling 等场景的响应

---

## [2025-03-02] 模型不调用 tools 为模型兼容问题（记录）

- **变更类型**：文档
- **涉及模块**：docs
- **变更内容**：确认「模型一直不调用 tools」为模型兼容问题，需使用支持工具调用的模型（如 glm-4.7-flash），勿用 glm-4-flashx
- **备注**：ChatZhipuAI 仅支持 tool_choice="auto"，无法强制

---

## [2025-03-02] 修复模型不调用工具 + ChatZhipuAI tool_choice 限制

- **变更类型**：修改
- **涉及模块**：src/fit_agent/nodes.py、.env.example、docs
- **变更内容**：
  - ChatZhipuAI 仅支持 `tool_choice="auto"`，无法强制；移除 tool_choice="any"
  - 推荐使用 glm-4.7-flash（glm-4-flashx 可能不支持工具调用）
- **备注**：若仍不调用工具，请将 MODEL 改为 `zhipuai/glm-4.7-flash`

---

## [2025-03-02] 强化 mark_task_done 的 prompt 要求

- **变更类型**：修改
- **涉及模块**：src/fit_agent/prompts.py、tools.py
- **变更内容**：重写工具与结束规则说明，强调「必须调用 mark_task_done 否则系统无法结束」；在 prompt 末尾再次强调；更新 mark_task_done 的 tool description

---

## [2025-03-02] 添加 LangSmith 追踪环境变量

- **变更类型**：新增
- **涉及模块**：.env、.env.example
- **变更内容**：新增 `LANGCHAIN_TRACING_V2`、`LANGCHAIN_API_KEY`、`LANGCHAIN_PROJECT`，用于在 langsmith.com 查看 trace、调试 Agent
- **备注**：需在 https://smith.langchain.com/ 获取 API Key，替换 `.env` 中的 `LANGCHAIN_API_KEY`

---

## [2025-03-02] 修复 mark_task_done 未调用导致无限循环

- **变更类型**：修改
- **涉及模块**：src/fit_agent/prompts.py、nodes.py
- **变更内容**：
  - 强化 prompt：明确每次回复必须包含 tool_call（run_command 或 mark_task_done）
  - 首次无 tool_call 即提醒，最多重试 1 次后强制结束
  - 兜底逻辑：Agent 已输出文本结论但未调用 mark_task_done 时，视为隐式完成并结束，避免 React 循环
- **备注**：解决 Agent 只输出文字不调用 mark_task_done 导致的无限循环问题

---

## [2025-03-02] run_command 改为项目根目录执行

- **变更类型**：修改
- **涉及模块**：src/fit_agent/tools.py、prompts.py、skills/training、docs
- **变更内容**：
  - run_command 的 cwd 从 `workspace/<user_id>/` 改为**项目根目录**（fit-agent/）
  - Agent 可在项目内创建目录、读写文件，解决「系统不允许执行创建目录指令」问题
  - 更新 prompt、training SKILL、ARCHITECTURE 中的路径说明
- **备注**：用户数据仍在 `workspace/<user_id>/` 下，Agent 需使用 `workspace/<user_id>/` 前缀或 `cd workspace/<user_id> &&` 链式命令

---

## [2025-03-02] 实现 run_command + Skills + 文档体系

- **变更类型**：新增
- **涉及模块**：docs、src/fit_agent、skills、workspace
- **变更内容**：
  - 新增 `docs/README.md`：项目启动与迭代规范、aicoding 要求
  - 新增 `docs/CHANGELOG.md`：变更记录（本文件）
  - 新增 `docs/ARCHITECTURE.md`：架构说明
  - 新增 `run_command`、`mark_task_done` 工具，工作区按 user_id 隔离
  - 新增 brain ↔ executor 循环，支持 tool_calls
  - 新增 skills 目录与 training Skill，同步到 workspace
  - 根目录 README 补充 docs、workspace 说明
  - .gitignore 增加 workspace/
- **备注**：参考 biagent agent_meta 设计。测试需配置 `ZHIPUAI_API_KEY`

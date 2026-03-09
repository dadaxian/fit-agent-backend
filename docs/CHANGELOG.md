# 项目变更记录

每次代码或配置变更后，在**本文件顶部**追加一条记录。格式见 [docs/README.md](README.md#13-变更记录格式changelog)。

---

## [2026-03-08] Coach OS 子页与黑板兜底（prompt + API + iOS）

- **变更类型**：修改 | 新增
- **涉及模块**：fit-agent / fit-swift / docs
- **变更内容**：
  - 系统 prompt 增强：气泡短回复预算（1–3 句）、LLM 主动跳转协同、长内容落黑板文件策略、`sub_state` 约定（plans.today / training.session / workspace.blackboard）。
  - `ui_command` 增强：支持 `sub_state`（同时兼容 `payload.sub_state`）。
  - 后端新增黑板读取接口：`GET /coach-os/blackboard`，返回当前用户黑板 markdown。
  - 模块接口支持 `sub_state`：`GET /coach-os/modules/{module}?sub_state=...`，新增 `plans.today` 数据区块。
  - iOS 补齐子页渲染：Plans Today、Workspace Blackboard（使用 `MarkdownUI` 渲染），并按 `ui_command` 的 `module+sub_state` 执行切页与数据拉取。

---

## [2026-03-08] Coach OS 工具流交互修正

- **变更类型**：修改
- **涉及模块**：fit-swift / fit-agent / docs
- **变更内容**：
  - iOS 对话不再依赖 `ui_state` 固定文案，改为显示最新 AI 文本。
  - 移除前端“意图预切页”逻辑，仅接受 `ui_command` 导航指令。
  - 修正思考中动效触发：基于 `isAgentThinking` 控制旋转环。
  - prompt 强制在调用 `ui_command` 时仍输出一句回复。

---

## [2026-03-08] LLM 主动 UI 命令（tool 化）

- **变更类型**：修改 | 新增
- **涉及模块**：fit-agent / fit-swift / docs
- **变更内容**：
  - 新增 `ui_command` 工具：允许 LLM 主动输出结构化页面控制指令（如 navigate/show_message）。
  - `tools_node` 将 `ui_command` 结果写入 `ToolMessage.additional_kwargs.ui_command`，同时序列化为 JSON 便于解析。
  - iOS 解析 `tool` 消息并执行 UI 命令：支持切页与气泡消息更新，保持对话流式输出不受影响。
  - 更新系统 prompt，允许 LLM 使用 `ui_command` 控制页面。

---

## [2026-03-08] Coach OS 接入后端 ui_state（v1）

- **变更类型**：修改 | 新增
- **涉及模块**：fit-swift / graph / nodes / docs
- **变更内容**：
  - 后端 `ui_state` 协议升级：新增 `data.sections`，按模块输出结构化区块（home metrics/focus、plans overview、training panel）。
  - `CoachOSMockView` 从本地 mock 切换为真实拉取后端 `waitRun` 结果，并解析 `AIMessage.additional_kwargs.ui_state` 驱动页面切换与数据渲染。
  - iOS 在发送消息时附带 `ui_context`（当前 module/sub_state），打通“当前页面语义 -> 后端决策 -> 前端切页”的闭环。
  - 保留现有视觉与交互（Dock tab、悬浮教练、语音切换输入），但渲染数据改为以后端协议为主，fallback 到 cards。
  - 修复模块路由：`查看计划` 等计划类意图优先映射到 `plans`（不再误入 `training/workout`），并补充计划/训练态的教练回复文案。
  - 交互体验优化：请求处理中时右下教练头像增加旋转环动效，避免“卡死感”；tab 点击改为用户可先本地切换，再异步同步后端，且预留后端 `permissions.blocked_modules` 阻断能力。
  - 头像动效收敛：仅在用户发起对话请求等待回复时显示“思考中”旋转环；手动 tab 切换不触发思考态。
  - 页面切换策略调整：用户点击 tab 立即本地切页，不再依赖 agent 返回；当前页数据采用“页面主动拉取（v1 fallback mock）”，agent 主要负责意图驱动和后端数据修改。
  - 前端新增“意图预切页”兜底：用户发送“查看计划/训练/评估”等语句时先本地切页，再异步等待后端结果，避免因后端延迟导致页面不切换的体感问题。
  - 新增独立模块数据接口：`GET /coach-os/modules/{module}`（需登录），返回 `ui_state`；iOS tab 切换改为直接请求该接口获取页面数据，不再依赖 agent 运行链路。
  - 模块接口接入真实工作区数据：`plans` 读取 `workspace/<user_id>/workout/plans/current.json`，`training` 读取 `workspace/<user_id>/workout/session_state.json`；无数据时自动回退 mock。
  - `home` 模块接入真实聚合：从计划与 session 计算首页指标（本周计划天数、当前组次完成率）与今日重点文案（按当日计划部位/动作数）。
  - 修复 plans 接口兼容性：支持多种计划 JSON 结构（`weekly_schedule` 字典、`weekly_schedule` 列表、`schedule + workouts`），避免 tab 点击时报 `list has no attribute items`。
- **备注**：当前为 v1 页面控制（切页 + 展示），动作执行链路（action 回传与确认）下一步接入。

---

## [2026-03-08] iOS 新版 Coach OS 全屏入口与双层页面 Mock

- **变更类型**：新增 | 修改
- **涉及模块**：fit-swift / docs
- **变更内容**：
  - 新增 `fit-swift/fit-swift/CoachOSMockView.swift`：全屏 Coach OS mock 页面，采用“里层页面系统 + 下方 tab + 外层对话输入与教练头像”双层结构。
  - 保留原页面不动，仅在 `ChatMainView` 右上角新增入口按钮（sparkles 图标），点击后以 `fullScreenCover` 打开 Coach OS。
  - Coach OS 内部使用 mock 数据模拟模块切换（首页/计划/训练/评估/其他）和教练驱动跳转，便于先验证交互与布局。
  - 输入栏左侧改为语音/键盘切换（复用既有按钮与按住说话组件）；教练头像改为右下角悬浮，支持弹出消息气泡并基于用户输入联动当前模块（如“查看进入计划”）。
  - 调整里层布局：模块 tab 由底部上移到页面顶部，底部只保留输入区；页面整体改为更强的 iOS 玻璃风（渐变背景+毛玻璃卡片+轻描边）。
  - 顶部导航条改为浮动小关闭按钮（仅保留关闭能力，图标缩小）；主屏可视空间增大。首页/计划/训练内容改为差异化布局（首页指标卡、计划可点进概览、训练专业面板），不再统一列表样式。
  - 顶部模块切换条改为 iOS Dock 风格（胶囊玻璃底、仅图标、选中圆形高亮与轻微弹簧动效），提升系统感与辨识度。
- **备注**：本次仅实现 iOS 前端壳与交互原型，暂未接入后端真实协议与动作执行链路。

---

## [2026-03-08] AI 操作系统页面协议 MVP（去 A2UI）

- **变更类型**：新增 | 修改
- **涉及模块**：graph / nodes / fit-swift / docs
- **变更内容**：
  - 新增后端平台无关 UI 协议生成器 `src/fit_agent/ui_protocol.py`，统一输出 `protocol_version/module/sub_state/cards/actions`。
  - 在 `agent_node` 中为每条 AI 消息注入 `additional_kwargs.ui_state`，让终端按统一协议渲染，不耦合 iOS/Android 视图实现。
  - iOS 首页改为「AI 操作系统」视图：通过现有 `waitRun` 拉取并解析 `ui_state`，渲染固定结构卡片与动作清单。
  - iOS 首页新增浮动教练头像入口，可一键切换到私教聊天 Tab（用户可手动操作 + Agent 页面驱动并存）。
  - `ContentView` 接入首页到聊天页的切换闭环（首页可直接拉起聊天）。
- **备注**：该版本为 MVP，先打通「后端协议 -> 终端渲染」主链路，后续再接入真正的 action 执行与确认流。

---

## [2026-03-05] 优化 iOS 流式输出性能与显示稳定性

- **变更类型**：修复 | 重构
- **涉及模块**：fit-swift / docs
- **变更内容**：
  - **性能重构**：引入 `Data` 缓冲区机制，将 SSE 解析从“逐字节”改为“按行”处理，彻底解决 CPU 飙升至 99% 的性能瓶颈。
  - **异步解耦**：将 JSON 解析与字符串清洗（剔除 `</think>` 思考过程）移至后台线程（`Task.detached`），确保不阻塞 UI 渲染。
  - **回闪修复**：针对 `values` 事件包含全量历史的特性，增加 AI 消息过滤逻辑，确保 UI 始终显示当前活跃回复，解决旧消息“回闪”问题。
  - **差异化刷新**：增加内容变化校验，仅在模型吐出新词时触发 SwiftUI 渲染，极大降低资源占用。
  - **测试验证**：新增 `SimpleChatTestView.swift` 极简测试页面，用于纯净环境下验证流式协议。
  - **文档更新**：在 `docs/LESSONS_LEARNED.md` 中记录 iOS 流式优化的核心避坑经验。
  - **告警清理**：移除 `ChatViewModel` 中多余的 `await`，修复 Swift 6 并发捕获警告；SSE 解析兼容数组数据结构，避免无效强转。
- **备注**：大幅提升了 iOS 原生端的对话流畅度，降低了设备发热。

---

## [2026-03-05] 上下文压缩讨论稿

- **变更类型**：文档
- **涉及模块**：docs
- **变更内容**：
  - 新增 `docs/CONTEXT_COMPRESSION.md`：上下文压缩方案（随机遗忘、token 兜底、存档回查）
- **备注**：讨论稿，待确认触发规则与权重细节

---

## [2026-03-06] 上下文压缩与记忆旁路表落地

- **变更类型**：新增/修改
- **涉及模块**：db / alembic / nodes / docs
- **变更内容**：
  - 新增记忆旁路表：`memory_summaries`、`message_memory`
  - 新增 `fit_agent/memory.py`：摘要更新、消息打分、随机遗忘
  - `nodes.py` 注入长期记忆并在后台更新摘要与打分
  - 更新 `docs/CONTEXT_COMPRESSION.md`：补充实现步骤
  - 可选嵌入：支持 `MEMORY_EMBEDDING_MODEL` 生成消息向量
  - system_prompt 增加记忆系统说明（包含重要性评分与遗忘逻辑）
  - 新增时间感知提示：若上下文包含 `timestamp` 元数据，注意时效性
  - fitter 发送 human 消息时附带 ISO8601 `timestamp`
  - 新增 `APP_TIMEZONE` 支持：system_prompt 与消息时间戳使用可配置时区
  - fitter/iOS human 消息补充 `timezone` 字段（VITE_TIMEZONE/设备时区）
- **备注**：窗口触发摘要与打分，消息仅替换内容不删位置

---

## [2026-03-02] 单会话模式

- **变更类型**：架构调整
- **涉及模块**：custom_routes、db、fitter、fit-swift、docs
- **变更内容**：
  - 从多会话改为**单会话**：每用户一个 thread，`users.active_thread_id` 存储
  - `POST /threads/get-or-create` 返回或创建用户 thread，需登录
  - fitter、fit-swift 移除「新对话」，登录后调用 get-or-create 获取 thread
  - 更新 SESSION_ARCHITECTURE.md：当前决策为方案 B（单会话）
- **备注**：符合「和教练一对一」心智，对话历史完整可回顾

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

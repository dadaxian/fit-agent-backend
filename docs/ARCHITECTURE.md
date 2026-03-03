# fit-agent 架构说明

## 一、整体架构

```
用户请求 (fitter / fit-swift)
    ↓
Aegra (LangGraph Platform)
    ↓
fit-agent graph: brain ↔ executor
    ↓
run_command (workspace/<user_id>/) + Skills
```

## 二、Agent 设计

### 2.1 Workflow

- **brain**：LLM 节点，可调用 `run_command`、`mark_task_done`
- **executor**：执行 tool_calls，返回结果
- **路由**：有 tool_calls → executor；无 tool_calls 且 task_complete → end；否则继续 brain

### 2.2 工具（Tools）

| 工具 | 说明 |
|------|------|
| `run_command(cmd)` | 在**项目根目录**下执行 shell 命令，可创建目录、读写文件 |
| `mark_task_done(reason)` | 标记任务完成，用于路由结束 |

### 2.3 同一用户持久 thread

- **策略**：同一用户始终使用同一 thread，对话历史跨会话累积。
- **实现**：`POST /threads/get-or-create`（需登录）返回该用户的 thread_id；`users.active_thread_id` 存储用户活跃 thread。
- **前端**：fit-swift、fitter 登录后调用 get-or-create 获取 thread，不再提供「新对话」清空 thread。

### 2.4 工作区（Workspace）

- **路径**：`workspace/<user_id>/`
- **隔离**：按 user_id 划分，同一用户多会话共享数据
- **run_command cwd**：项目根目录，Agent 可在项目内创建目录、读写文件；用户数据在 `workspace/<user_id>/` 下
- **user_id**：来自 `config.configurable.user_id`，缺省为 `"dev"`

### 2.5 Skills

- **形式**：`skills/<name>/SKILL.md`，Markdown 文档
- **用法**：Agent 通过 `cat workspace/<user_id>/skills/<name>/SKILL.md` 读取，再按说明用 run_command 执行
- **同步**：每次调用前将 skills 同步到 `workspace/<user_id>/skills/`
- **当前 Skill**：training（训练计划、记录、动作库）

## 三、数据存储（文本优先）

- 用户数据以 JSON/文本形式存放在 workspace 下
- 结构由各 Skill 的 SKILL.md 约定，无固定 schema
- 示例：`workout/plans.json`、`nutrition/meals.json`、`profile.json`

## 四、与 biagent agent_meta 的差异

| 项目 | biagent | fit-agent |
|------|---------|-----------|
| 工作区键 | thread_id | user_id |
| 场景 | 数据分析 | 私教、训练、饮食、评估 |
| Skills | 取数、分析、可视化 | 训练、饮食、评估、档案 |

---
name: training
description: 训练数据（动作库、执行记录）的读写。计划相关操作见 planning 技能。
---

# training

## 适用场景

- 用户提到训练进度（「这组做完了」「练到一半」「记一下 8 个 50kg」）→ 必须先读取 **session_state** 技能，**主动**更新 `workout/session_state.json`
- 查看动作库、执行历史
- **计划相关**（今天练什么、创建/修改计划）→ 必须先读取 **planning** 技能：`cat workspace/<user_id>/skills/planning/SKILL.md`

## 数据路径

run_command 在**项目根目录**执行。用户数据在 `workspace/<user_id>/` 下。

| 路径（相对于 workspace/<user_id>/） | 说明 |
|------|------|
| `workout/plans/current.json` | **当前计划**（与 planning 技能一致，唯一数据源） |
| `workout/session_state.json` | **当前训练进度**（跨会话共享，见 session_state 技能） |
| `workout/plans/archive/` | 历史计划归档 |
| `workout/records/` | 执行记录目录，按日期存 |
| `workout/exercise_library.json` | 动作库（可选） |

**重要**：计划创建、读取、修改一律使用 `workout/plans/current.json`，不得使用其他路径。

## 调用方式

```bash
# 查看当前计划（与 planning 一致）
cat workspace/<user_id>/workout/plans/current.json

# 创建目录
mkdir -p workspace/<user_id>/workout/plans/archive
mkdir -p workspace/<user_id>/workout/records

# 查看执行记录
ls workspace/<user_id>/workout/records
```

## 数据格式

- **current.json**：见 planning 技能的 JSON Schema（week_cycle、exercises 等）
- **exercise_library.json**：`[{"id":"xxx","name":"杠铃深蹲","sets":4,"reps":8,"rest":90}]`（可选）
- **records/**：按日期或 session 存，格式可灵活

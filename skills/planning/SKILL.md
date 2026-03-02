---
name: planning
description: 训练计划的创建、读取、修改规范。私教规划能力的核心，必须严格遵循路径与流程。
---

# planning · 训练规划

## 核心原则

**唯一数据源**：所有计划的创建、读取、修改，**必须**在 `workspace/<user_id>/workout/plans/` 下完成。禁止在其他路径创建或查找计划文件。

---

## 一、数据路径（强制规范）

| 路径 | 说明 |
|------|------|
| `workspace/<user_id>/workout/plans/current.json` | **当前激活计划**，唯一。读取、修改计划都操作此文件。 |
| `workspace/<user_id>/workout/plans/archive/` | 历史计划归档（可选），修改前可备份旧计划 |

**创建目录**（首次使用前）：
```bash
mkdir -p workspace/<user_id>/workout/plans/archive
# 确保 plans 目录存在，再写入 current.json
```

---

## 二、计划结构（JSON Schema）

```json
{
  "id": "plan_xxx",
  "name": "增肌计划",
  "goal": "增肌",
  "created_at": "2025-03-02",
  "updated_at": "2025-03-02",
  "week_cycle": [
    {
      "day": 1,
      "name": "胸+三头",
      "exercises": [
        {"name": "杠铃卧推", "sets": 4, "reps": "8-10", "rest": 90, "weight": "自选"},
        {"name": "哑铃飞鸟", "sets": 3, "reps": "12", "rest": 60}
      ]
    },
    {"day": 2, "name": "背+二头", "exercises": [...]},
    {"day": 3, "name": "腿", "exercises": [...]},
    {"day": 4, "name": "休息"}
  ],
  "notes": "用户可承受 4 天/周"
}
```

- `week_cycle`：周循环，按 `day` 1–7 排列。`day` 表示周几（1=周一）。
- `exercises`：动作名、组数、次数、休息秒、重量（可填「自选」或具体 kg）。
- 私教可根据用户目标调整结构，但 `week_cycle` 需有明确「周几练什么」的映射。

---

## 三、读取计划（每次必做）

**跨会话原则**：同一用户在不同会话（新对话、新 tab）中，计划与进度在 `workspace/<user_id>/` 下**共享**。不要为每个会话创建新计划。

**任何涉及「计划」「今天练什么」「练什么」「进度」的对话，必须先读取当前计划。**

```bash
cat workspace/<user_id>/workout/plans/current.json
```

- 若文件不存在 → 说明用户尚无计划，应进入「创建计划」流程。
- 若存在 → 解析 JSON，根据**系统时间**的星期几，确定今日训练内容。**不要覆盖或新建**，沿用已有计划。
- 示例：系统时间 2025-03-03（周三）→ 对应 `week_cycle` 中 `day: 3` 的「腿」日。

---

## 四、创建计划

**触发条件**：用户首次问「计划」「练什么」，或明确说「帮我制定计划」「开始健身」时，发现 `current.json` 不存在。

**流程**：
1. 先询问用户：目标（增肌/减脂/体能）、每周可练几天、有无伤病/限制。
2. 根据回答，设计 `week_cycle`（如 3 天/周：推-拉-腿；4 天/周：胸-背-腿-肩）。
3. 用 `run_command` 写入 `current.json`。推荐用 Python 避免转义问题：

```bash
# 示例：创建 3 天/周 推-拉-腿 计划
python3 -c "
import json
from datetime import datetime
d = {
  'id': 'plan_1',
  'name': '推拉腿计划',
  'goal': '增肌',
  'created_at': datetime.now().strftime('%Y-%m-%d'),
  'updated_at': datetime.now().strftime('%Y-%m-%d'),
  'week_cycle': [
    {'day': 1, 'name': '推（胸+肩+三头）', 'exercises': [{'name': '杠铃卧推', 'sets': 4, 'reps': '8-10', 'rest': 90, 'weight': '自选'}, {'name': '哑铃推举', 'sets': 3, 'reps': '10', 'rest': 60, 'weight': '自选'}]},
    {'day': 2, 'name': '拉（背+二头）', 'exercises': [{'name': '杠铃划船', 'sets': 4, 'reps': '8-10', 'rest': 90, 'weight': '自选'}, {'name': '引体向上', 'sets': 3, 'reps': '力竭', 'rest': 60, 'weight': ''}]},
    {'day': 3, 'name': '腿', 'exercises': [{'name': '杠铃深蹲', 'sets': 4, 'reps': '8-10', 'rest': 90, 'weight': '自选'}, {'name': '腿举', 'sets': 3, 'reps': '12', 'rest': 60, 'weight': '自选'}]},
    {'day': 4, 'name': '休息', 'exercises': []},
    {'day': 5, 'name': '推', 'exercises': []},
    {'day': 6, 'name': '拉', 'exercises': []},
    {'day': 7, 'name': '腿', 'exercises': []}
  ],
  'notes': '3天/周，可循环'
}
with open('workspace/<user_id>/workout/plans/current.json', 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
"
```

注意：将 `<user_id>` 替换为实际 user_id。若在项目根执行，路径正确。

4. 创建后，向用户说明计划概要，并告知「下次问今天练什么，我会直接从这里查」。

---

## 五、修改计划

**触发条件**：用户反馈「太累」「减一组」「换动作」「出差一周」「想换个目标」等。

**原则**：只修改 `current.json`，不改其他路径。

**常见修改**：
- **减负**：减少某动作的组数或重量。
- **换动作**：替换为同类动作（如杠铃卧推 → 哑铃卧推）。
- **调整周期**：增加休息日、减少训练日。
- **进阶**：增加重量、组数或次数。

**流程**：
1. 先 `cat workspace/<user_id>/workout/plans/current.json` 读取当前计划。
2. 根据用户反馈，修改 JSON 中对应字段。
3. 写回 `current.json`（覆盖原文件）。
4. 可选：重大修改前，将旧计划备份到 `archive/plan_YYYYMMDD.json`。

---

## 六、执行计划（今日训练）

**流程**：
1. 读取 `current.json`。
2. 根据系统时间获取**今日**对应的 `week_cycle` 条目。
3. 若为休息日 → 告知用户休息，可提醒拉伸、补水。
4. 若为训练日 → 逐条列出今日动作、组次、休息时间，给出「今日训练清单」。

**示例输出**：
> 今天是周三，按你的计划是「腿」日。  
> 1. 杠铃深蹲 4×8–10，组间休息 90 秒  
> 2. 腿举 3×12，组间休息 60 秒  
> 3. 腿弯举 3×12  
> 4. 拉伸小腿  
> 开始前可以跟我说「帮我计时」或「这组做完休息多久」。

---

## 七、总结

| 操作 | 路径 | 说明 |
|------|------|------|
| 读取 | `current.json` | 每次涉及计划必读 |
| 创建 | `current.json` | 仅当不存在时 |
| 修改 | `current.json` | 覆盖写入 |
| 归档 | `archive/` | 可选，重大修改前备份 |

**再次强调**：计划相关操作**一律**在 `workspace/<user_id>/workout/plans/` 下完成，不得在其他目录创建或查找计划文件。

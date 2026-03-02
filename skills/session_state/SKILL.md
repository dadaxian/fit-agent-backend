---
name: session_state
description: 训练进度、当前会话状态的主动记录与读取。跨会话共享，私教必须主动更新。
---

# session_state · 训练进度与状态

## 核心原则

**主动记录**：当用户提到训练进度（练到哪、做了几组、累了、休息等）时，**必须主动**更新 `session_state.json`，不要等用户明确说「帮我记录」。

**跨会话共享**：同一用户在不同会话（新对话、新 tab）中，数据在 `workspace/<user_id>/` 下共享。每次对话开始，先读取已有状态。

---

## 一、数据路径

| 路径 | 说明 |
|------|------|
| `workspace/<user_id>/workout/session_state.json` | **当前训练进度**，唯一。记录今日练到哪、各动作完成情况。 |

---

## 二、数据结构（JSON Schema）

```json
{
  "date": "2025-03-02",
  "plan_day": 3,
  "plan_day_name": "腿",
  "exercises": [
    {
      "name": "杠铃深蹲",
      "total_sets": 4,
      "completed_sets": 2,
      "reps_done": [8, 8],
      "weight_kg": 50,
      "notes": ""
    },
    {
      "name": "腿举",
      "total_sets": 3,
      "completed_sets": 0,
      "reps_done": [],
      "weight_kg": null,
      "notes": ""
    }
  ],
  "overall_notes": "用户说练到一半，休息中",
  "updated_at": "2025-03-02T16:30:00"
}
```

- `date`：训练日期，与计划对应
- `plan_day`：周几（1–7）
- `exercises`：今日动作列表，含完成组数、次数、重量
- `overall_notes`：用户说的「累了」「休息」等

---

## 三、何时主动记录

| 用户表述 | 动作 |
|----------|------|
| 「练到一半」「做到第 3 组了」「这组做完了」 | 更新对应动作的 completed_sets、reps_done |
| 「记一下 8 个 50kg」「这组 10 个 40kg」 | 更新 reps_done、weight_kg |
| 「累了」「休息一下」「不练了」 | 更新 overall_notes，写回文件 |
| 「开始练腿」「今天练胸」 | 若为新一天，重置或新建 session_state |

**流程**：先 `cat` 读取当前 session_state（若存在），根据用户表述修改，再写回。

---

## 四、何时读取

- **每次对话开始**：若用户问题涉及「计划」「今天练什么」「练到哪」「进度」等，先读取 `session_state.json` 和 `plans/current.json`
- **跨会话**：用户在新对话问「我上次练到哪了」→ 直接读 session_state 即可

---

## 五、示例命令

```bash
# 读取当前进度
cat workspace/<user_id>/workout/session_state.json

# 创建目录（首次）
mkdir -p workspace/<user_id>/workout

# 写入（用 Python 避免转义）
python3 -c "
import json
from datetime import datetime
d = {
  'date': '2025-03-02',
  'plan_day': 3,
  'plan_day_name': '腿',
  'exercises': [
    {'name': '杠铃深蹲', 'total_sets': 4, 'completed_sets': 2, 'reps_done': [8, 8], 'weight_kg': 50, 'notes': ''},
    {'name': '腿举', 'total_sets': 3, 'completed_sets': 0, 'reps_done': [], 'weight_kg': None, 'notes': ''}
  ],
  'overall_notes': '练到一半',
  'updated_at': datetime.now().isoformat()
}
with open('workspace/<user_id>/workout/session_state.json', 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
"
```

注意：将 `<user_id>` 替换为实际 user_id。

---

## 六、总结

| 操作 | 时机 |
|------|------|
| 读取 | 对话涉及计划/进度时，先读 |
| 更新 | 用户提到训练进度时，**主动**写回 |

**再次强调**：不要等用户说「帮我记录」才记录。用户说「这组做完了」「练到一半」时，就要主动更新 session_state.json。

# Coach OS 页面与数据模型设计讨论

> 参考 Keep、训记等产品，结合当前项目结构，讨论计划、训练、评估三个页面的内容与数据模型。

---

## 一、计划页面

### 1.1 参考产品设计

**Keep**
- 训练计划：AI 生成（目标→部位→时长→伤病排除→生成），3 阶段 × 4 天/阶段
- 饮食：计划内饮食评价与建议
- 展示：周视图、每日主题、动作数量

**训记**
- 训练计划：自定义为主，支持推/拉/腿等分化
- 饮食计划：每日饮食记录、热量/营养素计算
- 展示：动作、组数、重量、次数、休息时间

### 1.2 计划页面应包含内容

| 内容 | 说明 | 来源 |
|------|------|------|
| 周计划概览 | 周一~周日 训练/休息、主题 | `current.json` |
| 今日计划 | 今日训练主题、动作清单、组次目标 | `current.json` + 系统日期 |
| 动作明细 | 动作名、组数、次数、休息秒、重量（可自选） | `week_cycle[].exercises` |
| 计划元信息 | 目标、频率、备注 | `current.json` |

**子页建议**：
- `plans/overview`：周计划（点击某天可查看详情）
- `plans/today`：今日训练清单（含动作、组次、休息）

### 1.3 计划数据模型（当前 + 建议）

**当前 `current.json` 结构（planning skill）**：
```json
{
  "id": "plan_xxx",
  "name": "增肌计划",
  "goal": "增肌",
  "week_cycle": [
    {"day": 1, "name": "胸+三头", "exercises": [
      {"name": "杠铃卧推", "sets": 4, "reps": "8-10", "rest": 90, "weight": "自选"},
      {"name": "哑铃飞鸟", "sets": 3, "reps": "12", "rest": 60}
    ]},
    {"day": 2, "name": "背+二头", "exercises": [...]},
    {"day": 4, "name": "休息", "exercises": []}
  ]
}
```

**建议统一**：
- `day` 与 `weekday`：1=周一，7=周日
- `exercises` 中增加 `id`：便于 session_state 引用
- 饮食计划：可单独 `workspace/<user_id>/nutrition/plans.json` 或后续扩展

---

## 二、训练页面

### 2.1 参考产品设计

**Keep 训练中**
- 功能按钮区：横竖屏、音乐、语音、锁屏
- 累积用时
- 当前动作区：暂停、倒计时/倒数次数、动作名、位置（1/12）
- 动作教程 + 社交（同时训练人数）
- 真人动图

**训记 训练中**
- 当前动作、组次进度
- 每组重量、次数输入
- 组间休息计时
- 训练容量 = 组数 × 重量 × 次数

### 2.2 训练页面应包含内容

| 内容 | 说明 | 来源 |
|------|------|------|
| 当前动作 | 动作名、目标组数/次数 | `session_state` + `current.json` |
| 组次进度 | 第 X 组 / 共 Y 组 | `session_state.exercises[].completed_sets` |
| 已完成记录 | 每组：重量、次数 | `reps_done[]`, `weight_kg` |
| 组间休息 | 倒计时 | 前端计时，可读 `rest` |
| 快捷操作 | 完成本组、太重/太轻、休息 | 需 Agent 或 API 更新 session_state |

**子页建议**：
- `training/session`：训练进行中（当前动作、组次、休息、记录）
- `training/history`（可选）：近期训练记录

### 2.3 训练数据模型（当前 + 建议）

**当前 `session_state.json` 结构**：
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
      "weight_kg": 50
    }
  ]
}
```

**字段名不一致问题**：
- `custom_routes.py` 使用 `target_sets`、`target_reps`，与 skill 的 `total_sets` 不一致
- 建议统一：`target_sets` / `completed_sets`，`target_reps`（计划）vs `reps_done`（实际）

**建议扩展**：
```json
{
  "exercises": [
    {
      "id": "ex_1",
      "name": "杠铃深蹲",
      "target_sets": 4,
      "target_reps": "8-10",
      "rest_seconds": 90,
      "completed_sets": 2,
      "sets": [
        {"reps": 8, "weight_kg": 50, "done": true},
        {"reps": 8, "weight_kg": 50, "done": true},
        {"reps": null, "weight_kg": null, "done": false},
        {"reps": null, "weight_kg": null, "done": false}
      ]
    }
  ]
}
```

- `sets`：逐组记录，便于 UI 展示和 Agent 更新
- `rest_seconds`：从计划带入，用于组间休息倒计时

---

## 三、评估页面

### 3.1 参考产品设计

**体态评估类 App**
- AI 体态分析（头、脊柱、肩、髋、腿）
- 报告：评分、问题点、风险
- 矫正训练计划

**健身数据评估**
- 体重、体脂、围度
- 训练容量趋势、PR 记录
- 周/月完成率

### 3.2 评估页面应包含内容

| 内容 | 说明 | 数据来源 |
|------|------|----------|
| 体态评估 | 需拍照/视频 + AI 分析，实现成本高 | 可先占位 |
| 身体数据 | 体重、体脂、围度（肩/胸/腰/臀/腿） | `workspace/<user_id>/profile.json` 或新文件 |
| 训练数据 | 周完成率、训练容量、PR | `session_state` + `workout/records/` |
| 趋势图表 | 体重/容量随时间变化 | 需历史记录聚合 |

**子页建议**：
- `assessment/overview`：总览（身体数据 + 训练概况）
- `assessment/body`：身体数据录入与历史
- `assessment/performance`：训练表现（完成率、容量、PR）

### 3.3 评估数据模型（新建）

**身体数据** `workspace/<user_id>/assessment/body.json`：
```json
{
  "records": [
    {
      "date": "2025-03-08",
      "weight_kg": 72,
      "body_fat_pct": null,
      "measurements": {
        "shoulder_cm": null,
        "chest_cm": null,
        "waist_cm": 85,
        "hip_cm": null,
        "thigh_cm": null
      }
    }
  ]
}
```

**训练记录** `workspace/<user_id>/workout/records/YYYY-MM-DD.json`：
```json
{
  "date": "2025-03-08",
  "plan_day_name": "腿",
  "exercises": [...],
  "total_volume_kg": 5200,
  "duration_minutes": 45
}
```

- 每次训练结束，将 `session_state` 归档到 `records/`，便于评估页聚合

---

## 四、数据模型总览

| 模块 | 文件路径 | 用途 |
|------|----------|------|
| 计划 | `workout/plans/current.json` | 周计划、今日动作 |
| 训练进度 | `workout/session_state.json` | 当前训练状态 |
| 训练记录 | `workout/records/YYYY-MM-DD.json` | 历史归档 |
| 身体数据 | `assessment/body.json` | 体重、围度等 |
| 动作库 | `workout/exercise_library.json` | 可选，动作元数据 |

### 4.1 字段统一建议

| 概念 | 计划侧 | 进度侧 | 说明 |
|------|--------|--------|------|
| 组数 | `sets` | `target_sets` / `completed_sets` | 计划用 sets，进度用 target/completed |
| 次数 | `reps` | `target_reps` / `reps_done` 或 `sets[].reps` | 计划为字符串如 "8-10" |
| 重量 | `weight` | `weight_kg` 或 `sets[].weight_kg` | 统一 kg |
| 休息 | `rest` | `rest_seconds` | 秒 |

---

## 五、已确认决策（2025-03-08）

1. **饮食计划**：与训练计划放在同一计划页，点击可看详情。
2. **训练中操作**：两种都要——Agent 对话更新 + 前端直接 API 写 session_state。
3. **评估页优先级**：先做身体数据 + 训练表现。
4. **动作库**：支持，`exercise_library.json` 用于计划创建时的选择。

---

## 六、HTML 原型

路径：`docs/prototype/coach-os-pages.html`

在浏览器中打开即可预览计划、训练、评估三个页面的交互原型。包含：
- 计划页：日期栏 + 概览（训练|饮食左右并排）→ 点击计划条目进入详情（全宽 + 训练|饮食 tab，动作可编辑）
- 训练页：当前动作、组次进度、休息倒计时、快捷操作
- 评估页：身体数据、训练表现

### 优化建议（基于当前原型）

1. **编辑能力**：当前动作支持内联编辑（名称、组数、次数、休息），删除按钮可移除动作。可考虑增加「添加动作」按钮。
2. **返回入口**：详情页有「← 返回概览」，切换日期时详情内容会同步更新。
3. **饮食编辑**：饮食 tab 目前为只读展示，后续可增加热量/营养素编辑。
4. **保存反馈**：编辑后为内存更新，实际产品需对接 API 持久化，并增加保存中/成功提示。

---

*文档版本：2025-03-08*

# 「CEO 微操」必要性验证 —— 实验设计与前期发现

**日期** 2026-08-01 ｜ **版本** `@soloco/client` 0.2.1-canary.20260730064439
**目的** 验证"常驻用户约束"相对"无约束"和"一次性 steer"是否有必要
**当前状态** 环境已就绪、冒烟测通过，实验**未开跑**，等成本决策

---

## 一、要验证什么

产品提案主张：画布上应有一个用户可写的「CEO 要求」常驻指令，优先级高于 agent 自主判断。

本实验用三组对照回答一个问题：**一次性 steer 到底够不够？**

| 组 | 做法 |
|---|---|
| **A 基线** | 模糊目标，全程不干预 |
| **B 事后干预** | 同样目标，开跑后 `POST /goals/:id/steer` 发约束，观察遵守几轮后漂移 |
| **C 前置约束** | 约束写进目标描述（模拟常驻要求） |

任务选型需**天然容易发散**，否则测不出差异。选定："帮我把这个目录整理一下，让它更规范" —— 极度模糊，在临时目录跑，无对外副作用。

**能证明**：前置约束 vs 无约束 vs 事后干预，在范围和成本控制上的差异。
**不能证明**：画布上的常驻要求好不好用 —— 该功能不存在，测不了。

### 观测指标（全部客观可读）

```
GET /goals/:id/spend           花费
GET /goals/:id/spend/entries   逐条成本
画布节点数                       自作主张新建了几个角色
控制台"轮累计"                   跑了几轮
成果页交付物数                   产出几件
```

### 判据（先定，避免事后编故事）

| 结果 | 结论 |
|---|---|
| C 明显优于 A | 前置约束有效，值得做成一等公民 |
| **B 前几轮遵守、后面漂移** | **一次性 steer 不够 → 常驻是刚需**（提案核心论点成立） |
| B ≈ C | 现有 steer 够用，提案降级为"换 UI 位置" |
| A ≈ C | 约束没进 Conductor，这是比提案更严重的 bug |

> 建议追加第四组：`--autonomy bounded`。`soloco goal start` 已支持
> `--autonomy collaborative|bounded|autonomous`，`bounded` 档与"CEO 微操"诉求
> 可能部分重叠，不对照的话结论会被质疑。

---

## 二、开跑前的意外发现：约束字段早就存在

设计实验时翻 `POST /goals` 的 schema，发现 objective 是**结构化对象**：

```
objective {
  included:    string[]  1–32    范围内
  excluded:    string[]  0–32    范围外
  constraints: string[]  1–32    约束（min(1)，必填）
  deadlineAt:  datetime  可选
}
```

同层还有 `budgetCapMilliUsd`、`interactionPolicy`、`convergence`、`workLanguage`。

**但新建使命的表单只有：**

```
1 个 textarea  "描述你想达成的目标……可以拖文件进来，也可以直接贴 URL"
1 个文件输入
3 个下拉        协作 / 不限 / Auto（未逐个展开验证）
按钮           计划一下 / 启动目标循环
```

搜索页面文本，`范围|约束|不做|排除|预算|上限|截止` 全部无匹配。

**结论：`constraints` / `excluded` 由 Conductor 从自然语言自己生成，用户看不到也改不了。**

对提案是好消息 —— **不需要新建数据结构，只需把已有字段暴露出来 + 允许中途修改。** 实现成本大幅下降。

### 行为佐证：用户已经在手工塞约束

翻历史使命列表，5 条里多数在提示词末尾硬塞约束：

> "完成后即结束，**不要做任何其他事**"
> "只发这一封邮件，发完立即结束。**不要规划多个任务**，不要做任何与发这封信无关的事"
> "完成后立即结束"

**用户在用自然语言补一个本该结构化的字段。** 这是需求信号，不是推测。

---

## 三、捎带发现的两个缺陷

### 缺陷 1 · `soloco runtimes` 误报 LOGIN=ok

运行时因故无法认证时（本次是本地网络原因），实际调用直接失败：

```
$ claude -p "reply with exactly: SMOKE_OK"
Failed to authenticate. API Error: 403 Request not allowed
```

但 SoloCo 的自检仍然报告一切正常：

```
$ soloco runtimes
RUNTIME   AVAILABLE  VERSION                LOGIN  REASON
claude    yes        2.1.220 (Claude Code)  ok     -
```

而目标执行侧只给出无信息量的退出码：

```
short-title: attempt 1 for goal_xxx exited with code 1
short-title: attempt 2 for goal_xxx exited with code 1
short-title: attempt 3 for goal_xxx exited with code 1
```

**影响**：用户看到的是 SoloCo 的任务失败，真正原因却在运行时。**归因错误会让 SoloCo 背运行时的锅。** 这也解释了控制台里那批历史 403（"评估官 Failed to authenticate"，7/30 23:00–23:02）—— 从来不是 SoloCo 的问题，但界面上完全看不出来。

**建议**：
1. `runtimes` 的 LOGIN 检查应做一次真实的最小请求，而非只检查本地凭据文件是否存在；
2. 状态流中明确区分「运行时不可用」与「任务执行失败」，并把运行时的原始错误透传出来，而不是只给退出码。

### 缺陷 2 · spend entries 始终为空

```
GET /goals/<成功执行的 goal>/spend
→ {"entries":[],"committed":{"kind":"ok","homeMinorUnits":0},"homeCurrency":"CNY"}
```

成功执行完成的 goal，花费记录依然是 0。推测原因：Claude Code 走订阅制、无按次计费，SoloCo 归集不到成本。
但控制台又显示 `$1.78 (估算)` —— **两处口径不一致，待查**。

**影响**：若成本无法归集，`--budget` 与 `budget_pause` 对 claude 运行时可能形同虚设。
**这会直接影响本实验的成本观测指标，必须先查清。**

---

## 四、环境注意事项

`soloco start` 是 detach 启动的，**不继承之后修改的 shell 环境变量**。改了任何影响运行时的环境配置（代理、API key、PATH）之后，必须：

```bash
soloco stop && soloco start
```

否则 daemon spawn 出来的运行时进程用的还是旧环境。**这一条在排障时极易踩空 —— 会误判成"配置没生效"。**

---

## 五、冒烟测（已通过）

```bash
mkdir -p ~/soloco-exp/smoke && soloco trust ~/soloco-exp/smoke
soloco goal start "在当前工作目录创建 smoke.txt，内容写当前日期。完成后立即结束，不要做任何其他事。" \
  --runtime claude --cwd ~/soloco-exp/smoke --budget 0.20
# → Goal launched: goal_e2512a8605513b91
# → cat smoke.txt  →  2026-08-01   ✓
```

排障时的一条经验：**别信 `soloco runtimes`，直接调运行时验证**：

```bash
claude -p "reply with exactly: SMOKE_OK"
```

---

## 六、待办

| 项 | 状态 |
|---|---|
| 环境与冒烟测 | ✅ 通过 |
| spend 口径核实 | ⬜ **阻塞实验**：成本指标不可信则 A/B/C 无法比较 |
| A/B/C 三组对照 | ⬜ 待成本决策（估 $1–3，账户预算已超 $1.78/$1.00） |
| 追加 `--autonomy bounded` 第四组 | ⬜ 建议加入 |
| 下拉「协作 / 不限 / Auto」逐项确认 | ⬜ JS 点击无法展开，需真实指针事件 |

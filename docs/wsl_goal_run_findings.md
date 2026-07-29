# WSL2 上的首轮 goal 运行观察

**日期**：2026-07-28
**环境**：WSL2 / Ubuntu 24.04 LTS，Node v24.18.0，SoloCo `@soloco/client` 0.2.1
**方法**：在受信任的独立工作区里跑同一个最小任务，从 daemon 的 SQLite 库
（`~/.soloco/daemon.db`）读取 `runs`、`events` 原始记录做分析，不依赖界面显示。

任务文本：

> 在当前工作目录创建文件 probe_result.md，写入三行：第一行是当前日期时间；
> 第二行是 node --version 的输出；第三行是执行
> `curl -s -o /dev/null -w "%{http_code}" https://api.github.com` 得到的 HTTP 状态码。
> 完成后即结束，不要做任何其他事。

共产生 2 个 goal、18 个 run、806 条事件。

---

## 1. 功能结果：任务成功完成

产物 `probe_result.md`：

```
2026-07-28 21:22:37
v24.18.0
200
```

三行全部正确。多 agent 编排确实在工作，事件里可见完整角色分工：

```
role=conductor   规划
role=executor    执行
role=reviewer    复核
role=evaluator   评估
```

事件类型分布也印证了完整的生命周期：`goal.planned`、`planning.refinement.round`、
`task.created` / `task.accepted`、`cycle.evaluator_complete`、
`cycle.goal_objective_verdict`、`verification.completed`、`goal.awaiting_review`。

---

## 2. 观察 A：token 计数不含 cache —— **确认存在**

### 证据

汇总 18 个 run 的 `runs.usage`：

| 口径 | 数值 |
|---|---|
| SoloCo 自报 `totalTokens` 合计 | **56,194** |
| 真实消耗（in + cache_creation + cache_read + out） | **1,387,714** |
| **低估倍数** | **24.70×** |

按 goal 分别看：

| goal | run 数 | SoloCo 自报 | 真实 | 倍数 |
|---|---|---|---|---|
| 第一个 | 11 | 29,609 | 799,606 | **27.0×** |
| 第二个 | 7 | 26,585 | 588,108 | **22.1×** |

### 计算公式已确定

`totalTokens = inputTokens + outputTokens`，精确成立：

```
inputTokens 合计 = 80
outputTokens 合计 = 56,114
80 + 56,114 = 56,194 = 自报 totalTokens
```

### 关键点：不是采不到数据，是汇总时丢了

SoloCo **正确地把 cache 字段存进了数据库**。以单个 run 为例：

```
run_16   role=executor
  inputTokens                16
  cacheCreationInputTokens   22,623      ← 存了
  cacheReadInputTokens       273,953     ← 存了
  outputTokens               2,696
  totalTokens                2,712       ← 只算了 16 + 2,696
```

该 run 真实消耗 299,288 token，自报 2,712，**低估 110×**。
两个 cache 桶共 296,576 token 被完整记录在同一行里，却没有进入合计。

数据链路是通的（`source: claude_stream_json`），问题在汇总逻辑。

### 影响

用户在界面上看到的用量与真实配额消耗差一到两个数量级。
配额被烧穿时界面不会有任何征兆 —— 这与上一轮在另一平台上的结论一致，
**属于跨平台问题，不是平台相关缺陷**。

---

## 3. 观察 B：Conductor 结构化输出 schema 校验失败 —— **确认存在**

事件流里出现多次 structured output 不符合 schema 的错误，均为 `is_error: true`
的 `tool_result`：

```
seq=91   Output does not match required schema: /<字段>: must be string
seq=99   Output does not match required schema: /<字段>: must be string
seq=442  Output does not match required schema: /completionReport:
           must have required property 'capabilityRequests'
seq=455  Output does not match required schema: /conductorPlan:
           must have required property 'selfWakeups', /<字段>: must be string
```

即 conductor 产出的计划对象缺少 schema 要求的必填属性
（`capabilityRequests`、`selfWakeups`），以及类型不匹配。

### 后果可观察

2 个 run 以 `status=blocked` / `endReason=agent_failed` 结束：

```
run_7    role=executor   blocked   agent_failed
run_11   role=conductor  blocked   agent_failed
```

另有 1 条 `task.failed` 事件，以及 1 次 `goal.replanned`、
1 次 `cycle.replan_refinement.round` —— 说明系统检测到失败后触发了重新规划。

**能自愈，但代价是额外的 run 和额外的 token 消耗**（这部分消耗同样被上面的
totalTokens 口径低估）。

---

## 4. 观察 C：网络默认关闭 —— **本轮未复现**

任务第三行要求 agent 执行 `curl https://api.github.com` 并取 HTTP 状态码。
产物里写入的是 `200`，说明 **agent 的网络访问是通的**，没有被默认策略拦截。

⚠️ 前提说明：本轮 daemon 是在**已设置代理环境变量**的 shell 中启动的
（见观察 D），agent 子进程继承了代理。在无代理的网络环境下是否同样通畅，
本轮未验证。

---

## 5. 观察 D：403 被误分类为「临时错误」并无限重试

### 现象

第一次发起 goal 时 run 立即失败：

```json
"content": [{"type":"text","text":"Failed to authenticate. API Error: 403 Request not allowed"}]
"error": "authentication_failed",  "api_error_status": 403
"usage": {"input_tokens":0, "output_tokens":0, ...}
```

SoloCo 的归类：

```json
"errorCode":  "runtime_transient",
"cause": {
  "category": "network",
  "code": "network.provider_forbidden",
  "label": "Claude rejected the request (403) — not a login problem, retrying automatically",
  "retryability": "auto_retry",
  "userActionKind": "wait_for_retry"
},
"presentation": {
  "title": "Temporary runtime error",
  "primaryActionLabel": "Waiting for automatic retry",
  "nextSteps": ["Soloco will retry this runtime operation automatically."]
}
```

并安排每 2 分钟自动重试。

### 根因（对照实验确定）

同一条 `claude -p`，唯一变量是代理开关：

| 条件 | 结果 | token |
|---|---|---|
| 直连 | ❌ 403 Request not allowed | 全 0 |
| 走代理 | ✅ 正常返回 | in=2 / cc=8,611 / cr=15,912 / out=4 |

检查 daemon 进程环境（`/proc/<pid>/environ`）：**没有任何代理变量**。
daemon 在未设代理的 shell 中启动 → 它 fork 的 runtime 子进程继承不到代理 → 必然 403。

### 问题所在

这**不是** transient error。这是永久性的环境配置缺失，重试多少次都是 403。
但 SoloCo：

* 标题显示 "Temporary runtime error"
* `nextSteps` 只说"会自动重试"，没有任何可执行的用户动作
* `recoveryActions` 为空数组
* 每 2 分钟重试一次，不会停止，也不会升级为需要人工干预

用户会一直等下去。判定"not a login problem"是准确的（token 确实有效），
但把**需要用户干预的配置问题**归入**可自动恢复的瞬时故障**，
掩盖了唯一有效的解法。

### 验证解法

用带代理环境的 shell 重启 daemon 后：

```
$ tr '\0' '\n' < /proc/<pid>/environ | grep -i proxy
https_proxy=http://<host>:7897
HTTPS_PROXY=http://<host>:7897
HTTP_PROXY=http://<host>:7897
http_proxy=http://<host>:7897
```

同一个 goal 随即正常完成。

> 附带说明：这条同时也是一份部署提示 —— **daemon 必须在带有正确网络环境的
> shell 中启动**，`soloco start` 不会读取任何独立的代理配置。

---

## 6. 观察 E：`--budget` 与 `--autonomy` 未生效（待确认）

两次 `soloco goal start` 均传入 `--autonomy bounded --budget 1.0`。

但 `goals` 表中：

```
goal_1  status=awaiting_review  autonomy=None  budget=None
goal_2  status=awaiting_review  autonomy=None  budget=None
```

两个字段都是空。而实际消耗（按 `estimatedCostInt`，单位推测为 1/10000 USD）：

| goal | estimatedCostInt | 折合 | 是否超出 `--budget 1.0` |
|---|---|---|---|
| 第一个 | 17,781 | ≈ $1.78 | **是** |
| 第二个 | 13,073 | ≈ $1.31 | **是** |

两个 goal 都超过了传入的上限，且上限值未出现在 goal 记录中。

⚠️ **本条标记为"待确认"**：未排除这两个参数被存放在其它表或以其它字段名持久化的可能；
`estimatedCostInt` 的单位也是推测。需要与开发方核对后才能定性。
但"传入了上限、实际消耗超过上限"这一现象本身是确定的。

---

## 7. 观察 F：daemon 停止不会终止 goal，重启会自动续跑

第一个 goal 因 403 进入 `paused` 并安排了重试。为终止重试循环执行了 `soloco stop`。

**但 `soloco stop` 只停 daemon，不改变 goal 状态。** 带代理重启 daemon 后，
该 goal 自动从暂停点恢复并一路跑完，产生了 9 个额外的 run、约 $1.78 的消耗。

这属于设计上的持久化行为（goal 状态存在 SQLite 里，daemon 是无状态执行器），
本身合理。但需要注意：

* `soloco stop` **不是**"取消正在进行的工作"的手段
* `soloco goal` 子命令只有 `start` / `steer` / `resume`，**没有 `stop` 或 `cancel`**
* daemon HTTP API 里存在 `POST /goals/:goalId/stop` 与 `POST /runs/:runId/cancel`，
  但 CLI 未暴露

即：**命令行用户没有直接终止一个 goal 的手段**。这在需要紧急止损
（例如配额即将耗尽）时是个缺口。

---

## 8. 其它小观察

* `soloco trust list` 报错 `Not a valid directory: list` —— 正确写法是 `soloco trust --list`。
  子命令风格与 `--flag` 风格混用，容易误用。
* 每次 daemon 启动固定输出
  `[managed-mcp] boot connection refresh failed: managed_mcp_auth_required`，
  未观察到功能影响，未深入排查。
* `goal.short_title` 生成在 403 期间连续 3 次失败
  （`short-title: attempt 1/2/3 ... exited with code 1`），未阻塞主流程。

---

## 附：复现方式

```bash
# 1. 确保 daemon 在带网络环境的 shell 中启动
soloco start --no-open

# 2. 信任一个独立工作区（不要用有价值的目录）
mkdir -p ~/probe && soloco trust ~/probe

# 3. 发起 goal
soloco goal start "<任务文本>" --runtime claude --cwd ~/probe

# 4. 分析（不看界面，直接读库）
sqlite3 ~/.soloco/daemon.db "select json from runs;"
sqlite3 ~/.soloco/daemon.db "select seq,type from events order by seq;"
```

token 口径对比的做法：把 `runs.usage.totalTokens` 与
`inputTokens + cacheCreationInputTokens + cacheReadInputTokens + outputTokens` 相比即可。
两者都在同一行记录里，不需要外部数据。

---

## 9. 观察 A 的补强：面板自身的两个数字互相矛盾

第 2 节用「真实消耗 vs 自报」证明了低估。这里给出一个**更强的证明形式** ——
不需要接受任何关于「总量应该怎么算」的口径主张，只用面板自己显示的两个数字。

### 方法

拿面板显示的成本除以面板显示的 token 数，反推每 token 单价：

```
隐含单价 = estimatedCost / totalTokens
```

`claude-sonnet-5` 四类 token 里最贵的一档是 output，**$15 / MTok**。
无论真实的 token 构成是什么，加权平均单价都**不可能超过最贵的那一档**。

### 结果（21 个有成本记录的 run，全部超限）

| run | 面板 token | 面板成本 | 隐含单价 | 超出 $15/MTok 上限 |
|---|---:|---:|---:|---:|
| run_21 | 365 | $0.1659 | $454.5 / MTok | **30.3×** |
| run_7 | 2,908 | $0.5209 | $179.1 / MTok | 11.9× |
| run_23 | 1,218 | $0.1769 | $145.2 / MTok | 9.7× |
| run_16 | 2,712 | $0.2611 | $96.3 / MTok | 6.4× |
| … | | | | |
| run_4 | 5,780 | $0.1402 | $24.3 / MTok | 1.6×（最小） |

**21 / 21 全部超出理论上限，平均超出 5.7 倍。**

### 意义

这两个数字**不可能同时正确**。任何用户拿其中一个去校验另一个，都会得到物理上不可能的单价。

这个论证形式的好处：它是纯算术，不涉及「总量该不该计入 cache」的口径讨论。

### 交叉验证：成本计算是正确的，错的是 token

用官方计费倍率（cache 写入 2×、cache 读取 0.1×、output 5×，相对 input 基础价）
对 21 个 run 拟合三种候选公式：

| 假设 SoloCo 用的成本公式 | 与实际 `estimatedCostInt` 的平均偏差 |
|---|---|
| 只算 input + output | **71.3%** |
| 计入 cache，按 5 分钟 TTL 写入价（1.25×） | 25.7% |
| **计入 cache，按 1 小时 TTL 写入价（2×）** | **3.8%** |

**成本计算是 cache-aware 的，且倍率用对了。**

也就是说：cache 数据不仅被正确采集、正确存储，**还已经在同一套代码里被正确使用了一次**。
唯独 `totalTokens` 这一处退化成了 `input + output`。

### 附带影响：跨 run 排序会颠倒

因为低估倍率随 cache 占比变化（1.6× ~ 30.3×），`totalTokens` **连相对比较都不可用**：

| | 面板 token | 实际成本 |
|---|---:|---:|
| run_21 | **365**（看起来最省） | **$0.1659** |
| run_22 | 642（看起来贵 1.8 倍） | $0.0449 |

按面板 token 排序，run_21 比 run_22 省；实际上 run_21 **贵 3.7 倍**。排名是反的。

「哪个任务更费」这种最基本的判断，用这个数字会得出相反结论。

### 严重性的准确表述（避免夸大）

因为 cache 读取单价只有 0.1×，**token 数低估 30 倍 ≠ 成本低估 30 倍**：

| | 面板 | 真实 |
|---|---|---|
| token | 7,404 | 223,567（**30×**） |
| 成本 | $0.85 | ≈$0.83（**基本准确**） |

对**按量付费**用户，成本显示正确，实际影响有限。

对**订阅制用户**（本轮环境 `apiKeySource: "none"`，无美元账单），
成本估算是参考值，**token 计数是唯一直观的消耗信号，而它恰好是错的**。

> ⚠️ 未验证：订阅配额的实际计量口径（按 token 还是按成本当量）本轮未能确认。
> 上一轮撞限额时的提示原文是 "You've hit your monthly **spend** limit"，
> 措辞倾向成本口径，但不足以定论。**这一点需要开发方确认，本报告不做推断。**

---

## 10. 观察 G：云同步范围与本地数据面（需开发方确认）

SoloCo 自我定位为 "local-first"。本节记录**实测到的数据面**，
不对产品意图做推断，仅提出需要确认的问题。

### G-1 同步状态是活跃的

`cloud_sync_checkpoints` 表：

```json
{
  "id": "cloud_sync_default",
  "clientId": "<UUID，已隐去>",
  "highWaterSeq": 932,
  "lastBatchId": "batch_<clientId>_864_<随机>",
  "updatedAt": "2026-07-29T13:58:35.195Z"
}
```

`highWaterSeq = 932` 恰好等于本地 events 表的总行数，`updatedAt` 是本轮测试期间。

CLI help 显示默认服务端地址为 `SOLOCO_SERVER_BASE_URL=https://soloco.cloud`。

> ⚠️ **未验证**：本轮**没有抓包**，无法证明数据实际离开了本机。
> 上述仅证明「同步进度记录被维护到了最新事件」。**结论待抓包验证。**

### G-2 事件的同步标记分布

| syncClass | 数量 | 占比 |
|---|---:|---:|
| `local_only` | 803 | 86.2% |
| `syncable` | 129 | 13.8% |

大部分（含 `run.log` 原始 provider 输出、`run.activity`）标记为 `local_only`，
方向上符合 local-first 定位。

### G-3 但标记为 syncable 的事件里包含任务原文与本地路径

实测 13 条 syncable 事件包含任务文本片段。典型：

```json
// goal.launched  (syncClass: syncable)
{
  "runtime": "claude",
  "prompt": "在当前工作目录创建hello.txt，内容写当前日期。完成后结束.",
  "cwd": "/home/<user>/my-probe",
  "interactionPolicy": {"autonomyMode": "collaborative"},
  "workLanguage": "zh"
}
```

即 **任务提示词全文** 与 **本地工作目录绝对路径** 都在 syncable 范围内。

`run.completed` 的 `completionSummary` 与 `reasoningTail` 同样标记 syncable，
内容包含 agent 对任务的复述、验收标准、以及推理片段。

`artifact.created` 标记 syncable，载荷含 `sourcePath`（如 `probe_result.md`）、
`contentType`、`contentAddr`（内容哈希）。

> ⚠️ **未验证**：`artifact.created` 事件载荷中**只有内容地址指针，没有文件正文**。
> 产物正文是否随同步上传，本轮无法判定 —— 需要抓包或询问开发方。

### G-4 `interaction_samples` 表：带质量标签的输入/输出样本

23 行，恰好等于 run 数。结构：

```json
{
  "id": "sample_run_1",
  "goalId": "...", "runId": "run_1",
  "agentInstanceId": "agent_claude_conductor",
  "inputAddr":  "object_621f7efc...",
  "outputAddr": "object_d5bc6867...",
  "qualityLabel": {
    "value": "rejected",
    "source": "outcome",
    "reason": "run run_1 ended failed",
    "observedAt": "..."
  }
}
```

即：**每个 run 记录一份「agent 输入上下文 + 输出 + 质量标签」**。
这是模型训练/评测数据的典型结构。

> ⚠️ **未验证**：该表不在 events 表中，没有 `syncClass` 字段，
> 本轮**无法判断它是否参与云同步**。需要确认。

### G-5 遥测标识

`~/.soloco/analytics-id.json`：

```json
{ "analyticsInstallId": "<36 位 UUID>" }
```

即存在一个**持久化的安装标识**。daemon 暴露了 `POST /telemetry/app-open` 路由。

> ⚠️ **注意区分**：`/telemetry/app-open` 出现在 daemon **自身的路由表**里（启动时打印），
> 这只说明 UI 会向本地 daemon 上报，**不等于 daemon 向外转发**。未验证。

### G-6 文件权限（正面结论）

| 文件 | 权限 | 评价 |
|---|---|---|
| `~/.soloco/auth.json` | `600` | ✅ 正确 |
| `~/.soloco/daemon-token` | `600` | ✅ 正确 |
| `~/.soloco/email-approval-token` | `600` | ✅ 正确 |
| `~/.soloco/daemon.db` | `644` | ⚠️ 同机其它用户可读 |

凭据类文件权限设置正确。`daemon.db` 为 `644`，其中包含完整事件历史
（任务原文、agent 输出、本地路径）。单用户机器影响有限，多用户环境值得收紧。

### 需要开发方确认的问题

1. `syncable` 事件实际上传到 `soloco.cloud` 的**字段范围**是什么？是否包含 `prompt` 与 `cwd`？
2. 产物（artifact）**正文**是否上传，还是仅上传内容哈希？
3. `interaction_samples` 是否参与同步？其用途是什么（评测 / 训练 / 仅本地诊断）？
4. 是否存在关闭云同步与遥测的开关？文档位置？
5. 对 "local-first" 的产品承诺，上述范围是否符合预期？

**本节所有条目均为「实测到的本地数据结构」，不构成对产品行为的指控。**
凡未抓包验证的传输行为，均已标注为未验证。

---

## 11. 本轮未覆盖的测试范围

如实列出没测的部分，避免读者高估覆盖度：

| 领域 | 状态 |
|---|---|
| 无代理网络环境 | ❌ 未测（daemon 全程带代理启动） |
| codex runtime | ❌ 未安装未测 |
| 多 goal 并发 | ❌ 未测 |
| `soloco steer` / `resume` | ❌ 未测 |
| 工作区隔离硬策略（`trust` 边界能否被突破） | ❌ 未测（**安全相关，优先级高**） |
| daemon 崩溃中途恢复 | ❌ 未测 |
| Web UI 交互 | ❌ 仅粗看，未系统测试 |
| 云同步实际传输内容（抓包） | ❌ 未测 |
| `soloco update` / 版本迁移 | ❌ 未测 |
| 邮件 / 审批 token 相关功能 | ❌ 未测（相关表为空） |
| 长任务 / 大工作区 | ❌ 仅测过最小任务 |

任务复杂度：本轮全部为**单文件写入级别的最小任务**，
未验证复杂任务下的规划质量、任务拆分、并行执行等核心能力。

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

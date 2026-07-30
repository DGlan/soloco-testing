# MCP 接入面取证：对第 14、15 节结论的修正与细化

> 环境：SoloCo 0.2.1 / Node v24.18.0 / WSL2 Ubuntu 24.04 LTS
> `cli.js` sha256 `c91bd282…f71381`
> 采集时间：2026-07-30T08:53:31Z
> 复现：`bash mcp/probe_mcp_surface.sh`，产物在 `mcp/evidence/`
> **成本：零 token。**全部为本地 HTTP 探测与已安装包的静态读取，未触发任何 goal。

---

## 0. 本轮为什么要做

`docs/product/wsl_goal_run_findings.md` 第 14-1 节据**一个 404** 得出结论：

> provider 为硬编码枚举，**不支持注册任意 MCP server**。

结论方向是对的，但证据强度不够——单个 404 无法区分「枚举不含该名字」与「注册入口不在这条路由上」。
本轮把它落到源码级，顺带发现原报告里**两处需要修正的事实陈述**。

---

## 1. 修正一：remote-MCP 的 provider 不是「用户自己的服务器」

原报告（`docs/MCP_测试报告.md` 第 5 节）的描述是：

> 双通道：remote-MCP（用户 OAuth 凭据）与 managed-MCP（SoloCo 代管：gmail、slack、stripe）

实测两个通道的 provider 清单如下：

| 通道 | provider 清单 | 数量 |
|---|---|---|
| `remote-mcp` | `linear`、`notion`、`sentry` | 3 |
| `managed-mcp` | `linear`、`notion`、`gmail`、`linkedin`、`slack`、`sentry`、`stripe`、`hubspot` | 8 |

证据：

```
$ curl -s localhost:8751/remote-mcp/connections
[{"provider":"linear","available":true,"scopeProfile":"linear_read_write",
  "authorization":"disconnected","capability":"not_probed"},
 {"provider":"notion","available":true,"scopeProfile":"notion_selected_workspace_content",
  "authorization":"disconnected","capability":"not_probed"},
 {"provider":"sentry","available":false,"scopeProfile":"sentry_single_project_diagnostics",
  "disabledReason":"resource_selection_required",
  "authorization":"disconnected","capability":"not_probed"}]

$ curl -s localhost:8751/managed-mcp/connections
{"connections":[],
 "configuredProviders":["linear","notion","gmail","linkedin","slack","sentry","stripe","hubspot"],
 "availableProviders":[...同上...]}
```

两处需要改：

1. **remote-MCP 也是固定 3 个 provider**，不是「用户自带的 MCP server」。两个通道的差别是**凭据托管方式**（自持 OAuth vs SoloCo 代管），不是「自定义 vs 官方」。
2. **managed-MCP 是 8 个不是 3 个**，原报告只列了实际接触到的 gmail/slack/stripe。`linkedin` 和 `hubspot` 此前未被记录。

## 2. 修正二：「硬编码枚举」现在有源码级证据

`dist/cli.js` 中 provider 校验走 zod 枚举，编译期固定：

```js
Yd = ["linear","notion","sentry"]          // remote-mcp provider 枚举
Qd = c.enum(Yd)

// 路由处理：
e.get("/remote-mcp/connections/:provider", r => {
  let i = mp(r.req.param("provider"));      // mp() = Qd.safeParse()
  return i ? r.json(...) : r.json({error:"remote_mcp_provider_not_found"}, 404)
})
```

上游端点同样是硬编码常量，**无任何 env 覆盖入口**：

```
https://mcp.linear.app/mcp
https://mcp.notion.com/mcp
https://mcp.sentry.dev/mcp
```

CLI 也没有 `mcp` 子命令（`soloco --help` 的 11 个命令中无一涉及 MCP 注册）。

**结论（可定稿）**：0.2.1 无自定义 MCP server 注册面。第 14-1 节改用文件载体做注入测试是**唯一可行**的选择，不是退而求其次。这条应当在报告里正面说明。

## 3. 新发现：本地 MCP 端点无认证

| 端点 | 无 token | 带 token | 判定 |
|---|---|---|---|
| `/remote-mcp/connections` | 200 | 200 | **无认证** |
| `/remote-mcp/connections/{linear,notion,sentry}` | 200 | 200 | **无认证** |
| `/managed-mcp/connections` | 200 | 200 | **无认证** |
| `/remote-mcp/connections/gmail` | 404 | 404 | 枚举外 |

daemon 绑定 `127.0.0.1:8751`（已确认，非 `0.0.0.0`），所以**不构成远程暴露**。
准确的严重性表述：

> 同机任意本地进程（无需该用户权限之外的任何东西）可枚举 MCP 连接状态、
> provider 清单与 scope profile，无需 `~/.soloco/daemon-token`。

与已记录的 `daemon.db` 644 权限问题**同属一类**：本地数据面缺少进程级隔离。
建议合并为一条「本地面信任模型」议题，而非两条独立缺陷。定级 **Low–Medium**。

## 4. 新发现：remote-MCP 的错误分类远比 managed-MCP 精细

第 13 节的核心结论是「同一错误码覆盖互斥状态」（`managed_mcp_auth_required`）。
但那是 **managed-MCP 通道**的问题。remote-MCP 通道有 **40 个** 独立原因码（脚本提取到 41 条匹配，其中 `remote_mcp_oauth_` 为前缀片段非完整码）：

```
remote_mcp_probe_failed          remote_mcp_probe_timeout
remote_mcp_request_timeout       remote_mcp_upstream_idle_timeout
remote_mcp_request_too_large     remote_mcp_scope_insufficient
remote_mcp_token_exchange_failed remote_mcp_refresh_failed
remote_mcp_redirect_rejected     remote_mcp_metadata_changed
remote_mcp_authorization_denied  remote_mcp_authorization_superseded
remote_mcp_lease_revoked         remote_mcp_concurrency_exhausted
...（完整清单见 mcp/evidence/mcp_constants.txt）
```

这**修正了第 13 节结论的适用范围**，而且指向一个更有价值的表述：

> 同一产品内存在两套错误建模质量差异悬殊的通道。remote-MCP 侧区分了
> 超时/尺寸/scope/令牌刷新/并发等 40 种情形；managed-MCP 侧用一个
> `managed_mcp_auth_required` 覆盖了「未连接」与「连不上授权服务器」两个互斥状态。
>
> 这说明缺陷不是「团队不会做错误分类」，而是 **managed-MCP 通道的错误建模落后于 remote-MCP 通道**。

这个表述比原来的「错误码不携带诊断信息」更准确，也更容易被开发方接受和定位。

## 5. 新发现：结构化输出截断问题的机制找到了

这一条与 MCP 无关，但在同一次静态取证中发现，且**直接解释了另一位测试者报告的 P0**
（`fanghongwei1017/solo` Issue #3：CEO 规划任务过长 → 输出截断 → JSON 解析失败 → 强制终止）。

`dist/cli.js` 中的默认配置：

```js
planning:      { rounds: 5, maxRounds: 5, maxTasksPerPlan: 25 }
cyclePlanning: { rounds: 2, maxRounds: 2,
                 evaluatorParseMissAttempts: 2, maxEvaluatorParseMissAttempts: 3 }
run:           { maxReplans: 100, maxReplansLimit: 100 }
```

对应可覆盖的环境变量：`SOLOCO_MAX_TASKS_PER_PLAN`、`SOLOCO_EVALUATOR_PARSE_MISS_ATTEMPTS`、
`SOLOCO_PLANNING_ROUNDS`、`SOLOCO_MAX_REPLANS`。

两个数字放在一起就是矛盾：

| 量 | 值 | 来源 |
|---|---|---|
| 平台允许的单次规划任务上限 | **25** | `planning.maxTasksPerPlan` |
| 实测触发解析失败的任务数 | **约 6–7** | 他人报告的 Issue #3 |
| 结构化输出解析失败的重试次数 | **2**（上限 3） | `cyclePlanning.evaluatorParseMissAttempts` |

也就是说：**平台声明能规划 25 个任务，实际在 1/4 规模就会解析失败，
而失败后只重试 2 次即终止。**「声明容量」与「实际容量」差 4 倍，
这不是「用户把任务写太长了」，是配置默认值之间不自洽。

这把一个「偶发的 P0」变成了**有具体旋钮、可设计实验、可给出修复建议**的问题。

---

## 6. 下一步：真实 MCP 生命周期测试的可行路径

第 15 节把阻塞原因写成「需 gmail/slack/stripe 的真实 OAuth，风险高」。
基于本轮发现，这个判断需要更新——**存在一条低风险路径**：

`remote-mcp` 的三个 provider 是 `linear` / `notion` / `sentry`，
**没有一个涉及外发邮件或支付**。三者均有免费档，可用一次性测试工作区完成授权。
用 Notion 或 Linear 建一个空白测试工作区，即可打通此前全部「未测」状态格：

| 状态格 | 此前 | 用 notion/linear 后 |
|---|---|---|
| 已连接且正常调用 | ❌ 需 OAuth | ✅ 可测 |
| `capability: not_probed → ready` | ❌ | ✅ 可测（probe 走 `initialize` + `tools/list`） |
| `capability: incompatible` | ❌ | ✅ 可测 |
| 连接 token 过期 → `needs_reconnect` | ❌ | ✅ 可测（撤销授权后观察） |
| tool 调用超时 | ❌ | ⚠️ 部分（`remote_mcp_request_timeout` 需断网构造） |
| provider 返回 4xx | ❌ | ⚠️ 部分（撤销 scope 可触发 `scope_insufficient`） |

**风险对比**：notion/linear 测试工作区里没有真实数据、无外发副作用、无支付通道；
而 gmail/stripe 一旦授权，agent 具备真实发信与扣款能力。
**副作用闸门那个最高价值问题（第 15 节）应当排在最后做，且必须用专用账号。**

### 建议的执行顺序

| 序 | 内容 | 风险 | 前置 |
|---|---|---|---|
| 1 | 本轮静态取证 | 零 | ✅ 已完成 |
| 2 | Notion 测试工作区走通 `disconnected → connected` | 低 | 一次性 Notion 账号 |
| 3 | 观察 probe 行为，填 `capability` 状态格 | 低 | 同上 |
| 4 | 撤销授权，观察 `needs_reconnect` 与恢复路径 | 低 | 同上 |
| 5 | 规划规模扫描（`SOLOCO_MAX_TASKS_PER_PLAN` 6→25） | 中（烧 token） | 配额 |
| 6 | 副作用闸门（gmail 路径） | **高** | 专用测试邮箱 |

---

## 7. 本轮产物

| 文件 | 内容 |
|---|---|
| `mcp/probe_mcp_surface.sh` | 取证脚本，可独立复跑 |
| `mcp/evidence/environment.txt` | 环境指纹 + `cli.js` 校验和 |
| `mcp/evidence/api_auth_matrix.txt` | 端点认证要求矩阵 |
| `mcp/evidence/remote_mcp_connections.json` | remote-MCP 连接状态快照 |
| `mcp/evidence/managed_mcp_connections.json` | managed-MCP 连接状态快照 |
| `mcp/evidence/mcp_constants.txt` | provider 枚举、状态机、上游端点、40 个原因码 |
| `mcp/evidence/env_knobs.txt` | 全部 `SOLOCO_*` 环境变量（62 项） |
| `mcp/evidence/local_surface.txt` | `~/.soloco` 权限快照与相关表行数 |
| `mcp/watch_email_gate.sh` | 邮件闸门测试的观测装置（只读快照 + 自动比对） |
| `mcp/evidence/email_gate/before.txt` | 闸门测试基线快照（见第 9 节） |

## 8. 本轮的性质说明

本节全部结论来自**静态取证**：本地 HTTP 端点探测 + 已安装包的常量提取。
它证明的是「代码里写了什么」与「端点当前返回什么」，
**不能替代运行时行为验证**——例如第 5 节的容量矛盾是从默认值推出的，
实际失败阈值仍需第 5 项实验测出曲线才能定论。

---

## 9. 邮件审批闸门：静态定位与测试设计

第 15 节把「agent 经 gmail 的 MCP 连接发信是否经过审批闸门」列为最高价值待测问题。
本节先用静态取证把闸门的挂载位置定位出来，再据此设计测试——
**因为设计错了会得到假阳性。**

### 9-1 先纠正一个前提：已授权的不是 gmail 的 MCP 连接

2026-07-30 授权 gmail 测试邮箱后的实测状态：

```
GET /managed-mcp/connections
→ {"connections":[], "configuredProviders":[...8 个...], "availableProviders":[...]}

sqlite> select id, credential_type from credential_records;
1|email
```

`connections` 为**空数组**，`credential_records` 只有一条 `credential_type = "email"`。
事件流对应一条 `email.connection.connected`（actor = `human`，08:07:15Z）。

即：**授权走的是 SoloCo 自研邮件通道（provider 枚举 `gmail|icloud|tencent_enterprise|aliyun_enterprise|custom`），
不是 managed-MCP 的 gmail 连接。** 两者同名但是两套东西。

**这一点必须先纠正，否则测试直接失效**——在此状态下让 agent 发信，走的是自研路径，
必然经过闸门，会得出「闸门有效、MCP 不构成旁路」的**假阳性**结论。

### 9-2 闸门的实际结构（自研路径）

路由分为 agent 面与人工面两组：

| 面 | 端点 | 认证 |
|---|---|---|
| agent 可达 | `POST /email/agent/drafts`、`/email/agent/messages` | 随 run 租约 |
| **人工审批** | `POST /email/drafts/:id/approve`<br>`POST /email/drafts/:id/confirm-send`<br>`POST /email/drafts/:id/reject` | `x-soloco-approval-token` |

实测认证确实生效，且用的是常量时间比较：

```
curl /email/drafts                                    -> 401 bad_approval_credential
curl -H "x-soloco-approval-token: <token>" /email/drafts -> 200 {"drafts":[]}
curl -H "Authorization: Bearer <token>" /email/drafts  -> 401   # 与 daemon-token 不通用
```

```js
function u2(e){ return e.req.header("x-soloco-approval-token") ?? "" }
function l2(e,t){ let n=Buffer.from(t); return n.length===e.length && timingSafeEqual(n,e) }
```

**结论：自研路径上 agent 只能建草稿，发送需人工两步（approve → confirm-send），
凭据独立于 daemon-token，比较为常量时间。这一层设计是扎实的。**

值得对照的是：**这个审批端点有认证，而第 3 节的 MCP 端点没有。**
同一个 daemon 里两类端点的认证要求不一致。

### 9-3 MCP 通道上没有对应的语义闸门

managed-MCP 的请求过滤只到 JSON-RPC 方法级：

```js
N6 = new Set(["initialize","notifications/cancelled","notifications/initialized",
              "ping","tools/call","tools/list"])

if (!N6.has(e.method)) throw new Qe(403, "managed_mcp_method_rejected");
if (e.method === "tools/call" &&
    (!co(e.params) || typeof e.params.name !== "string" || e.params.name.length === 0))
  throw new Qe(403, "managed_mcp_tool_name_required");
```

注意 `managed_mcp_tool_name_required` **只校验工具名是非空字符串，不比对任何白名单**。
`tools/call` 本身在允许集内。

因此客户端侧对 MCP 工具调用的控制只有四层，**没有一层理解工具的语义**：

1. 方法白名单（6 个 JSON-RPC 方法）
2. `capabilityRequests` 逐 run 租约（声明用哪个 provider）
3. 并发 / 尺寸 / 超时限制
4. 传输层错误分类

对比之下，自研路径的邮件有 `/email/drafts/*/approve`，支付有
`/goals/:goalId/payment-intents/:intentId/approve`——**两个闸门都挂在自研实现上，
不在「外部副作用」这个抽象层上。**

### 9-4 由此得出的预判与其边界

**预判**：第 15 节那张表的答案倾向于「不会」，即 MCP 构成绕过旁路。

**但这个预判有一处静态分析够不到的地方**：managed-MCP 的凭据由 SoloCo 云端代管，
授予 gmail 连接的 **scope 是服务端决定的**。若云端只授予只读 scope
（gmail MCP server 根本不暴露发信工具），那么「绕过」就不成立——
不是因为有闸门，而是因为**没给能力**。

这两种情况的产品含义完全不同，必须用实测区分：

| 实测结果 | 结论 | 定级 |
|---|---|---|
| gmail MCP 不暴露发信工具 | 靠 scope 收敛，非闸门。**换一个暴露写操作的 provider 仍会绕过** | Medium |
| 暴露发信工具且发送不经审批 | 闸门被绕过，架构级问题 | **High** |
| 暴露发信工具但发送被降级为草稿 | 闸门挂在副作用抽象层，设计扎实 | 正面结论 |

### 9-5 测试步骤（按风险递增，可随时停在任一步）

观测装置：`mcp/watch_email_gate.sh`，只读快照 + 自动比对，不发信、不触发 goal。

| 步 | 动作 | 是否产生外发副作用 | 能回答什么 |
|---|---|---|---|
| 0 | `bash mcp/watch_email_gate.sh before` | 否 | 基线（已采，见 `evidence/email_gate/before.txt`） |
| 1 | `POST /managed-mcp/connections/authorize {"provider":"gmail"}`，浏览器完成 OAuth | 否 | 连接是否真能建立；`connections` 是否非空 |
| 2 | 对该连接发 `tools/list` | **否** | **是否存在发信工具——多数情况到这步即可定论** |
| 3 | 仅当第 2 步存在发信工具：让 agent 向测试邮箱**自己发给自己**一封信 | **是** | 发送是否被降级为草稿、是否要求审批 |
| 4 | `bash mcp/watch_email_gate.sh after` | 否 | 自动比对，出判读结论 |

**第 2 步是本测试的关键**：`tools/list` 是只读的，不产生任何副作用，
却能区分上表三种结论中的第一种。**不要跳过第 2 步直接发信。**

第 3 步的约束：

* 收发件人必须是同一个**专用测试邮箱**，不得涉及任何真实联系人
* 该邮箱不应含真实数据（gmail MCP 连接授权后 agent 具备读取邮箱内容的能力）
* 支付通道（`stripe` 同在 managed-MCP 且 `payment.enabled` 默认 `false`）
  **不在本测试范围内，不要为了对称而开启**

### 9-6 本节性质说明

9-2、9-3 为静态取证，结论限于**客户端代码写了什么**。
9-4 的预判**尚未经运行时验证**，在第 2、3 步完成前不应作为结论引用。

### 9-7 UI 取证：gmail 可能是错误的测试对象

从 UI bundle 提取的 8 个 managed 连接能力描述（`dist/web/assets/index-*.js`）：

| provider | 描述 | 语义 |
|---|---|---|
| `gmail` | Read and organize email as mission evidence.<br>读取和整理邮件，作为任务证据。 | **只读** |
| `slack` | Read channels and **deliver** mission output. | **可外发** |
| `linkedin` | Reach decision-makers and **maintain** professional content. | **可发布** |
| `stripe` | **Create** payment links and track order revenue. | **可创建收款** |
| `notion` | **Write** results into your workspace. | 可写 |
| `hubspot` | Maintain customer and lead records. | 可写 |
| `linear` | Track issues and sync progress. | 可写 |
| `sentry` | Monitor errors and attribute them to changes. | 只读 |

**gmail 的描述里没有发信。** 若属实，则用 gmail 测「闸门是否覆盖 MCP 路径」
会落进第 9-4 节表格的第一行——**「不绕过」是因为没给发信能力，而非有闸门**，
定级 Medium，且这个结论对其它 provider 不成立。

相反，`slack`（deliver mission output）与 `linkedin`（maintain professional content）
的描述明确包含外发语义。**若要测副作用闸门，这两个才是对的靶子。**

其中 **slack 优于 gmail 作为测试对象**：

* 描述层面明确可外发，能真正触发「有副作用但无闸门」的组合
* 自建一个空 workspace、发到自己的私有频道，可控性高于邮件
* 消息可删除，邮件发出不可撤回
* SoloCo 的自研路径**没有** slack 对应物（自研只有邮件与支付），
  因此若 slack 外发不经任何审批，即可直接证明「闸门挂在自研实现上而非副作用抽象层」

> ⚠️ 上表是 **UI 文案**，属产品描述而非权威 scope 声明。
> 权威来源有两个，且都在真正授权之前/之中即可获得：
> 1. **OAuth 同意页本身** —— Google / Slack 的授权页会逐条列出申请的 scope。
>    这一屏就是证据，**授权前截图即可**，此时尚未授予任何权限。
> 2. `tools/list` —— 连接建立后只读枚举工具清单。
>
> 两者任一与 UI 文案矛盾，以它们为准。

### 9-8 附带发现：UI 里「Gmail」出现两次，语义不同

同一个 daemon 的 UI 中，Gmail 以两种互不相干的身份出现：

| 入口 | 实际是什么 | 能否发信 | 是否有审批闸门 |
|---|---|---|---|
| 「Connect my email」 | 自研邮件通道（`credential_type=email`） | 能 | **有**（草稿 → approve → confirm-send） |
| 资产页 Gmail 卡片 | managed-MCP 连接 | 据描述只读 | 无语义闸门 |

两者共用「Gmail」这一名称，UI 上没有任何提示说明它们是两条独立通道、
能力与管控完全不同。**本轮测试的第一次尝试就因此走错**——
授权了自研通道却以为连上了 MCP（见第 9-1 节）。

这是一个真实的可用性缺陷：用户无法从界面判断自己授予了哪一类权限。
建议在两处分别标注通道类型与能力边界。定级 **Medium（可用性 / 权限透明度）**。

### 9-9 运行时取证：managed-MCP 是「云端 relay + 策略闸门」，副作用管控不在本地

第 9-3 节据本地代码得出「MCP 通道无语义闸门」。授权 gmail 测试邮箱后，
运行时取证表明**这个结论只对了一半**：本地确实没有语义闸门，
但语义管控整体上移到了云端 relay。以下均为零 token、只读取证。

#### 授权后的状态

```
GET /managed-mcp/connections
→ connections:[{ id:"<conn-id>", provider:"gmail",
                 environment:"live", status:"connected", authorizationEpoch:1 }]

sqlite> select credential_type from credential_records;
email        ← 仍只有自研通道这一条
```

**MCP 凭据不落本地**——`credential_records` 授权前后都只有自研邮件那一条。
gmail 的 MCP 凭据由云端代管，本地只持有连接引用。

#### relay 形态

managed-MCP 的实际数据路径是 `POST <cloud-base>/api/soloco/managed-mcp/sessions/<id>/mcp`，
用户自己的 `accessToken` 鉴权。initialize 应答：

```
server: Vercel
{"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":true}},
 "serverInfo":{"name":"mcp-typescript server on vercel","version":"0.1.0"}}}
```

即一个 **Vercel 上的无状态 JSON-mode MCP server**。会话由 URL 里的 sessionId +
Bearer token 绑定，无独立会话头。

#### 能力面是动态的，`tools/list` 会严重低估

对 gmail 连接调 `tools/list`，只返回 **3 个 Composio 元工具**：

| 工具 | 语义 |
|---|---|
| `COMPOSIO_SEARCH_TOOLS` | 按用例检索本会话「已批准的动作」 |
| `COMPOSIO_GET_TOOL_SCHEMAS` | 取某 action slug 的入参 schema |
| `COMPOSIO_MULTI_EXECUTE_TOOL` | 执行已批准的 action slug |

**真实能力（能不能发信）不是工具名，而是 `COMPOSIO_MULTI_EXECUTE_TOOL` 的参数
（action slug），且这些 slug 是「本会话已批准」的动态集合。**

这直接修正了第 9-4 节的测试设计前提：**「gmail 是否暴露发信工具」无法用 `tools/list` 回答**，
因为工具是动态的、按会话批准的。这也是我此前判读脚本出错的原因——
它去工具名里找 `send`，而 gmail 的工具名里根本没有业务动词。

#### 关键发现：relay 有双向策略闸门，且完全在云端

尝试用用户自己的合法 token 从外部枚举「已批准动作」时，连续撞到两道 relay 闸门：

| 阶段 | 返回 | 含义 |
|---|---|---|
| 请求入站 | `RELAY_POLICY_DENIED` / `meta_unknown_field` | **请求 gate**：请求结构不合策略即拒 |
| 响应出站 | `PROVIDER_POLICY_DRIFT` / `Response gate rejected (meta_response_shape_invalid)` | **响应 gate**：上游 provider 的应答结构不合策略也拒 |

**这四个策略码在本地 `cli.js` 中出现 0 次**（已 grep 确认）——
它们纯粹来自云端 relay。也就是说：

> managed-MCP 的策略校验是**服务端强制、双向（请求+响应）、本地不可见**的。
> 本地客户端看不到、也无法关闭这层校验。

#### 对第 9-3 节的完成与对威胁模型的结论

第 9-3 节「本地无语义闸门」成立，但不完整。完整图景是：

```
本地 daemon:  方法白名单 + 逐 run 租约 + 尺寸/超时      （无业务语义）
     ↓ 经 accessToken 鉴权的 relay 会话
云端 relay:   请求 gate + 响应 gate（PROVIDER_POLICY_DRIFT / RELAY_POLICY_DENIED）
     ↓
Composio:     按会话批准的 action slug 集合
```

因此第 15 节「MCP 是否构成副作用管控的旁路」这一威胁，
**在 relay 层得到实质缓解**，而非仅靠本地：

* 持有用户合法云端 token 的**外部进程**，仍无法自由枚举/驱动 provider 动作——
  被 relay 的策略闸门挡住（实测 `RELAY_POLICY_DENIED` → `PROVIDER_POLICY_DRIFT`）。
* 能力集是**按 run 的 `capabilityRequests` 在云端动态批准**的，不是静态开放。

这是一个**偏正面的架构结论**，比原计划「发一封信看是否降级为草稿」信息量更大：
管控点在云端 relay，且对本地不可见、不可绕过。

#### 本轮**没有**做、以及为什么

**我没有尝试去满足/绕过那道响应策略闸门。** 让一个外部非 agent 客户端
通过 relay 成功执行 Gmail 动作，等于绕过一个 relay 明确标注为 "policy gate" 的安全控制——
这既非本测试所需，也不应去做。**闸门把外部客户端挡在门外，这件事本身就是结论。**

#### 仍未定论的一点，与唯一正当的下一步

「agent 经 MCP 发信是否被降级为草稿/是否要审批」这一具体问题，
本轮**仍未直接观测到**——因为要观测它，必须走**真实 agent 路径**
（agent 的请求才能合法通过 relay 闸门）。那条路径：

* 会**真实发出一封邮件**（有外部副作用，不可撤回）
* 会**消耗 token**（要跑一个真实 goal）

因此它必须满足全部前置条件才可执行，且需使用者明确逐次授权：

| 前置 | 要求 |
|---|---|
| 收发件人 | 同一个**专用测试邮箱**，自己发给自己，不涉及任何真实联系人 |
| 邮箱数据 | 该邮箱无真实数据（agent 已具备读取该邮箱的能力） |
| 观测 | 全程 `mcp/watch_email_gate.sh before/after`，看 `email_reply_ledger`、
      是否出现无 approve 的 `email_sent` 事件 |
| 支付通道 | `stripe` 同在此 relay 且默认关闭，**不在范围内，不touch** |

在满足上述条件、且使用者明确同意「真实发信 + 消耗 token」之前，此步不执行。

#### 本轮产物

| 文件 | 内容 |
|---|---|
| `mcp/list_managed_tools.sh` | 经云端 relay 只读枚举某 provider 的 `tools/list`（零 token） |
| `mcp/search_actions.sh` | 尝试只读枚举「已批准动作」；实测被 relay 响应 gate 拦下 |
| `mcp/evidence/tools_gmail.json` | gmail 的 3 个 Composio 元工具及 schema |
| `mcp/evidence/init_gmail.json` | relay initialize 应答（证明 Vercel 无状态 MCP） |
| `mcp/evidence/session_gmail.json` | 会话申请应答 |
| `mcp/evidence/actions_gmail_*.json` | 响应 gate 拒绝记录（`PROVIDER_POLICY_DRIFT`） |

所有产物已脱敏：无 token、无邮箱、会话/请求 id 与云端域名以占位符替换。

### 9-10 运行时发信测试：被 runtime 403 阻断，但同时三重复现既有缺陷

在使用者明确授权「真实发信 + 消耗少量 token」后，用真实 agent 路径做了发信测试。
**结果：goal 在规划阶段即因 runtime 403 失败，从未到达发信步骤。**
gate 问题因此仍未直接观测到，但这次尝试**同时复现了三个既有缺陷**，价值不低。

#### 测试设计

* 目标：`autonomy=autonomous`（最宽松，用以区分「邮件专有闸门」与「autonomy 本身即闸门」）
* 成本上限：`--budget 2`
* 目标极窄：经已连 Gmail 向 agent **自己的**地址发一封 `[SoloCo-GATE-TEST]`，发完即止
* 收发件人同为测试邮箱本身，零真实联系人；全程 `watch_email_gate.sh` before/after

#### 实际发生

```
goal_launched → run.started(conductor/planning)
run.log: {"model":"<synthetic>","stop_reason":"stop_sequence",
          "content":[{"text":"Failed to authenticate. API Error: 403 Request not allowed"}],
          "error":"authentication_failed","total_cost_usd":0,"input_tokens":0}
run.completed: status=failed "Local claude exited with 1"
goal.paused: "Claude runtime transient error", retryAt=+2min
```

**副作用核对**：`email_drafts` 0→0，`email_reply_ledger` 0→0，无 `email_sent` 事件。
即 runtime 从未到达发信步骤，**无任何邮件产生**——gate 无从触发，本次不构成对 gate 的观测。

#### 三重复现（这才是本次的产出）

| # | 复现的既有结论 | 本次现场证据 |
|---|---|---|
| 1 | 第 13 节结论二：**永久性错误被判为瞬时** | 403 `authentication_failed`（永久）被 `errorCode:runtime_transient` + 每 2 分钟无限重试 |
| 2 | 第 13 节结论三 / doctor 网络盲区 | `soloco runtimes` 自报 `claude LOGIN=ok`，实际 API 返回 403。**自检说健康，真实调用失败** |
| 3 | 第 7 节：无取消 goal 的手段 | goal 卡在 403 重试环（run_29 → 09:37 再次 run.started），CLI 无法单独终止 |

三者叠加正是第 13-4 节那条「无出口的死胡同」——这次不是注入构造的，
而是**一个真实 goal 自然踩中**，证据链完整（见 `evidence/email_gate/runtime_403_block.txt`）。

补充一个新的精确观察：**`budget` 无法作为此环的止损**。因为每次重试 `total_cost_usd:0`，
预算永不消耗，`--budget 2` 形同虚设——预算护栏对「0 成本的失败重试环」不生效。

#### 403 的根因与解阻步骤

daemon 进程环境无 `HTTPS_PROXY`。宿主机装有 Clash Verge，但 **WSL daemon 及其 spawn 的
`claude -p` 子进程未继承宿主代理**，直连 Anthropic 边缘得到 `403 Request not allowed`。
与第 13 节 grid 6/7（代理相关）同源。

> 解阻（留给使用者决定，涉及网络/守护进程配置，未擅自执行）：
> 为 daemon 注入代理后重启，例如
> `HTTPS_PROXY=http://127.0.0.1:<clash端口> HTTP_PROXY=… soloco start`，
> 再 `soloco runtimes` 确认，然后重跑本测试。
> 若注入代理后仍 403，则根因转为「订阅登录态不允许 headless/SDK 调用」，另议。

#### gate 问题的当前状态

**「agent 经 MCP 发信是否被降级为草稿/需审批」仍未定论**，但边界已收窄到极小：
装置（`watch_email_gate.sh`）、目标、授权均已就位，**只差 runtime 能实际发出 API 调用**。
一旦上面的代理解阻生效，重跑同一条 goal 即可得出结论，无需新设计。

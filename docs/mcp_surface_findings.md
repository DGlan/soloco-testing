# MCP 接入面取证：对第 14、15 节结论的修正与细化

> 环境：SoloCo 0.2.1 / Node v24.18.0 / WSL2 Ubuntu 24.04 LTS
> `cli.js` sha256 `c91bd282…f71381`
> 采集时间：2026-07-30T08:53:31Z
> 复现：`bash mcp/probe_mcp_surface.sh`，产物在 `mcp/evidence/`
> **成本：零 token。**全部为本地 HTTP 探测与已安装包的静态读取，未触发任何 goal。

---

## 0. 本轮为什么要做

`docs/wsl_goal_run_findings.md` 第 14-1 节据**一个 404** 得出结论：

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

## 8. 本轮的性质说明

本节全部结论来自**静态取证**：本地 HTTP 端点探测 + 已安装包的常量提取。
它证明的是「代码里写了什么」与「端点当前返回什么」，
**不能替代运行时行为验证**——例如第 5 节的容量矛盾是从默认值推出的，
实际失败阈值仍需第 5 项实验测出曲线才能定论。

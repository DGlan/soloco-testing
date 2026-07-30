# SoloCo 0.2.1 产品测试报告

**测试人**：刘逸　|　**版本**：`@soloco/client` 0.2.1　|　**日期**：2026-07-30
**平台**：WSL2 / Ubuntu 24.04 LTS（内核 5.10.16，Node v24.18.0，Claude Code 2.1.220）
**账号**：Claude Pro 订阅（无 API key）
**证据链**：https://github.com/DGlan/soloco-testing　（`cli.js` sha256 `c91bd282…f71381`；升级后结论需复验）

> **方法论**：所有数值来自 `~/.soloco/daemon.db` 只读查询与 daemon HTTP 端点实测，
> **不采用界面显示值**——界面本身是被测对象，用它验证自己是循环论证。
> 静态结论注明源自 `cli.js`（编译期常量），运行时结论注明源自实测。

---

## 摘要

**总结论**：SoloCo 0.2.1 的底层设计有多处超出预期的纵深防御（逐 run 沙箱白名单、
自研邮件两步审批、凭据信封加密、云端 relay 双向策略闸门）；但**可观测性与错误分类
存在系统性缺陷**——token 计数漏 cache、永久错误判为瞬时并无限重试、`doctor`/`runtimes`
自检与真实调用脱节、卡死 goal 无法取消。这些缺陷会在真实长跑任务里直接伤害用户对
**成本与状态**的判断。

**缺陷汇总（按严重度）**

| 严重度 | 缺陷 | 所属块 | 状态 |
|---|---|---|---|
| 高 | token 计数漏 cache 字段，面板 token 与成本值自相矛盾 | 通用 | 已证实 |
| 高 | `doctor`/`runtimes` 零网络检查，云端不可达仍报健康 | 通用 | 已证实 |
| 高 | 规划容量不自洽：声明 25 任务，实测约 6–7 即结构化输出解析失败 | 通用 | 已证实 |
| 中 | 永久故障判为瞬时 → 无限重试 → 无法取消 goal（复合死胡同） | 通用 | 已证实 |
| 中 | 同一错误码覆盖互斥状态（限 managed-mcp 通道） | MCP | 已证实 |
| 中 | UI 中 Gmail 双重身份（自研通道 vs MCP 卡片）无区分 | MCP | 已证实 |
| 中 | 本地 MCP 端点无认证（daemon 绑 127.0.0.1） | MCP | 已证实 |
| 低 | 云同步 syncable 事件含任务原文与本地路径 | 通用 | 待开发方确认 |
| 低 | `soloco trust list` 子命令风格不统一 | 通用 | 已证实 |

**做得对的地方（应予认可）**

- 自研邮件外发**两步人工审批闸门**（草稿 → approve → confirm-send，凭据独立、常量时间比较）
- managed-MCP 走**云端 relay，双向策略闸门**（请求 + 响应），本地不可见、外部客户端不可绕过
- 逐 run 下发**沙箱可写路径白名单**；reviewer 校验 `externalActions`/`scopeDegradations` 为空
- 凭据**信封加密**（`encrypted_payload`/`envelope_version`/`cas_version`），非明文
- 支付**默认关闭 + 双层限额**（¥500/次、¥2000/任务）
- 退出码可脚本化；工作区隔离启动即生效

---

## 报告结构

本报告分两块，对应两条独立的测试线：

- **第一部分 · 产品通用测试**：编排、可观测性、错误处理、安全隔离等产品层面。
- **第二部分 · MCP 定向测试**：MCP 通道结构、接入面、relay 架构、副作用闸门。

每条缺陷给出「现象 / 证据 / 影响 / 建议」，原始记录与复现命令见 GitHub 证据链
（附录 C 为索引）。

---

# 第一部分 · 产品通用测试

> 详细原始记录：`docs/product/wsl_goal_run_findings.md`（922 行）、
> `docs/product/wsl_setup_log.md`（环境搭建全过程）

## 1. 范围与方法

在受支持平台（WSL2）上从零搭建环境，发起真实 goal，通过直接读取 daemon 的
SQLite 库与事件流来观测行为，并用**受控故障注入**填出错误分类真值表。
本块聚焦**可靠性、可观测性、成本透明度、人工介入**四个维度。

## 2. 发现

### 2.1 token 计数漏 cache，面板自相矛盾（高 / 已证实）

- **现象**：面板对某 goal 同时显示「累计 token 7,404」与「成本 $0.85」。
- **证据**：
  - token 低估——某 goal 显示 56,194，实际（含 cache 创建/读取）1,387,714，**≈ 24.7×**。
  - 面板自相矛盾——用面板自己的 token 与成本反推单价，**21/21 个 run 全部**超出模型
    最贵档（output $15/MTok）理论上限，最高 **30.3×**（run_21：365 token / $0.166），平均 5.7×。
  - 根因：`totalTokens = input + output`，漏加两个 cache 字段。交叉验证证明**成本计算是
    cache-aware 且正确**（21 run 拟合偏差 3.8%）——同一份数据在同一套代码里一处用对、
    一处用错，可精确定位到汇总那一行。
- **影响**：两个数字物理上不可能同时正确；对订阅制用户，token 是唯一直观消耗信号，
  而它恰好是错的。严重性在**信任与可解释性**，金额本身估算尚准（$0.85 vs 真实 $0.83）。
- **建议**：`total = input + cache_creation + cache_read + output`。

### 2.2 结构化输出截断 / schema 校验失败（高 / 已证实）

- **现象**：Conductor 规划任务较多时，结构化输出解析失败，goal 被迫终止。
- **证据**：`cli.js` 默认 `planning.maxTasksPerPlan = 25`，但实测约 **6–7** 个任务即触发
  解析失败；失败重试上限 `cyclePlanning.evaluatorParseMissAttempts = 2`。**声明容量与
  实际容量差约 4 倍**，且失败后仅重试 2 次即止。
- **影响**：用户按「可规划 25 任务」的预期拆解任务，会在 1/4 规模处意外失败，
  且难以自证是「任务写太长」还是产品缺陷。
- **建议**：令 `maxTasksPerPlan` 声明值与实际解析上限对齐；或提高重试上限；
  可用 `SOLOCO_MAX_TASKS_PER_PLAN` 做 N∈{4,6,8,10,12} 的解析成功率扫描定位阈值。

### 2.3 错误分类：永久故障判为瞬时 + 无限重试（中 / 已证实）

- **证据（受控注入真值表，6/7 格零成本）**：
  - provider 返回 403（永久配置缺失）→ 判 `runtime_transient` / `auto_retry`，每 2 分钟
    **无限重试**，`recoveryActions` 为空，界面提示「临时错误，正在自动重试」。
  - managed-MCP 无连接（云端可达）→ boot 日志报 `auth_required`，端点却返回 HTTP 200 空列表
    ——**启动路径与查询路径判定相反**。
- **影响**：永久故障重试一万次结果不变，用户被告知等待即可。
- **建议**：分类规则区分永久/瞬时；永久错误不进自动重试，给出可执行动作。
- **备注**：错误框架本身设计良好（含 `confidence`/`retryability`/`recoveryActions`/可读文案），
  问题在**分类映射规则**，不在框架。

### 2.4 doctor / runtimes 零网络检查（高 / 已证实）

- **证据**：云端完全不可达、代理指向死端口两种情况下，`soloco doctor` 均报 **5/5 健康**；
  运行时测试中 `soloco runtimes` 报 `claude login=ok`，而实际 API 返回 403（见 8.3）。
  对照同机 `lark-cli doctor` 检查 9 项含 2 项出网可达性（`endpoint_open`/`endpoint_mcp`）。
- **影响**：自检说健康，真实调用失败——用户在遇到永久网络故障前得到「全部健康」。
- **建议**：增加一项出网可达性检查（成本最低、收益最大）。

### 2.5 goal 无法取消，停 daemon 会自动续跑（中 / 已证实）

- **证据**：CLI 无终止单个 goal 的手段（`soloco goal` 仅 start/steer/resume）；`stop` 只停
  daemon，且重启**自动续跑**未完成 goal。运行时测试中一个 403 goal 因此卡在重试环无法清除。
- **影响**：与 2.3 + 2.4 复合成**无出口死胡同**：doctor 报健康 → goal 403 → 判瞬时无限重试
  → 界面让等待 → 无法取消 → 用户无限等待。修复任意一环即可打断。
- **建议**：提供 `goal stop <id>`。
- **新观察**：`--budget` 对「0 成本失败重试环」不生效（每次 `total_cost_usd=0`，预算永不消耗）。

### 2.6 云同步范围与本地数据面（低 / 待开发方确认）

- **证据**：云同步活跃；标记 `syncable` 的事件包含**任务原文与本地路径**；`daemon.db`
  权限 644（同机其他用户可读事件历史），凭据文件为 600（正面）。
- **建议**：明确 syncable 边界；收敛 `daemon.db` 权限至 600。

## 3. 安全 · 间接提示注入（观察 / 有局限）

- **设计**：工作区 `notes.md` 内嵌两处注入（明文「忽略之前指令」+ 伪装 HTML 注释的系统提示），
  各有独立可观测产物；合法任务仅要求总结文档。
- **结果**：两处注入产物均未生成，总结未纳入注入文本。发现纵深防御：`run.started` 携带逐 run
  沙箱描述符（`writablePaths` 白名单等），reviewer 校验 `externalActions`/`scopeDegradations` 为空。
- **⚠️ 关键局限**：注入是被 **executor（Claude 模型本身）**挡下的，SoloCo 审查层因无越界行为
  漏出而**未被触发**。故本测试度量的是**模型鲁棒性**而非平台防御有效性，**不能**得出
  「SoloCo 抵抗了注入」的结论。
- **后续**：换弱鲁棒性 runtime（codex/kimi/qwen）复跑以区分模型贡献与平台贡献。

## 4. 本块未覆盖

- 复杂任务下的编排能力（本轮全部为最小任务）
- 弱 runtime 下的注入、网页内容注入载体
- 纯 Linux（容器/云主机）复跑——「平台无关」目前是主张非证据
- 云同步实际传输内容（需抓包）

---

# 第二部分 · MCP 定向测试

> 交付原件：`docs/mcp/MCP_测试报告.md`（飞书版）；补充取证：`docs/mcp/mcp_surface_findings.md`；
> 脚本与证据：`mcp/`

## 1. 范围与方法

以 MCP 为切入点，通过 daemon 路由表、端点实测、`cli.js` 静态常量与云端 relay 会话
（用户自持 token）做**零 token、只读**取证。真实连接生命周期在获得 gmail 测试邮箱授权后
做了运行时验证（见 8.3）。

## 2. 通道结构：remote-mcp vs managed-mcp

| 通道 | provider 清单 | 凭据 |
|---|---|---|
| `remote-mcp` | linear, notion, sentry（**3 个**） | 用户自持 OAuth |
| `managed-mcp` | linear, notion, gmail, linkedin, slack, sentry, stripe, hubspot（**8 个**） | SoloCo 代管 |

> **修正**：两通道差别是**凭据托管方式**，不是「自定义 vs 官方」；remote-mcp 也是固定 3 个
> provider，并非用户自带 server。`gmail`/`slack`/`stripe` 仅在托管通道，信任面更大。

## 3. 不支持自建 MCP server（源码级证据）

- provider 校验为编译期 zod 枚举 `Yd=["linear","notion","sentry"]`；上游端点硬编码
  （`mcp.linear.app/mcp` 等），无 env 覆盖；CLI 无 MCP 注册子命令。
- **意义**：0.2.1 无自定义 MCP server 接入面。因此注入测试改用文件载体是**唯一可行路径**，
  非退让。

## 4. 接入面：本地 MCP 端点无认证（低-中 / 已证实）

- **证据**：`/remote-mcp/connections`、`/managed-mcp/connections` 等不带 `daemon-token`
  均返回 200。daemon 绑 `127.0.0.1`，不构成远程暴露。
- **定性**：同机任意本地进程可枚举 MCP 连接状态、provider 清单与 scope，无需 token。
  与 `daemon.db` 644 同属**本地面信任模型**问题，建议合并处理。

## 5. 错误建模：两通道质量悬殊（中 / 认知修正）

- **证据**：remote-mcp 有 **40 个**独立原因码（区分超时/尺寸/scope/令牌刷新/并发…）；
  managed-mcp 用一个 `managed_mcp_auth_required` 覆盖「未连接」与「连不上授权服务器」两个互斥状态。
- **准确表述**：不是「团队不会做错误分类」，而是 **managed-mcp 通道的错误建模落后于 remote-mcp 通道**。

## 6. 关键架构：managed-mcp = 云端 relay + 双向策略闸门（偏正面）

- **证据**：managed-MCP 数据路径为 `POST <cloud>/api/soloco/managed-mcp/sessions/<id>/mcp`，
  用用户自持 `accessToken` 鉴权，是 **Vercel 上的无状态 JSON-mode MCP server**。
  用合法 token 从外部尝试驱动时连撞两道闸门：
  - 请求入站 `RELAY_POLICY_DENIED` / `meta_unknown_field`
  - 响应出站 `PROVIDER_POLICY_DRIFT` / `meta_response_shape_invalid`
  这四个码在本地 `cli.js` 出现 **0 次**——**纯云端强制、双向、本地不可见/不可绕过**。
- **意义**：这**完成并修正**了第一部分「本地无语义闸门」的图景——语义管控上移到云端 relay。
  「持用户 token 的外部进程能否绕过管控」这一威胁，在 relay 层得到实质缓解。
- **测试边界声明**：我**刻意未尝试满足/绕过**该响应策略闸门——那等于绕过一个明确标注的
  安全控制，非本测试所需。闸门把外部客户端挡在门外，本身即结论。

## 7. 能力模型：动态 action-slug（认知修正）

- **证据**：对 gmail 连接调 `tools/list` 仅返回 3 个 Composio 元工具
  （`SEARCH_TOOLS`/`GET_TOOL_SCHEMAS`/`MULTI_EXECUTE_TOOL`）。真实能力是执行工具的**参数**
  （按会话批准的 action slug），非工具名。
- **意义**：「gmail 是否暴露发信」**无法用 `tools/list` 回答**；能力集按 run 的
  `capabilityRequests` 在云端动态批准。

## 8. 邮件审批闸门：自研路径 vs MCP 路径

### 8.1 自研邮件路径的闸门（正面结论）

- agent 面 `POST /email/agent/drafts` **只能建草稿**；人工面 `/email/drafts/:id/approve`
  → `/confirm-send` 需 `x-soloco-approval-token`（实测 401/200，凭据独立于 daemon-token，
  `timingSafeEqual` 常量时间比较）。**两步人工审批，设计扎实。**

### 8.2 UI 双重 Gmail（中 / 可用性缺陷）

- UI 中 Gmail 以两种互不相干的身份出现：「Connect my email」是**自研邮件通道**（能发信、
  有两步审批），资产页 Gmail 卡片是 **managed-MCP 连接**（据 UI 文案只读、无语义闸门）。
  两者同名且界面无区分——本轮测试第一次尝试即因此走错通道。
- **建议**：分别标注通道类型与能力边界。

### 8.3 运行时发信测试 → 403 阻断 + 三重复现

- **设计**：经授权后用真实 agent 路径（`autonomy=autonomous`，`--budget 2`，自己发给自己）
  发一封测试邮件，观测是否被降级为草稿/需审批。
- **结果**：goal 在**规划阶段即 runtime 403 失败**（`"API Error: 403 Request not allowed"`，
  `authentication_failed`），从未到达发信步骤。before/after 比对：`email_drafts` 0→0、
  `email_reply_ledger` 0→0、无 `email_sent`——**无任何邮件副作用**。
- **副产出（三重复现第一部分缺陷）**：该 403 同时坐实
  ①永久错误判为瞬时并无限重试（2.3）②`runtimes` 报 login=ok 而 API 403（2.4）
  ③goal 卡死无法取消（2.5）——由一个真实 goal 自然踩中，即 2.5 所述死胡同。
- **根因**：daemon 无 `HTTPS_PROXY`，宿主 Clash 代理未传入 WSL 子进程 → Anthropic 边缘 403。
- **状态**：**「MCP 发信是否过审批闸门」仍未定论**，但装置/目标/授权均已就位，
  只差为 daemon 注入代理这一步；解阻后重跑同一 goal 即可得结论，无需新设计。

## 9. 本块未覆盖 + 最高价值待办

- **最高价值待办**：8.3 的 MCP 发信闸门测试——它决定 6/8.1 的正面结论是否覆盖**外发副作用**
  这条最敏感路径（stripe 同在托管通道，答案关乎产品安全模型）。
- remote-mcp 完整生命周期：linear/notion/sentry **无外发副作用**，可用一次性测试工作区低风险打通。
- managed-mcp 已批准 action slug 全集；支付限额客户端 vs 服务端校验（不开真实 stripe）。

---

# 附录

## A. 未覆盖范围与下一轮（canary）建议

| 待办 | 风险 | 前置 | 优先级 |
|---|---|---|---|
| MCP 发信闸门（8.3 续） | 中（真实发信+token） | 为 daemon 注入代理 | ★★★ |
| remote-mcp 生命周期（notion/linear） | 低 | 一次性测试工作区 | ★★ |
| 规划容量阈值扫描（2.2） | 中（token） | 配额 | ★★ |
| 弱 runtime 下注入（3 续） | 低 | codex/kimi/qwen 接入 | ★★ |
| 支付校验层（不开真实 stripe） | 中 | 改本地 config 观测服务端 | ★ |
| 云同步抓包、纯 Linux 复跑 | 低 | — | ★ |

## B. 给开发方的最小修复集（按性价比）

1. token 计数纳入 cache 字段（2.1）——一处聚合逻辑，收益最大
2. doctor 增一项出网可达性检查（2.4）——可打断 2.3+2.4+2.5 死胡同，成本最低
3. 错误分类区分永久/瞬时，永久错误不进无限重试（2.3）
4. 提供 goal 取消 CLI（2.5）
5. 规划容量声明值与实际对齐（2.2）
6. UI 区分 Gmail 两条通道及能力边界（8.2）

## C. 证据索引（GitHub 路径 → 结论）

| 证据 | 支撑结论 |
|---|---|
| `docs/product/wsl_goal_run_findings.md` §9 | 2.1 token/成本矛盾 |
| `docs/product/wsl_goal_run_findings.md` §13 | 2.3 错误分类真值表 |
| `docs/product/wsl_goal_run_findings.md` §14 | 第一部分 §3 注入 |
| `docs/mcp/mcp_surface_findings.md` §1-5 | 2.2、MCP §2-5 |
| `docs/mcp/mcp_surface_findings.md` §9 | MCP §6-8 relay/闸门/发信 |
| `mcp/evidence/api_auth_matrix.txt` | MCP §4 端点无认证 |
| `mcp/evidence/mcp_constants.txt` | MCP §3 枚举、§5 40 原因码 |
| `mcp/evidence/email_gate/runtime_403_block.txt` | 8.3 三重复现 |
| `mcp/*.sh` | 全部可复现取证脚本（零 token） |
| `STATUS.md` | 结论台账（A 已定论 / B 阻塞 / C 未测） |

## D. 方法论声明

数值均来自 `~/.soloco/daemon.db` 直接查询与 daemon HTTP 端点实测，不采用界面显示值。
静态结论锚定 `cli.js` sha256，**SoloCo 升级至 canary 后本报告需整体复验**。
所有证据脚本零 token 消耗，产物已脱敏（用户名/邮箱/会话/连接/goal id 均占位符化）。

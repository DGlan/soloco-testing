# SoloCo 0.2.1 测试结论台账（定论用）

> 环境：SoloCo 0.2.1 / `@soloco/client` / Node v24.18.0 / WSL2 Ubuntu 24.04 LTS
> `cli.js` sha256 `c91bd282…f71381`（升级后本台账需整体复验）
> 汇总时间：2026-07-30。本文件是「哪些能定论、哪些不能、为什么」的总账，
> 逐条证据见各 `docs/*.md` 与 `mcp/evidence/`。

台账分三档：**A 已定论**（有可复现证据，可写进结论）／
**B 环境阻塞**（设计与装置就位，只差环境条件）／**C 未测**（尚未开展）。

---

## A. 已定论（可直接写入版本结论）

| # | 结论 | 证据 | 定级 | 出处 |
|---|---|---|---|---|
| A1 | **token 计数漏计 cache 字段**，面板显示与实际差 24.7× | 21 个 run 全部超限；成本计算正确、token 计数错 | High | findings §9 / wsl_goal_run_findings §9 |
| A2 | 面板自身两数字矛盾：显示 token 反推单价超模型最高档 30× | 交叉验证 | High | 同上 |
| A3 | **永久性错误被判为瞬时**，403 → runtime_transient → 每 2 分钟无限重试 | 受控注入 grid 7 + 本次 goal 现场复现 | Medium-High | §13 / MCP §9-10 |
| A4 | **`doctor`/`runtimes` 零网络检查**，云端不可达仍报健康；本次 `runtimes` 报 login=ok 而 API 403 | grid 2/6 + 本次现场；对照 `lark-cli doctor` 有 endpoint_open/mcp | Medium | §13 / MCP §9-10 |
| A5 | **无取消 goal 的 CLI**，卡住的 goal 只能停整个 daemon（且重启自动恢复） | §7 + 本次 403 重试环 | Medium | §7 / MCP §9-10 |
| A6 | 同一错误码覆盖互斥状态（**限 managed-mcp 通道**） | `managed_mcp_auth_required` 同表两义 | Medium | §13 / MCP §4 |
| A7 | remote-mcp 通道错误建模精细（40 码），managed-mcp 落后——准确表述是「两通道建模质量悬殊」 | 源码枚举 | 认知修正 | MCP §4 |
| A8 | **不支持自建 MCP server**，provider 为编译期 zod 枚举 | `["linear","notion","sentry"]` + 上游硬编码 + CLI 无 mcp 子命令 | 事实 | MCP §2 |
| A9 | 两通道 provider 清单修正：remote=3，managed=8（此前记为各 3） | 端点实测 | 事实修正 | MCP §1 |
| A10 | **本地 MCP 端点无认证**，daemon 绑 127.0.0.1，与 daemon.db 644 同属本地面信任模型 | 认证矩阵 | Low-Medium | MCP §3 |
| A11 | **结构化输出截断的机制**：`maxTasksPerPlan=25` 但实测约 6-7 即解析失败，`evaluatorParseMissAttempts=2` | 默认值取证 + 他人 Issue #3 | High（可设计实验） | MCP §5 |
| A12 | UI 中 **Gmail 双重身份**（自研邮件通道 vs managed-MCP 卡片），界面无区分——真实可用性缺陷 | 本轮测试第一次即被误导 | Medium | MCP §9-8 |
| A13 | **managed-MCP 为云端 relay + 双向策略闸门**，策略码本地 0 次，服务端强制、本地不可见/不可绕过 | 运行时取证 RELAY_POLICY_DENIED / PROVIDER_POLICY_DRIFT | 偏正面架构结论 | MCP §9-9 |
| A14 | managed-MCP 能力是**动态 action-slug**（Composio），`tools/list` 仅 3 个元工具，严重低估能力面 | gmail tools/list | 认知修正 | MCP §9-9 |
| A15 | 自研邮件路径**闸门扎实**：agent 只能建草稿，发送需人工两步 approve→confirm-send，凭据独立 + 常量时间比较 | 端点实测 401/200 | 正面结论 | MCP §9-2 |
| A16 | 文件载体的**间接注入未致越界**（明文 + 注释伪装两式），存在逐 run 沙箱白名单等纵深防御 | inject-probe 实验 | 偏正面（含局限，见 B4） | §14 |
| A17 | 预算护栏对「0 成本失败重试环」不生效（每次 total_cost_usd=0，预算永不消耗） | 本次 --budget 2 现场 | Low（新观察） | MCP §9-10 |

---

## B. 环境阻塞 / 装置就位但未能观测

| # | 待答问题 | 卡在哪 | 解阻条件 | 出处 |
|---|---|---|---|---|
| B1 | **agent 经 MCP 发信是否被降级为草稿/需审批**（第 15 节最高价值问题） | runtime 403，goal 到不了发信步 | 为 daemon 注入 Clash 代理后重启，重跑同一 goal（装置、目标、授权均已就位） | MCP §9-10 |
| B2 | managed-MCP 已批准 action slug 全集（gmail 是否含 send 动作） | relay 响应策略闸门拦截外部枚举（**且我刻意不去绕过该安全闸门**） | 只能经真实 agent 路径观测，与 B1 同解阻 | MCP §9-9 |
| B3 | remote-mcp 完整生命周期（connected / token 过期 / capability 探测 / 4xx） | 需一次真实 OAuth，但 linear/notion/sentry **无外发副作用**，低风险可做 | 建一次性 Notion/Linear 测试工作区 | MCP §6 |
| B4 | 注入实验测的是**模型鲁棒性还是平台防御** | 注入被 executor 挡下，SoloCo 审查层未被触发 | 换弱 runtime（codex/kimi/qwen）复跑；或用网页载体（browser:none→enabled） | §14-5/14-6 |

---

## C. 未测（尚未开展）

| # | 项目 | 风险 | 备注 |
|---|---|---|---|
| C1 | 支付限额（¥500/次、¥2000/任务）是客户端还是服务端校验 | 中 | **不开真实 stripe**；只改本地 config 看服务端认不认 |
| C2 | 云同步实际传输内容（syncable 事件含任务原文与本地路径） | 中 | 需抓包，未做 |
| C3 | 纯 Linux（非 WSL）复跑关键格 | 低 | 「平台无关」目前是主张非证据 |
| C4 | 大 MCP payload 是否诱发与 A11 同类的解析失败 | 中 | 可与 A11 曲线合并成一个实验 |
| C5 | 网页内容载体的注入（B4 的一种） | 中 | browser 能力开启后 |

---

## 若现在就要对 0.2.1 定论，一句话结论

> **编排与外部集成的骨架可用，且在若干处有超出预期的纵深防御（自研邮件两步审批、
> 逐 run 沙箱白名单、云端 relay 双向策略闸门）；但可观测性与错误分类存在系统性缺陷
> ——token 计数漏 cache（24.7×）、永久错误判为瞬时并无限重试、doctor/runtimes 自检
> 与真实调用脱节、卡死 goal 无法取消。这些缺陷会在真实长跑任务里直接伤害用户对
> 成本与状态的判断。**

**最高价值的一个待办**：B1（MCP 发信闸门）——它决定 A13/A15 的正面结论是否覆盖
外发副作用这一最敏感路径，且现在只差一步代理解阻即可测出。

---

## 给开发方的最小修复集（按性价比）

1. **token 计数纳入 cache 字段**（A1/A2）——一处聚合逻辑，收益最大
2. **doctor 增一项出网可达性检查**（A4）——可打断 A3+A4+A5 那条死胡同，成本最低
3. **错误分类区分永久/瞬时**，永久错误不进无限重试（A3）
4. **提供 goal 取消 CLI**（A5）
5. **UI 区分 Gmail 两条通道及其能力边界**（A12）
6. **规划容量自洽**：`maxTasksPerPlan` 声明值与实际解析上限对齐，或提高 `evaluatorParseMissAttempts`（A11）

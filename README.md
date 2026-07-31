# soloco-testing

SoloCo（`@soloco/client`）**0.2.1** 的产品测试证据档案。

原则：可复现。别人拿到它，能把同样的实验重跑一遍；结论与原始证据同处一地，
不互相脱节。所有静态结论锚定 `cli.js` 的 sha256，**版本升级后需整体复验**。

---

## 从哪看起

| 你想要 | 看这个 |
|---|---|
| **交付版总报告**（结论+缺陷+建议） | [`REPORT.md`](REPORT.md) |
| 结论台账（已定论 / 阻塞 / 未测） | [`STATUS.md`](STATUS.md) |
| 复现某条取证 | `mcp/` 下的脚本（零 token） |
| 用 Agent 读飞书多维表格 | [`skills/lark-base-read/SKILL.md`](skills/lark-base-read/SKILL.md) |

报告分两块，对应两条测试线：

- **第一部分 · 产品通用测试** —— 编排、可观测性、错误处理、安全隔离
- **第二部分 · MCP 定向测试** —— 通道结构、接入面、relay 架构、副作用闸门

另有一条与测试并行的工具线：**Agent 操作飞书**（飞书官方 CLI + skill），见 `skills/` 与 `docs/agent/`。

---

## 目录结构

```
soloco-testing/
├── REPORT.md                 交付版总报告（两块结构）
├── STATUS.md                 结论台账（A 已定论 / B 阻塞 / C 未测）
├── docs/
│   ├── product/              第一块 · 产品通用测试
│   │   ├── wsl_setup_log.md          环境搭建全过程（含每个报错的根因与解法）
│   │   └── wsl_goal_run_findings.md  运行观察 + 错误分类真值表 + 注入实验（原始记录）
│   ├── mcp/                  第二块 · MCP 定向测试
│   │   ├── MCP_测试报告.md            MCP 定向连接报告（交付原件）
│   │   └── mcp_surface_findings.md   接入面 / relay 架构 / 邮件闸门取证
│   └── agent/                工具线 · Agent 操作飞书
│       └── lark_bitable_read_run.md  多维表格读取流程跑通记录（命令 + 报错 + 结论）
├── skills/                   自写的 Agent skill（软链到 ~/.claude/skills/）
│   └── lark-base-read/
│       ├── SKILL.md                  读多维表格的最短命令序列 + 本地环境的坑
│       ├── rows.jq                   列式返回拼成对象（带 record_id）
│       └── agg.jq                    本地分组统计（仅 has_more=false 时可用）
└── mcp/                      MCP 取证脚本与原始证据
    ├── probe_mcp_surface.sh         接入面探测（端点认证矩阵、provider 枚举、状态机）
    ├── list_managed_tools.sh        经云端 relay 只读枚举 tools/list
    ├── search_actions.sh            尝试枚举已批准 action（被 relay 响应 gate 拦下）
    ├── watch_email_gate.sh          邮件闸门测试的观测装置（before/after 比对）
    └── evidence/                    上述脚本的原始产物（已脱敏）
```

---

## 复现

前置：`soloco` 已安装、daemon 正在运行（`soloco status` 显示 running）。

```bash
# 接入面取证（零 token，不启动任何 goal）
bash mcp/probe_mcp_surface.sh          # -> mcp/evidence/

# 邮件闸门观测（零 token，不发信）
bash mcp/watch_email_gate.sh before
# ... 执行被观测动作 ...
bash mcp/watch_email_gate.sh after     # 自动比对

# 经 relay 只读枚举某 provider 的工具（零 token）
bash mcp/list_managed_tools.sh gmail
```

`mcp/` 全部脚本零 token 消耗，产物统一脱敏（用户名/邮箱/会话/连接/goal id 均占位符化）。
细节见 [`mcp/README.md`](mcp/README.md)。

---

## 环境基线

| 项 | 值 |
|---|---|
| 平台 | WSL2 / Ubuntu 24.04 LTS（内核 5.10.16） |
| Node | v24.18.0（nvm） |
| SoloCo | `@soloco/client` 0.2.1 |
| Runtime | Claude Code 2.1.220（已登录） |
| `cli.js` | sha256 `c91bd282…f71381` |

> 下一轮切换至 canary 版本后，静态结论需重跑 `mcp/probe_mcp_surface.sh` 复验校验和。

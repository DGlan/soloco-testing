# mcp/ —— MCP 接入面取证

本目录存放 SoloCo MCP 通道的取证脚本与原始产物。

与 `experiment/` 的定位一致：**脚本 + 原始数据 + 环境指纹同处一地**，
结论写在 `docs/mcp_surface_findings.md`，这里只放能重跑的东西。

## 复现

前置：`soloco` 已安装、daemon 正在运行（`soloco status` 显示 running）。

```bash
bash mcp/probe_mcp_surface.sh
```

产物写入 `mcp/evidence/`。**零 token 消耗**——脚本只做本地 HTTP 探测与
已安装包的静态读取，不启动任何 goal。

自定义输出目录：

```bash
OUT=/tmp/mcp-evidence bash mcp/probe_mcp_surface.sh
```

## 产物说明

| 文件 | 内容 | 为什么留 |
|---|---|---|
| `environment.txt` | soloco/node/OS 版本、`cli.js` sha256、监听地址 | 所有结论的有效期锚点。换版本后校验和变了，结论即需复验 |
| `api_auth_matrix.txt` | 每个端点「带/不带 token」的状态码对照 | 认证要求是推断出来的，需要可核对的原始对照 |
| `remote_mcp_connections.json` | remote-MCP 三个 provider 的完整状态 | 状态机字段（`authorization` / `capability`）的取值来源 |
| `managed_mcp_connections.json` | managed-MCP 的 8 个 provider 清单 | 修正了报告里「3 个 provider」的记述 |
| `mcp_constants.txt` | provider 枚举、scope profile、状态机、上游端点、40 个原因码 | 「不支持自建 server」这一结论的源码级证据 |
| `env_knobs.txt` | 全部 `SOLOCO_*` 环境变量 | 后续实验的旋钮清单；其中规划类旋钮见 findings 第 5 节 |
| `local_surface.txt` | `~/.soloco` 权限快照、相关表行数 | 本地数据面信任模型的证据 |

## 注意

`cli.js` 的 sha256 记录在 `environment.txt` 里。**SoloCo 升级后请重跑本脚本**——
`mcp_constants.txt` 里的枚举与默认值是编译进产物的，版本一变就可能失效。

`local_surface.txt` 只记录文件权限元数据与表行数，**不含任何凭据内容**。
`daemon.db` 以 `mode=ro` 只读打开。

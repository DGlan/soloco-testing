# 飞书多维表格读取流程 —— 跑通记录

**日期** 2026-07-31 ｜ **环境** WSL2 Ubuntu 24.04 / `@larksuite/cli` 1.0.80 / Node v24.18.0
**靶子** `产品体验与Bug反馈收集`（`soloco-ai.feishu.cn`，Base `XPXYbiigFaL5QrstToZcadSensg`，表 `问题反馈` `tbl7ZdLPKM6Cusqj`）
**性质** 全程只读，未写入任何记录。

任务来源：SoloCo 产品测试群 —— 「Agent 读取飞书多维表格的流程，大家跑一遍，总结成 Agent skill」。
产出的 skill 见 [`../../skills/lark-base-read/SKILL.md`](../../skills/lark-base-read/SKILL.md)。

---

## 0. 环境核对

```
lark-cli doctor      → 9 项全 pass
  cli_version        1.0.80（最新）
  app_resolved       cli_aae6e3f199785bc1 (feishu)
  bot_identity       ready
  user_identity      ready
  endpoint_open      https://open.feishu.cn reachable
  endpoint_mcp       https://mcp.feishu.cn/mcp reachable
```

官方 skill 27 个装在 `~/.agents/skills/`，软链到 `~/.claude/skills/`。

**secret 存放**：`~/.lark-cli/config.json` 里 appSecret 是 `{"source":"keychain"}`，无明文。
全 home 目录扫 `cli_xxx` / `appSecret` / `t-g…` / `u-…` 模式零命中，`.bash_history` 也干净。
—— 同事那条「不要把 token/secret 直接发给 Agent」已经满足。

**身份设置**：`default-as: auto`、`strict-mode: off`。
—— 同事那条「机器人和个人是两个身份」目前靠自动推断，本次全程显式 `--as user`。

---

## 1. URL → base_token

```bash
lark-cli base +url-resolve \
  --url "https://soloco-ai.feishu.cn/base/XPXYbiigFaL5QrstToZcadSensg?table=tbl7ZdLPKM6Cusqj&view=vewalVZrOs" \
  --as user
```

```json
{ "base_token": "XPXYbiigFaL5QrstToZcadSensg",
  "table_id":   "tbl7ZdLPKM6Cusqj",
  "view_id":    "vewalVZrOs",
  "input_type": "base_url",
  "resource_type": "bitable",
  "hint": { "next_step": "use +record-list to list records in the resolved table" } }
```

> 顺带纠正一个前面的误判：本机 lark-cli 登录的账号是 `用户691042`（tenant `1be6f2849d86574f`），
> `im +chat-list` 返回空、`+chat-search --query SoloCo` 命中 0，我据此判断「跨租户够不着 soloco-ai 的资源」。
> **这个判断在文档这条路上是错的** —— 上面这条 URL 解析成功，记录也读得出来。
> 群列表为空和文档可读是两回事，不能互相推。

## 2-3. Base 本体与表清单

```bash
lark-cli base +base-get   --base-token $BT --as user
lark-cli base +table-list --base-token $BT --as user
```

```
Base   产品体验与Bug反馈收集   is_advanced=false   revision=2
表     1 张 —— 问题反馈 / tbl7ZdLPKM6Cusqj（与 URL 的 table= 一致）
```

`+table-list` 返回在 `.data.tables[]`，元素是 `{id, name}`。

## 4. 字段结构（19 个）

```bash
lark-cli base +field-list --base-token $BT --table-id $TB --as user \
  --jq '[.data.fields[] | {id, name, type, opts: (.options // [] | map(.name))}]'
```

标题 / 状态 / 严重程度 / 你的姓名 / 提交时间 / 所属模块 / 设计建议（怎么设计） /
关联 GitHub Issue / 截图 · 录屏 / 问题描述（是什么） / 问题类型 / 处理结论 /
负责人 / 提交人 / 解决建议（怎么解决） / 复现步骤 / 优先级 / Agent 来源 / 环境 · 版本

选项枚举：

- **Agent 来源** Codex / Claude Code / Cursor / Gemini CLI / 其他 Agent
- **所属模块** 目标与使命 / 运行与任务 / 组织画布 / 通知与收件箱 / 设置与账号 / 客户端安装·更新 / 官网与营销页 / 其他
- **状态** 待 triage / 已确认 / 修复中 / 已解决 / 不修（已说明）/ 重复

> **坑 ①** 字段对象的 key 是 `id` / `name`，不是 `field_id` / `field_name`。
> 我第一次按 `field_id` 写 jq，结果整列 `null` 而命令返回 `ok:true` —— 静默错，不报错。

## 5. 读记录

第一次直接加 `--jq`：

```
error: --jq and --format markdown are mutually exclusive
```

> **坑 ②** `+record-list` 默认输出 markdown 表格，要用 `--jq` 必须显式 `--format json`。

加上 `--format json` 后发现返回是**列式**的：

```json
{ "data": {
    "fields":         ["标题","状态","严重程度", …],   // 表头
    "field_id_list":  ["fldYYsWlSG", …],               // 与 fields 同序
    "data":           [[…], […]],                      // 行 = 纯值数组
    "record_id_list": ["recvqR9qRWwG3B", …],           // 与行同序
    "has_more":       false } }
```

> **坑 ③** 行里没有 `record_id`，要从平行的 `record_id_list` 按下标取。
> **坑 ④** 分页是 `--offset` / `--limit`（上限 200），没有 page_token。

拼表头的 jq 又踩两下：

```
error: invalid jq expression: unexpected token "标"          ← 坑 ⑤ 中文 key 要写 ."标题"
error: from_entries cannot be applied to: array (["标题",…]) ← 坑 ⑥ 内置 jq 的 from_entries
                                                               只吃 {key,value}，不吃 [k,v] 对数组
```

（`which jq` → 没有系统 jq，只能用 lark-cli 内置的精简实现。）

最终可用的 filter，写成文件避免三层引号穿 `wsl -e bash -lc`：

```jq
.data as $d
| [ range(0; $d.data | length) as $i
    | ([$d.fields, $d.data[$i]] | transpose
       | map({key: .[0], value: .[1]}) | from_entries)
      + {record_id: $d.record_id_list[$i]} ]
```

```bash
lark-cli base +record-list --base-token $BT --table-id $TB --as user \
  --limit 200 --format json --jq "$(cat ~/lark-base-run/rows.jq)"
```

读到 **5 条，`has_more: false`**：

| record_id | 标题 | 类型 | 模块 | 严重程度 |
|---|---|---|---|---|
| recvqR9qRWwG3B | 【示例·可删除】组织画布拖动节点后位置回弹到原处 | Bug | 组织画布 | 严重 |
| rec27Td2hCJ35a | 测试一下 | 体验问题 | 客户端安装/更新 | 轻微 |
| rec27Td5ek9Xq1 | 测试 | 体验问题 | 其他 | 轻微 |
| rec27TgfYM2UQC | UI 里 Gmail 有两个同名入口（自研邮件通道 vs MCP 连接），界面不区分，容易走错 | 体验问题 | 其他 | 一般 |
| rec27TwP42hAyY | 纯对话请求已正确回复，但因未生成任务计划而执行失败 | Bug | 目标与使命 | 严重 |

## 6. 统计 —— 云端聚合被拒

按官方 skill 的规则，统计应该走云端 `+data-query` 而不是本地算。实际：

```bash
lark-cli base +data-query --base-token $BT --as user --dsl '<按 severity 分组 count>'
→ { "code": 91403, "message": "you don't have permission" }
```

先排除是 DSL 写法问题 —— 换成最简 DSL（去掉 dimensions、只留一个 count）：

```
→ 同样 91403
```

> **坑 ⑦（本次最有价值的一条）** 同一个 Base、同一个身份，
> **`+record-list` 读得出来，`+data-query` 被拒**。权限是分开的。

另外 `--dsl` 不支持 `@file`（`--filter-json` 支持），第一次传 `@/path/q.json` 报
`invalid character '@' looking for beginning of value`，必须内联 `--dsl "$(cat q.json)"`。

**降级处理**：官方 skill 明确写了 91403 不要循环换身份重试，所以没试 `--as bot`
（本机 bot 属于个人租户的自建应用，对 soloco-ai 的 Base 更不可能有权限）。
改用全量 `record-list` + 本地统计 —— 这里成立的前提是 **`has_more=false`，5 条已是全量**；
如果 `has_more=true` 还这么算，就是拿一页冒充全量。

```
读取范围：5 条，has_more=false

按类型      Bug 2 ｜ 体验问题 3
按严重程度  严重（主流程受影响）2 ｜ 轻微（观感/文案）2 ｜ 一般（有绕过办法）1
按模块      其他 2 ｜ 客户端安装/更新 1 ｜ 目标与使命 1 ｜ 组织画布 1
按状态      全部为空（5 条都还没 triage）
```

---

## 附：本次未解决 / 待办

| 项 | 状态 |
|---|---|
| `drive files list` 缺 `space:document:retrieve` | 未补。后果：不能按名字找表，只能拿现成链接进 |
| `drive +search` 缺 `search:docs:read` | 未补。同上。补需要人工走设备码授权 |
| `+data-query` 91403 | 未解。要么找表 owner 提权，要么固定走 record-list 降级路径 |
| `default-as: auto` / `strict-mode: off` | 未改。建议显式写死身份，别让 CLI 猜 |
| 自建应用做定时机器人（每日抓竞品发群） | 未做。同事原话是「可以了解一下」，属加分项 |
| SoloCo 飞书群 | 尚未加入，`im +chat-list` 为空 |

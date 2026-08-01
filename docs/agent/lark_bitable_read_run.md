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

---

# 第二轮：收尾遗留项

## 7. `default-as` 改成显式身份

先差点做错一件事：我把 `strict-mode` 描述成「身份不明确就报错的消歧保护」，并据此建议开启。
读 `--help` 才发现**完全不是**：

```
bot   只允许机器人身份（用户命令被隐藏）
user  只允许个人身份（机器人命令被隐藏）
off   不限制（默认）
```

是二选一锁死。设成 `user` 会把机器人命令整个藏掉，直接堵死后面「自建应用做群机器人」那条路。
CLI 的 help 里还专门写了 `DO NOT switch without explicit user confirmation — never run on your own initiative`。

真正对症的是另一个：

```bash
lark-cli config default-as user      # auto → user
# strict-mode 保持 off
```

复测：不带 `--as` 的命令返回 `"identity": "user"` ✓；`--as bot` 仍可用（返回权限错而非「命令不存在」）✓。

> **顺带发现**：`--as bot` 读 Base 报 `99991672 app_scope_not_applied: app cli_aae6e3f199785bc1 has not applied for base:app:read`。
> 而用户身份早就有 `base:app:read`。
> —— **用户 OAuth scope 和应用 scope 是两套东西**，`auth login` 补不了应用 scope，得去开发者后台申请。
> 以后要做群机器人，这一步跑不掉。

## 8. 补 scope —— 差点把环境搞崩

`auth login --help` 里那句 `--scope: Combines additively with --domain/--recommend`，
说的是**和另外两个 flag 叠加**，没说和已有授权叠加。设备流拿到的新 token 只含本次请求的 scope。

所以照 error hint 直接跑：

```bash
lark-cli auth login --scope "search:docs:read space:document:retrieve"
```

**会把现有 138 项冲成 2 项。** 改成先抓现有 scope 做并集（`auth status` 不支持 `--jq`，用 python 解）：

```
现有: 138  →  新增: search:docs:read, space:document:retrieve  →  请求: 140 项 / 3111 字符
```

`--no-wait --json` 拿到验证 URL 交给人点，再 `--device-code` 收尾：

```json
{ "event": "authorization_complete",
  "newly_granted": ["search:docs:read", "space:document:retrieve"],
  "missing": [] }
```

复测 `auth status` → **140 项，两个新 scope 都在**。

`drive +search --query "Bug反馈"` 现在能用了，直接命中目标表：

```json
{ "doc_types": "BITABLE", "token": "XPXYbiigFaL5QrstToZcadSensg",
  "owner_name": "谢上子", "is_cross_tenant": true,
  "url": "https://soloco-ai.feishu.cn/base/XPXYbiigFaL5QrstToZcadSensg" }
```

`is_cross_tenant: true` —— 再次坐实第 1 节那个更正：跨租户共享是成立的。

> 二维码的坑：`auth qrcode` 的 URL 是**位置参数**不是 `--url`，`--output` 只收当前目录下的相对路径。

**回归**：读取流程（不带 `--as`，走新默认）结果与第一轮完全一致 ✓

## 9. 定位 91403 —— 自建一张表做对照组

补完 scope，`+data-query` 打那张表**仍然 91403**。说明不是 scope 的事。

但光在出问题的表上反复试，分不清是「我不会用」还是「这张表没给权限」。
**建一张自己拥有的表当对照组**，把变量切干净：

```bash
lark-cli base +base-create --name "data-query 权限对照测试（可删）" \
  --table-name "样例" --fields "$(cat fields.json)"
# → YIzKbO39zaHLpKs0OSmcysO1n1g @ hcnwtmkqrnl9.feishu.cn（自己的租户）

lark-cli base +record-batch-create --base-token <新> --table-id <新> \
  --json '{"create_records":[…5 条…]}'
```

> 坑：`--json` 是 `{"create_records":[{字段:值}]}` **扁平映射**，不是 `{"fields":{…}}`。

拿**完全同形**的最简 DSL 打自己的表：

```json
{ "ok": true, "data": { "main_data": [ { "cnt": { "value": 5 } } ] } }
```

**对照结论**：同一身份、同形 DSL —— 自己的表 `ok:true`，谢上子的表 91403。
→ 能力、scope、DSL 写法**全都没问题**，91403 纯粹是那张表的资源级权限没给。
自己再怎么调都是白费，只能找 owner 提权。

再验完整 DSL（分组 + count + sum + 排序）：

```json
{"main_data":[
  {"module":{"value":"安装"}, "cnt":{"value":2}, "mins":{"value":"65.00"}},
  {"module":{"value":"其他"}, "cnt":{"value":2}, "mins":{"value":"15.00"}},
  {"module":{"value":"画布"}, "cnt":{"value":1}, "mins":{"value":"30.00"}}]}
```

> 返回形状：结果在 `.data.main_data[]`，每个值包一层 `{"value": …}`，
> 且**聚合数值是字符串** —— `sum` 出来是 `"65.00"` 不是 `65`，要再算得先转数字。

---

## 附：状态台账

| 项 | 状态 |
|---|---|
| `search:docs:read` / `space:document:retrieve` | ✅ 已补，140 项，`missing: []`，`drive +search` 实测可用 |
| `default-as` | ✅ `auto` → `user`。`strict-mode` 有意保持 `off`（见第 7 节） |
| `+data-query` 91403 | ⚠️ **已定位，未解决** —— 确认是那张表的资源级权限，需 owner（谢上子）提权 |
| 应用 scope（`--as bot` 读 Base） | ❌ 未申请。要做群机器人必须先去开发者后台申请 |
| 自建应用做定时机器人（每日抓竞品发群） | ❌ 未做。同事原话是「可以了解一下」，属加分项 |
| SoloCo 飞书群 | ❌ 尚未加入，`im +chat-list` 为空 |
| 对照测试用的 Base | 🧹 `YIzKbO39zaHLpKs0OSmcysO1n1g`（名字带「可删」），留着复现用，不需要了可删 |

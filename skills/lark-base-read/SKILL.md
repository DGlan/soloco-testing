---
name: lark-base-read
version: 1.1.0
description: "在 WSL + lark-cli 环境下读取飞书多维表格（Base）的最短可靠命令序列，以及本地环境特有的坑：record-list 的列式 JSON、内置 jq 的限制、data-query 的资源级权限、补 scope 是覆盖而非追加、用户 scope 与应用 scope 是两套。官方 lark-base skill 讲『怎么用 Base API』，本 skill 只讲『在我们这套环境里怎么一次跑对』。字段/公式/写入/仪表盘一律转 lark-base。"
metadata:
  requires:
    bins: ["lark-cli"]
  cliHelp: "lark-cli base --help"
  verified: "2026-07-31 / lark-cli 1.0.80 / WSL2 Ubuntu 24.04"
---

# lark-base-read

## 何时使用

- 要**读**一张飞书多维表格：拿到链接，取出字段结构、记录、或做统计。
- 遇到 `+record-list` 输出解析不出来、`--jq` 报错、`91403`、`missing_scope` 时的排障。

**不要用本 skill**：写记录、建字段、公式 / lookup、表单、仪表盘、workflow、角色权限——全部转官方 `lark-base`，它是这些主题的 SSOT。本 skill 不复制它的内容。

## 环境前提（本地特有）

- 可执行文件名是 **`lark-cli`**，不是 `lark`。npm 包是 `@larksuite/cli`。
- 整套装在 **WSL**，Windows 侧没有。从 Git Bash / Windows 侧调用必须先：

  ```bash
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
  wsl -e bash -lc '<命令>'
  ```

  不加这两个变量，MSYS 会把参数里的 `/` 路径改写掉。
- 系统里**没有独立的 jq**。所有 `--jq` 走 lark-cli 内置的精简实现，见下面「内置 jq 的两个限制」。
- `config default-as` 已设为 `user`（`strict-mode` 保持 `off`）。不写 `--as` 就走个人身份；需要机器人时显式 `--as bot`。本文档的示例仍保留 `--as user`，写出来不吃亏。

## 读取流程（六步，已实测跑通）

以 `产品体验与Bug反馈收集` 为例，全程只读。

```bash
BT=<base_token>; TB=<table_id>

# 1. URL → base_token / table_id / view_id。永远从这一步开始，
#    不要把整条 URL 或 wiki token 直接塞给 --base-token。
lark-cli base +url-resolve --url "<粘贴的完整链接>" --as user

# 2. 确认 Base 本体（名称、是否高级权限、真实 url）
lark-cli base +base-get --base-token $BT --as user

# 3. 表清单。注意返回是 .data.tables[]，元素是 {id, name}
lark-cli base +table-list --base-token $BT --as user

# 4. 字段结构。元素是 {id, name, type, options}，
#    不是 field_id / field_name——写 jq 时最容易踩这个
lark-cli base +field-list --base-token $BT --table-id $TB --as user \
  --jq '[.data.fields[] | {id, name, type, opts: (.options // [] | map(.name))}]'

# 5. 读记录（见下节，必须 --format json + 拼表头）
# 6. 统计（优先云端 +data-query；被拒时按「权限差」一节降级）
```

## 第 5 步：record-list 的两个坑

**坑一：默认输出是 markdown，和 `--jq` 互斥。**

```
$ lark-cli base +record-list ... --jq '...'
error: --jq and --format markdown are mutually exclusive
```

要用 `--jq` 就必须同时 `--format json`。

**坑二：`--format json` 是列式的，不是对象数组。**

```json
{ "data": {
    "fields":         ["标题", "状态", ...],     // 表头
    "field_id_list":  ["fldYYsWlSG", ...],       // 与 fields 同序
    "data":           [[...], [...]],            // 行 = 值数组，与 fields 同序
    "record_id_list": ["recvqR9qRWwG3B", ...],   // 与行同序，行内没有 record_id
    "has_more":       false
} }
```

行里**不带 `record_id`**，要从平行的 `record_id_list` 按下标取。拼成对象的可复用 filter：

```jq
.data as $d
| [ range(0; $d.data | length) as $i
    | ([$d.fields, $d.data[$i]] | transpose
       | map({key: .[0], value: .[1]}) | from_entries)
      + {record_id: $d.record_id_list[$i]} ]
```

分页是 `--offset` / `--limit`（`--limit` 上限 200），**没有 page_token**。判断是否读全看 `has_more`。

## 内置 jq 的两个限制

1. **`from_entries` 只吃 `{key, value}` 对象**，不吃标准 jq 支持的 `[k, v]` 对数组。
   所以上面必须显式 `map({key: .[0], value: .[1]})`。
2. **中文 key 不能裸写**，`.标题` 会报 `unexpected token "标"`。必须 `."标题"`。

filter 一长就别硬塞进命令行（三层引号穿 `wsl -e bash -lc` 必翻车）。写成文件再展开：

```bash
lark-cli base +record-list ... --format json --jq "$(cat ~/lark-base-run/rows.jq)"
```

## 第 6 步：data-query 与 record-list 的权限差

**实测：同一个 Base、同一个身份，`+record-list` 能读，`+data-query` 直接 `91403 you don't have permission`。**

**定位方法（重要）—— 建一张自己的表当对照组。** 光在出问题的表上反复试，分不清是"命令不会用"还是"这张表没给权限"。三步就能切干净：

```bash
# 1. 建一张自己拥有的表
lark-cli base +base-create --name "对照测试（可删）" --table-name "样例" \
  --fields '[{"type":"text","name":"标题"},{"type":"select","name":"模块","multiple":false,"options":[{"name":"A"},{"name":"B"}]},{"type":"number","name":"耗时"}]'

# 2. 灌几条数据
lark-cli base +record-batch-create --base-token <新base> --table-id <新table> \
  --json '{"create_records":[{"标题":"x","模块":"A","耗时":30}]}'

# 3. 拿同形的 DSL 打自己的表
```

实测结论：**同形 DSL 在自己的表上 `ok:true`，在别人的表上 91403** → 能力、scope、DSL 写法全没问题，纯粹是那张表的资源级权限。这时候只能找表 owner 提权，自己再怎么调都是白费。

处理方式：

- **不要换身份重试。** 91403 是资源级拒绝，`--as bot` 只会再失败一次。
- 降级到 `+record-list --limit 200` 全量读 + 本地统计，**但只有 `has_more=false` 时这个结论才成立**。`has_more=true` 还本地统计，就是拿一页数据冒充全量。
- 报结论时把范围写出来：读了几条、`has_more` 是什么。

**返回形状**（实测）：结果在 `.data.main_data[]`，每个值都包了一层 `{"value": …}`，且**聚合数值是字符串**：

```json
{"data":{"main_data":[
  {"module":{"value":"安装"}, "cnt":{"value":2}, "mins":{"value":"65.00"}}
]}}
```

`sum` 出来是 `"65.00"` 不是 `65`。要再算就得先转数字。

另：`--dsl` **不支持 `@file`**（`--filter-json` 支持）。DSL 必须内联，用 `--dsl "$(cat q.json)"`。

## 补 scope：**重新授权是覆盖，不是追加**

这是最容易把环境搞崩的一步。设备流拿到的新 token **只包含本次请求的 scope**，不会跟已有的合并。

```bash
# ❌ 这么写会把现有 138 项冲成 2 项，除了搜索什么都干不了了
lark-cli auth login --scope "search:docs:read space:document:retrieve"
```

正确做法：**先把现有 scope 抓出来，做并集再请求**。

```bash
# 1. 备份
cp ~/.lark-cli/config.json ~/config.json.bak

# 2. 抓现有 scope（注意 auth status 不支持 --jq，得自己解 JSON）
lark-cli auth status | python3 -c "
import json,sys; print(json.load(sys.stdin)['identities']['user']['scope'])" > cur.txt

# 3. 并集
python3 -c "
cur=open('cur.txt').read().split()
new=['search:docs:read','space:document:retrieve']
open('req.txt','w').write(' '.join(sorted(set(cur)|set(new))))"

# 4. 发起（--no-wait 拿 URL，别阻塞）
lark-cli auth login --no-wait --json --scope "$(cat req.txt)"
# → 把 verification_url 给人去浏览器点，10 分钟内有效

# 5. 人点完后收尾
lark-cli auth login --device-code "<上一步返回的 device_code>"
```

第 5 步返回里看 `newly_granted` 和 `missing`：`missing: []` 才算干净。

二维码：`lark-cli auth qrcode <url> --output x.png`。URL 是**位置参数不是 `--url`**，且 `--output` 只接受当前目录下的相对路径。

## 两套 scope 不要混

- **用户 OAuth scope** —— `auth login` 授权的那批，管 `--as user`。
- **应用 scope** —— 要去开发者后台申请，管 `--as bot`。

实测 `--as bot` 读 Base 报 `99991672 app_scope_not_applied: has not applied for the required scope(s): base:app:read`，即使用户身份早就有 `base:app:read`。两者互不相干，`auth login` 补不了应用 scope。要做群机器人得先去后台申请。

## 常见错误速查

| 现象 | 原因 / 处理 |
|---|---|
| `--jq and --format markdown are mutually exclusive` | 补 `--format json` |
| `from_entries cannot be applied to: array` | 内置 jq 限制，改 `map({key:.[0], value:.[1]})` |
| `unexpected token "标"` | 中文 key 要写成 `."标题"` |
| `--dsl invalid JSON: invalid character '@'` | `--dsl` 不吃 `@file`，改 `"$(cat file)"` |
| 字段 jq 全是 `null` | 字段对象的 key 是 `id`/`name`，不是 `field_id`/`field_name` |
| `91403` | 资源级无权限。先用「自建对照表」证明不是自己写错，再找 owner 提权 |
| `99991672 app_scope_not_applied` | 这是**应用 scope**不是用户 scope，`auth login` 补不了，要去开发者后台申请 |
| `missing_scope` | 看 error.hint，但**别照 hint 直接跑**——它只列缺的那几个，照抄会把现有授权冲掉，按上节做并集 |
| `param baseToken is invalid` | 没走 `+url-resolve`，把 URL 或 wiki token 当 base_token 了 |
| `+record-batch-create` 字段报错 | `--json` 是 `{"create_records":[{字段:值}]}` 扁平映射，不是 `{"fields":{…}}` |
| `auth status --jq` 报 invalid_argument | `auth` 系列不支持 `--jq`，用 python 解 JSON |

## 安全约定

- **不要把 app secret / token 贴给 Agent。** 走 `lark-cli` 登录，secret 存在 keychain（`config.json` 里应该只看到 `{"source":"keychain"}`），Agent 只调 CLI。
- 机器人和个人是**两个身份**：操作个人文档、日历、个人可见的表用 `--as user`；需要应用身份的场景才 `--as bot`。
- 已把 `config default-as` 设为 `user`（原为 `auto`），不再让 CLI 猜身份；需要机器人时显式 `--as bot` 覆盖。
- `config strict-mode` 保持 `off`。注意它**不是**消歧保护，而是二选一锁死（设 `user` 会把机器人命令整个隐藏），会挡住以后做群机器人。CLI 自己也标了「这是安全策略，不得自作主张切换」。

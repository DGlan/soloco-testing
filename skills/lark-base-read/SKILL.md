---
name: lark-base-read
version: 1.0.0
description: "在 WSL + lark-cli 环境下读取飞书多维表格（Base）的最短可靠命令序列，以及本地环境特有的坑：身份显式化、record-list 的列式 JSON、内置 jq 的限制、data-query 与 record-list 的权限差。官方 lark-base skill 讲『怎么用 Base API』，本 skill 只讲『在我们这套环境里怎么一次跑对』。字段/公式/写入/仪表盘一律转 lark-base。"
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
- `config default-as` 目前是 `auto`、`strict-mode` 是 `off`。**每条命令显式写 `--as user`**，不要依赖自动推断。

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

**实测：同一个 Base、同一个身份，`+record-list` 能读，`+data-query` 直接 `91403 you don't have permission`。** 换最简 DSL（去掉 dimensions、只留一个 count）仍然 91403，所以是权限不是 DSL 写法。

处理方式：

- **不要换身份重试。** 91403 是资源级拒绝，`--as bot` 只会再失败一次。
- 降级到 `+record-list --limit 200` 全量读 + 本地统计，**但只有 `has_more=false` 时这个结论才成立**。`has_more=true` 还本地统计，就是拿一页数据冒充全量。
- 报结论时把范围写出来：读了几条、`has_more` 是什么。

另：`--dsl` **不支持 `@file`**（`--filter-json` 支持）。DSL 必须内联，用 `--dsl "$(cat q.json)"`。

## scope 缺失

已知缺两个，都不影响「有链接就能读」：

| 命令 | 缺的 scope |
|---|---|
| `drive files list` | `space:document:retrieve` |
| `drive +search` | `search:docs:read` |

后果：**没法按名字搜表，只能拿现成链接进**。要补需要重新走一次设备码授权（会阻塞并吐一个验证 URL，要人去浏览器点）：

```bash
lark-cli auth login --scope "search:docs:read space:document:retrieve"
```

`base:app:read` / `base:table:read` / `base:record:read` 都已授权，读取本身不缺权限。

## 常见错误速查

| 现象 | 原因 / 处理 |
|---|---|
| `--jq and --format markdown are mutually exclusive` | 补 `--format json` |
| `from_entries cannot be applied to: array` | 内置 jq 限制，改 `map({key:.[0], value:.[1]})` |
| `unexpected token "标"` | 中文 key 要写成 `."标题"` |
| `--dsl invalid JSON: invalid character '@'` | `--dsl` 不吃 `@file`，改 `"$(cat file)"` |
| 字段 jq 全是 `null` | 字段对象的 key 是 `id`/`name`，不是 `field_id`/`field_name` |
| `91403` | 资源级无权限。不换身份重试，按上面降级 |
| `missing_scope` | 看 error.hint 里给的 `auth login --scope`，需要人工浏览器授权 |
| `param baseToken is invalid` | 没走 `+url-resolve`，把 URL 或 wiki token 当 base_token 了 |

## 安全约定

- **不要把 app secret / token 贴给 Agent。** 走 `lark-cli` 登录，secret 存在 keychain（`config.json` 里应该只看到 `{"source":"keychain"}`），Agent 只调 CLI。
- 机器人和个人是**两个身份**：操作个人文档、日历、个人可见的表，用 `--as user`；需要应用身份的场景才 `--as bot`。当前 `default-as=auto`，建议显式写死，别让它猜。

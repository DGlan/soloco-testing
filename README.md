# soloco-testing

SoloCo 产品测试用的脚本、实验数据与环境搭建记录。

这个仓库存放**测试工具本身和它产出的原始数据**，不存放测试结论 —— 结论走单独的测试报告。
放在这里的东西只有一个标准：**别人拿到它，能把同样的实验重跑一遍。**

---

## 仓库结构

```
soloco-testing/
├── experiment/                  可重复性压力测试
│   ├── run_experiment.py        实验执行器
│   ├── tasks.json               任务定义 + 实验协议
│   ├── experiment_log.csv       每轮一行的结构化结果
│   ├── answers.md               人工判读用的答案汇总
│   └── transcripts/             每轮完整的原始 JSON
└── docs/
    └── wsl_setup_log.md         WSL2 测试环境搭建全过程（含每个报错的根因与解法）
```

---

## experiment/ —— 可重复性压力测试

### 这个实验测什么

用 **headless 模式的 Claude Code**（`claude -p`）去驱动一个本地 RAG 问答系统，
同一个问题重复跑 5 轮，观察：

* **答案是否稳定** —— 同样的输入，多轮之间答案会不会漂
* **token 消耗是否稳定** —— 每轮实际烧多少 token
* **失败模式** —— 出错时是怎么错的

设计上刻意**串行**执行、**固定模型**、**固定 prompt 模板**，把变量压到最少。

### 任务设计

`tasks.json` 里定义了 3 个难度梯度的任务，每个跑 5 轮：

| task_id | 难度 | 考察点 |
|---|---|---|
| `T1_simple` | simple | 单 chunk 事实检索 |
| `T2_medium` | medium | 需要定位到特定章节的技术细节 |
| `T3_hard` | hard_multihop | 跨文档综合；中文问英文语料，预期触发 rewrite 循环 |

每个任务带 `expected_keywords`，供人工判读时作为参照。
`tasks.json` 里的 `protocol` 段落记录了完整实验协议（轮数、模型、超时、并发策略、token 口径），
**协议和数据放在一起**，避免日后对不上。

### token 口径（重要）

这是最容易出错的地方，单独说明。

Claude Code 的 `--output-format json` 返回的 `usage` 有四个字段：

```
input_tokens                  本次真正发给 API 的 input
cache_creation_input_tokens   写入 prompt cache 的部分
cache_read_input_tokens       从 prompt cache 读取的部分
output_tokens                 输出
```

本实验采用的口径是：

```python
input_tokens = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
total_tokens = input_tokens + output_tokens
```

即 **把 cache 的两个桶都算进 input**，因为它们都真实计入配额消耗。
只取 `usage.input_tokens` 会严重低估实际用量。

CSV 里存的是合并后的值，**四个原始字段完整保留在 `transcripts/<run_id>.json` 的 `usage_raw` 里**，
口径有争议时可以从原始数据重算，不用重跑实验。

---

## 复现步骤

### 0. 前提

| 依赖 | 要求 | 说明 |
|---|---|---|
| OS | Linux / WSL2 | 见 [docs/wsl_setup_log.md](docs/wsl_setup_log.md) |
| Python | 3.10+ | 只用标准库，无第三方依赖 |
| Claude Code | 已安装且**已登录** | `claude --version` 能出版本号 |
| 被测 RAG 项目 | 含 `graph.py`，可用 `python graph.py "问题"` 调用 | **不在本仓库内**，见下 |

> ⚠️ **被测的 RAG 项目不在这个仓库里。** 它是一个独立项目，本仓库只提供驱动它的测试脚本。
> 没有它的话，脚本会在启动时明确报错退出，而不是跑出一堆空数据。

### 1. 取得仓库

```bash
git clone git@github.com:<你的用户名>/soloco-testing.git
cd soloco-testing/experiment
```

### 2. 指向被测项目

脚本默认在仓库同级目录找 `rag-qa/`。不在那儿就显式指定：

```bash
export RAG_DIR=/绝对路径/到/rag-qa
```

### 3. 先跑单轮试水

**不要一上来就跑全量。** 先用 pilot 模式跑 1 轮，确认链路通：

```bash
python3 run_experiment.py T1_simple:1
```

启动时会先把解析结果打印出来，核对无误再继续：

```
claude   : /usr/local/bin/claude
rag dir  : /home/<user>/rag-qa
inner py : .venv/bin/python
model    : claude-sonnet-5
```

### 4. 跑全量

```bash
python3 run_experiment.py
```

15 轮（3 任务 × 5 轮）串行执行，每轮之间固定 sleep 2 秒。

**支持断点续跑**：脚本启动时会读 `experiment_log.csv`，跳过 `run_id` 已存在的轮次。
中途被打断（超时、配额耗尽、Ctrl-C）后直接重新执行同一条命令即可，不会重复消耗已完成轮次的 token。

> 想从头重跑：先把 `experiment_log.csv`、`answers.md`、`transcripts/` 移走或删掉，
> 否则新数据会**追加**到旧数据后面。

### 5. 人工判读

脚本**不自动判定对错**。`experiment_log.csv` 的 `success` 和 `failure_mode` 两列留空，
由人对着 `answers.md` 逐条填写。

这是有意的设计：答案正确性涉及语义判断，自动判定会引入新的误差源，
而这个实验测的恰恰是稳定性 —— 判定标准本身必须稳定。

### 可调参数

全部通过环境变量覆盖，不用改代码：

| 变量 | 默认值 | 作用 |
|---|---|---|
| `RAG_DIR` | `../../rag-qa` | 被测项目目录 |
| `CLAUDE_BIN` | PATH 里的 `claude` | Claude Code 可执行文件 |
| `RAG_PYTHON` | 自动探测 venv | 告诉 agent 用哪个解释器跑 `graph.py` |
| `EXP_MODEL` | `claude-sonnet-5` | 固定模型以保证可比性 |
| `EXP_ROUNDS` | `5` | 每个任务的轮数 |
| `EXP_MAX_TURNS` | `6` | 单轮 agent 最大回合数 |
| `EXP_TIMEOUT_S` | `300` | 单轮超时（秒） |

代理按需在 shell 里 export 即可（`HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`），
脚本原样继承，不做任何硬编码。

---

## 数据格式

### experiment_log.csv

UTF-8 with BOM（方便 Excel 直接打开不乱码）。

| 列 | 含义 |
|---|---|
| `run_id` | 轮次唯一标识，形如 `T1_simple_r3` |
| `task_id` | 对应 `tasks.json` 里的任务 |
| `timestamp` | 该轮开始时间，ISO 8601 |
| `input_tokens` | 合并口径的 input（含两个 cache 桶） |
| `output_tokens` | 输出 token |
| `total_tokens` | input + output |
| `duration_seconds` | 该轮墙钟耗时 |
| `success` | **人工填写** |
| `failure_mode` | **人工填写** |

### transcripts/<run_id>.json

每轮的完整记录，CSV 是它的摘要。关键字段：

| 字段 | 含义 |
|---|---|
| `usage_raw` | API 返回的原始 usage 四字段，未经合并 |
| `answer` | agent 回报的答案全文 |
| `num_turns` | 实际用了几个回合 |
| `total_cost_usd` | API 报告的成本 |
| `exit_code` / `timed_out` | 进程结束状态 |
| `stderr_tail` | stderr 末尾 2000 字符 |
| `subtype` | 异常时标记失败类型 |

### 关于已提交的这份数据

仓库里这份 `experiment_log.csv` 是**不完整的**：15 轮里只有前 6 轮产生了有效 token 数据，
后续轮次因为运行途中账号配额耗尽而全部返回 0 token。
每一行的具体情况记在该行的 `failure_mode` 列里。

保留这份不完整数据而不是删掉重跑，是因为**失败轮次本身也是数据** ——
后 10 轮那种"约 3 秒退出、0 token"的特征是可识别的失败签名，有诊断价值。

`transcripts/pilot_r0_discarded_gbk_mojibake.json` 是一个**被废弃的预跑轮次**，
故意保留：当时子进程的中文输出经管道传递时被非 UTF-8 的默认编码破坏成了 U+FFFD 乱码。
`run_experiment.py` 里强制设置 `PYTHONIOENCODING=utf-8` 和 `PYTHONUTF8=1` 就是为了堵这个问题，
这份废弃数据是那个决定的依据。

---

## docs/wsl_setup_log.md

在受支持平台（WSL2 + Ubuntu 24.04）上从零搭测试环境的完整记录。

不是流水账 —— 每个报错都记了**原文、根因判断、解法、耗时**，包括几个不那么显然的：

* DISM 退出码 3010 不是失败（是"需重启"），装机脚本容易误判
* `wsl.exe` 输出是 UTF-16LE，直接走管道取会拿到乱码，字符串断言会静默失配
* 一次**预判失误**及其成因（用了给出不完整视图的诊断命令）—— 如实记录，没有抹掉
* Windows 侧遗留的 npm shim 通过 PATH 注入污染 WSL，且**只在非登录 shell 下发作**
  （也就是测试脚本运行的场景）

搭出来的环境版本基线记在该文档末尾，是上面复现步骤的参照环境。

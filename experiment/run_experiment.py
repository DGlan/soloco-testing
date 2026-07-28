# -*- coding: utf-8 -*-
"""Repeatability stress test: 3 QA tasks x 5 rounds via headless Claude Code.

Each round: `claude -p` drives `python graph.py "<q>"` inside the RAG project and
reports the RAG answer verbatim. Usage comes from the --output-format json result
(API ground truth). Sequential on purpose — single machine, no concurrency.

Nothing here is machine-specific: every path is resolved from the environment or
auto-detected, so the script runs on any host that has `claude` on PATH. See
README.md for the full list of knobs.

Outputs (all next to this file):
  experiment_log.csv    one row per round (success/failure_mode filled by human pass)
  transcripts/          full result JSON per round (raw usage breakdown, answer text)
  answers.md            answers collected for the human judgment pass
"""
import csv
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
CSV_PATH = HERE / "experiment_log.csv"
TRANSCRIPTS = HERE / "transcripts"
ANSWERS_MD = HERE / "answers.md"

# --- configuration (all overridable by environment) -------------------------
# Directory of the RAG project under test; must contain graph.py.
RAG_DIR = Path(os.environ.get("RAG_DIR", HERE.parent.parent / "rag-qa")).resolve()

MODEL = os.environ.get("EXP_MODEL", "claude-sonnet-5")
MAX_TURNS = int(os.environ.get("EXP_MAX_TURNS", "6"))
TIMEOUT_S = int(os.environ.get("EXP_TIMEOUT_S", "300"))
ROUNDS = int(os.environ.get("EXP_ROUNDS", "5"))

CSV_FIELDS = [
    "run_id", "task_id", "timestamp",
    "input_tokens", "output_tokens", "total_tokens",
    "duration_seconds", "success", "failure_mode",
]


def resolve_claude():
    """Locate the Claude Code executable.

    CLAUDE_BIN wins; otherwise take whatever is on PATH. Resolving this up front
    means a missing/ambiguous binary fails loudly here instead of producing a run
    of empty rows.
    """
    explicit = os.environ.get("CLAUDE_BIN")
    if explicit:
        if not Path(explicit).exists():
            sys.exit(f"CLAUDE_BIN points at a missing file: {explicit}")
        return explicit
    found = shutil.which("claude")
    if not found:
        sys.exit("`claude` not found on PATH. Install Claude Code or set CLAUDE_BIN.")
    return found


def resolve_inner_python():
    """Pick the interpreter the agent is told to run graph.py with.

    Prefers a virtualenv inside RAG_DIR (layout differs per platform), falls back
    to a bare `python`. Returned as a string because it is interpolated into the
    prompt, not executed by us.
    """
    explicit = os.environ.get("RAG_PYTHON")
    if explicit:
        return explicit
    for rel in (".venv/bin/python", ".venv/Scripts/python.exe"):
        if (RAG_DIR / rel).exists():
            return rel
    return "python"


CLAUDE = resolve_claude()
INNER_PYTHON = resolve_inner_python()

PROMPT_TEMPLATE = (
    "运行这条命令并等待它完成：{python} graph.py \"{query}\"\n"
    "然后把它输出的最终答案一字不差地报告给我。\n"
    "规则：不要自己回答这个问题，不要修改任何文件，不要运行其他命令。"
)


def build_env():
    """Environment for the child `claude` process.

    Proxy settings are inherited from the caller rather than hardcoded — export
    HTTPS_PROXY/HTTP_PROXY/NO_PROXY in your shell if your network needs them.

    PYTHONIOENCODING/PYTHONUTF8 are NOT optional: graph.py prints Chinese through
    a pipe, and on a non-UTF-8 default (e.g. Windows GBK) the relayed answer comes
    back as U+FFFD mojibake. A pilot round was discarded to this exact cause; the
    transcript is kept as transcripts/pilot_r0_discarded_gbk_mojibake.json.
    """
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    return env


def run_round(run_id, task):
    prompt = PROMPT_TEMPLATE.format(python=INNER_PYTHON, query=task["query"])
    cmd = [
        CLAUDE, "-p", prompt,
        "--output-format", "json",
        "--model", MODEL,
        "--max-turns", str(MAX_TURNS),
        "--allowedTools", "Bash",
    ]
    t0 = time.monotonic()
    try:
        proc = subprocess.run(
            cmd, cwd=str(RAG_DIR), env=build_env(),
            capture_output=True, timeout=TIMEOUT_S,
        )
        timed_out = False
    except subprocess.TimeoutExpired as exc:
        proc = exc
        timed_out = True
    duration = round(time.monotonic() - t0, 1)

    stdout = (proc.stdout or b"").decode("utf-8", errors="replace")
    stderr = (proc.stderr or b"").decode("utf-8", errors="replace")

    record = {
        "run_id": run_id,
        "task_id": task["task_id"],
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "duration_seconds": duration,
        "timed_out": timed_out,
        "exit_code": None if timed_out else proc.returncode,
        "stderr_tail": stderr[-2000:],
    }

    result = None
    if not timed_out:
        try:
            result = json.loads(stdout)
        except json.JSONDecodeError:
            record["parse_error"] = True
            record["stdout_tail"] = stdout[-3000:]

    if result:
        u = result.get("usage", {})
        api_in = u.get("input_tokens", 0)
        cache_c = u.get("cache_creation_input_tokens", 0)
        cache_r = u.get("cache_read_input_tokens", 0)
        out = u.get("output_tokens", 0)
        record.update({
            "answer": result.get("result", ""),
            "num_turns": result.get("num_turns"),
            "subtype": result.get("subtype"),
            "is_error": result.get("is_error"),
            "total_cost_usd": result.get("total_cost_usd"),
            "usage_raw": u,
            # accounting: input = everything sent (api input + both cache buckets)
            "input_tokens": api_in + cache_c + cache_r,
            "output_tokens": out,
            "total_tokens": api_in + cache_c + cache_r + out,
        })
    else:
        record.update({"input_tokens": "", "output_tokens": "", "total_tokens": "",
                       "answer": "", "num_turns": "", "subtype": "spawn_or_parse_failure"})

    # persist transcript
    TRANSCRIPTS.mkdir(exist_ok=True)
    with open(TRANSCRIPTS / f"{run_id}.json", "w", encoding="utf-8") as f:
        json.dump(record, f, ensure_ascii=False, indent=1)

    # append CSV row (success / failure_mode left blank for the human pass)
    new_file = not CSV_PATH.exists()
    with open(CSV_PATH, "a", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        if new_file:
            w.writeheader()
        w.writerow({k: record.get(k, "") for k in CSV_FIELDS})

    # append answer for the judgment pass
    with open(ANSWERS_MD, "a", encoding="utf-8") as f:
        f.write(f"## {run_id} — {task['task_id']}\n\n")
        f.write(f"**Q:** {task['query']}\n\n")
        f.write(f"**A:** {record.get('answer', '(no answer)')}\n\n")
        f.write(f"tokens={record.get('total_tokens')} turns={record.get('num_turns')} "
                f"duration={duration}s exit={record.get('exit_code')}\n\n---\n\n")

    return record


def main():
    if not (RAG_DIR / "graph.py").exists():
        sys.exit(f"graph.py not found under RAG_DIR={RAG_DIR}. Set RAG_DIR to the "
                 f"RAG project directory.")

    print(f"claude   : {CLAUDE}")
    print(f"rag dir  : {RAG_DIR}")
    print(f"inner py : {INNER_PYTHON}")
    print(f"model    : {MODEL}")

    tasks = json.loads((HERE / "tasks.json").read_text(encoding="utf-8"))["tasks"]
    only = sys.argv[1] if len(sys.argv) > 1 else None  # e.g. "T1_simple:1" pilot mode

    if only:
        tid, n = only.split(":")
        task = next(t for t in tasks if t["task_id"] == tid)
        rounds = [(f"{tid}_r{i+1}", task) for i in range(int(n))]
    else:
        rounds = [
            (f"{t['task_id']}_r{i+1}", t)
            for t in tasks for i in range(ROUNDS)
        ]
        # skip rounds already logged (lets us resume after interruption)
        done = set()
        if CSV_PATH.exists():
            with open(CSV_PATH, encoding="utf-8-sig") as f:
                done = {row["run_id"] for row in csv.DictReader(f)}
        rounds = [r for r in rounds if r[0] not in done]

    print(f"{len(rounds)} round(s) to run, sequential")
    for run_id, task in rounds:
        print(f"--- {run_id}: {task['query']}")
        rec = run_round(run_id, task)
        status = "TIMEOUT" if rec.get("timed_out") else f"exit={rec.get('exit_code')}"
        print(f"    {status} tokens={rec.get('total_tokens')} "
              f"turns={rec.get('num_turns')} {rec.get('duration_seconds')}s")
        time.sleep(2)


if __name__ == "__main__":
    main()

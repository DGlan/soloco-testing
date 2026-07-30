#!/usr/bin/env bash
# search_actions.sh —— 枚举某 managed-MCP provider 在本会话中「已批准的 action slug」
#
# 背景：tools/list 对 gmail 只返回 3 个 Composio 元工具
# （COMPOSIO_SEARCH_TOOLS / COMPOSIO_GET_TOOL_SCHEMAS / COMPOSIO_MULTI_EXECUTE_TOOL），
# 真实能力是 COMPOSIO_MULTI_EXECUTE_TOOL 的 **参数**（action slug），不是工具名。
# 因此只看 tools/list 会严重低估能力面。
#
# 本脚本调用 COMPOSIO_SEARCH_TOOLS —— 该工具语义为「搜索本会话已批准的动作」，
# **只读，不执行任何动作**。绝不调用 COMPOSIO_MULTI_EXECUTE_TOOL。
#
# 用法： bash mcp/search_actions.sh gmail "send email"

set -uo pipefail

PROVIDER="${1:-gmail}"
QUERY="${2:-send email}"

DIR="$(cd "$(dirname "$0")" && pwd)/evidence"
HOME_DIR="${SOLOCO_HOME:-$HOME/.soloco}"
AUTH="$HOME_DIR/auth.json"
mkdir -p "$DIR"

TOKEN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["accessToken"])' "$AUTH")
BASEURL=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["serverBaseUrl"].rstrip("/"))' "$AUTH")
API="$BASEURL/api/soloco/managed-mcp"
RUNID="probe-$(date +%s)-$RANDOM"

SESS=$(curl -s --max-time 30 -X POST "$API/sessions" \
  -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  -d "{\"runId\":\"$RUNID\",\"capabilityRequests\":[{\"provider\":\"$PROVIDER\"}]}")
SID=$(printf '%s' "$SESS" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("sessionId") or d.get("id") or (d.get("session") or {}).get("sessionId",""))')
[ -n "$SID" ] || { echo "会话申请失败: $SESS" >&2; exit 1; }
RELAY="$API/sessions/$SID/mcp"
trap 'curl -s -X DELETE "$API/sessions/$SID" -H "authorization: Bearer $TOKEN" >/dev/null 2>&1; echo "(会话已释放)"' EXIT

rpc() {
  curl -s --max-time 45 -X POST "$RELAY" \
    -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
    -H "accept: application/json, text/event-stream" -d "$1"
}

rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"soloco-testing-probe","version":"0.1.0"}}}' > /dev/null
rpc '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' > /dev/null

REQ=$(python3 -c '
import json,sys
print(json.dumps({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{
  "name":"COMPOSIO_SEARCH_TOOLS",
  "arguments":{"queries":[{"use_case":sys.argv[1]}],
               "session":{"generate_id":True}}}}))' "$QUERY")

OUT_FILE="$DIR/actions_${PROVIDER}_$(echo "$QUERY" | tr ' /' '__').json"
rpc "$REQ" > "$OUT_FILE"
echo "raw -> $OUT_FILE"
echo

python3 - "$OUT_FILE" "$QUERY" <<'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
if raw.lstrip().startswith("event:") or "\ndata:" in raw or raw.startswith("data:"):
    parts = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")]
    raw = parts[-1] if parts else raw
try:
    d = json.loads(raw)
except Exception:
    print("无法解析：", raw[:800]); sys.exit(1)
if "error" in d:
    print("错误：", json.dumps(d["error"], ensure_ascii=False)); sys.exit(1)

content = d.get("result", {}).get("content", [])
text = "\n".join(c.get("text", "") for c in content if isinstance(c, dict))
slugs = sorted(set(re.findall(r"\b[A-Z][A-Z0-9]+_[A-Z0-9_]{3,}\b", text)))

print("查询用例: %s" % sys.argv[2])
print("命中 action slug: %d\n" % len(slugs))
SEND = re.compile(r"SEND|REPLY|FORWARD|POST|PUBLISH|CREATE_DRAFT", re.I)
hot = []
for s in slugs:
    if s.startswith("COMPOSIO_"):
        continue
    m = "!!" if SEND.search(s) else "  "
    if m == "!!":
        hot.append(s)
    print("%s %s" % (m, s))
print()
if hot:
    print("判读：已批准动作中存在外发能力 -> %s" % ", ".join(hot))
    print("      即 MCP 通道确实具备发信能力，第 3 步（是否经审批闸门）必须做。")
else:
    print("判读：本次查询未命中外发类 action。")
    print("      注意这是按 use_case 检索的结果，不等于已批准集合的全集；")
    print("      应换多个 use_case 复查后再下结论。")
if not text.strip():
    print("\n(响应正文为空，原始内容见 %s)" % sys.argv[1])
PY

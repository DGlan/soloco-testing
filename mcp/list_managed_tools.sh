#!/usr/bin/env bash
# list_managed_tools.sh —— 枚举某个 managed-MCP provider 实际暴露的工具清单
#
# 为什么需要它：SoloCo 的本地 MCP 代理路径是逐 run 随机生成的
# （`/managed-mcp/<32字节随机>`），只在 run 派发时交给 agent，
# 没有独立开会话的入口。若要看工具清单就必须跑一个 goal，那要烧 token。
#
# 本脚本改为直接向云端 relay 申请会话（用 ~/.soloco/auth.json 里已有的
# accessToken，即用户自己的凭据），走标准 MCP 握手后调用 tools/list。
# **不经过任何 LLM，零 token 消耗；tools/list 是只读方法，不产生副作用。**
#
# 用法：
#   bash mcp/list_managed_tools.sh gmail
#   bash mcp/list_managed_tools.sh slack
#
# 产物：mcp/evidence/tools_<provider>.json（原始响应）
#       并在 stdout 打印工具名与「是否含外发语义」的初判

set -uo pipefail

PROVIDER="${1:-}"
[ -n "$PROVIDER" ] || { echo "用法: bash $0 <provider>" >&2; exit 2; }

DIR="$(cd "$(dirname "$0")" && pwd)/evidence"
HOME_DIR="${SOLOCO_HOME:-$HOME/.soloco}"
AUTH="$HOME_DIR/auth.json"
mkdir -p "$DIR"

[ -f "$AUTH" ] || { echo "未找到 $AUTH，请先登录 soloco" >&2; exit 1; }

TOKEN=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["accessToken"])' "$AUTH")
BASEURL=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["serverBaseUrl"].rstrip("/"))' "$AUTH")
EXPIRES=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("expiresAt",""))' "$AUTH")
API="$BASEURL/api/soloco/managed-mcp"
RUNID="probe-$(date +%s)-$RANDOM"

echo "provider:   $PROVIDER"
echo "runId:      $RUNID"
echo "token_exp:  $EXPIRES  (now $(date -u +%Y-%m-%dT%H:%M:%SZ))"
echo

# ---- 1. 申请会话 ------------------------------------------------------------
SESS=$(curl -s --max-time 30 -X POST "$API/sessions" \
  -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  -d "{\"runId\":\"$RUNID\",\"capabilityRequests\":[{\"provider\":\"$PROVIDER\"}]}")

echo "$SESS" > "$DIR/session_$PROVIDER.json"
SID=$(python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit()
for k in ("sessionId","id"):
    if isinstance(d,dict) and k in d: print(d[k]); break
else:
    s=d.get("session") if isinstance(d,dict) else None
    if isinstance(s,dict): print(s.get("sessionId") or s.get("id") or "")
' "$DIR/session_$PROVIDER.json")

if [ -z "$SID" ]; then
  echo "会话申请失败，原始响应："; echo "$SESS" | head -c 800; echo; exit 1
fi
echo "sessionId:  $SID"
RELAY="$API/sessions/$SID/mcp"

cleanup() {
  curl -s --max-time 15 -X DELETE "$API/sessions/$SID" \
    -H "authorization: Bearer $TOKEN" > /dev/null 2>&1
  echo "(会话已释放)"
}
trap cleanup EXIT

# ---- 2. MCP 握手 ------------------------------------------------------------
rpc() {
  curl -s --max-time 30 -D "$DIR/.hdr" -X POST "$RELAY" \
    -H "authorization: Bearer $TOKEN" \
    -H "content-type: application/json" \
    -H "accept: application/json, text/event-stream" \
    ${MCP_SID:+-H "mcp-session-id: $MCP_SID"} \
    -d "$1"
}

INIT=$(rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
  "protocolVersion":"2024-11-05","capabilities":{},
  "clientInfo":{"name":"soloco-testing-probe","version":"0.1.0"}}}')
MCP_SID=$(grep -i '^mcp-session-id:' "$DIR/.hdr" 2>/dev/null | tr -d '\r' | cut -d' ' -f2)
echo "mcp_session: ${MCP_SID:-<none>}"
echo "$INIT" > "$DIR/init_$PROVIDER.json"

rpc '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' > /dev/null

# ---- 3. tools/list（只读） ---------------------------------------------------
TOOLS=$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
echo "$TOOLS" > "$DIR/tools_$PROVIDER.json"
rm -f "$DIR/.hdr"

# ---- 4. 判读 ----------------------------------------------------------------
python3 - "$DIR/tools_$PROVIDER.json" <<'PY'
import json, re, sys

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# StreamableHTTP 可能以 SSE 形式返回，取最后一个 data: 行
if "data:" in raw:
    parts = [l[5:].strip() for l in raw.splitlines() if l.startswith("data:")]
    raw = parts[-1] if parts else raw
try:
    d = json.loads(raw)
except Exception:
    print("无法解析响应：", raw[:600]); sys.exit(1)

if "error" in d:
    print("服务端返回错误：", json.dumps(d["error"], ensure_ascii=False)); sys.exit(1)

tools = d.get("result", {}).get("tools", [])
print("工具总数: %d\n" % len(tools))

WRITE = re.compile(
    r"send|create|draft|reply|forward|post|write|update|delete|modify|trash|archive|label",
    re.I)
SEND = re.compile(r"send|reply|forward|post|publish", re.I)

flagged = []
for t in tools:
    name = t.get("name", "?")
    desc = (t.get("description") or "").replace("\n", " ")[:80]
    mark = "  "
    if SEND.search(name):
        mark = "!!"; flagged.append(name)
    elif WRITE.search(name):
        mark = " *"
    print("%s %-42s %s" % (mark, name, desc))

print()
print("!! = 名称含外发语义（send/reply/forward/post/publish）")
print(" * = 名称含其它写操作语义")
print()
if flagged:
    print("判读：存在外发能力工具 -> %s" % ", ".join(flagged))
    print("      需继续第 3 步，验证调用它是否经过审批闸门。")
else:
    print("判读：未发现外发能力工具。")
    print("      若全部为只读，则「MCP 不绕过闸门」是因为未授予能力，")
    print("      而非存在闸门 —— 对应 findings 第 9-4 节表格第一行，定级 Medium。")
PY

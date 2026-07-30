#!/usr/bin/env bash
# probe_mcp_surface.sh —— SoloCo MCP 接入面取证脚本
#
# 目的：把「MCP 能接什么、接不了什么」从叙述变成可复现的机器产物。
# 成本：零 token。全部为本地 HTTP 探测与已安装包的静态读取，不触发任何 goal。
#
# 用法：
#   bash mcp/probe_mcp_surface.sh            # 输出到 mcp/evidence/
#   OUT=/tmp/x bash mcp/probe_mcp_surface.sh # 自定义输出目录
#
# 前置：soloco daemon 正在运行（soloco status 应显示 running）。

set -uo pipefail

OUT="${OUT:-$(cd "$(dirname "$0")" && pwd)/evidence}"
PORT="${SOLOCO_DAEMON_PORT:-8751}"
BASE="http://localhost:${PORT}"
HOME_DIR="${SOLOCO_HOME:-$HOME/.soloco}"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$OUT"

# ---- 环境指纹 ---------------------------------------------------------------
CLI_JS="$(dirname "$(readlink -f "$(command -v soloco)")")/dist/cli.js"

{
  echo "collected_at_utc: $STAMP"
  echo "soloco_version:   $(soloco --version 2>/dev/null | head -1)"
  echo "node_version:     $(node --version 2>/dev/null)"
  echo "os:               $(uname -sr)"
  echo "distro:           $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  echo "cli_js:           $CLI_JS"
  echo "cli_js_sha256:    $(sha256sum "$CLI_JS" 2>/dev/null | cut -d' ' -f1)"
  echo "daemon_status:    $(soloco status 2>&1 | head -1)"
  echo "listen:           $(ss -lnt 2>/dev/null | grep ":$PORT" | tr -s ' ' | head -1)"
} > "$OUT/environment.txt"

# ---- A. API 面：认证要求矩阵 -------------------------------------------------
# 每个端点探两次：不带 token 与带 token，比对状态码。
TOKEN="$(cat "$HOME_DIR/daemon-token" 2>/dev/null || echo)"

ENDPOINTS=(
  "/remote-mcp/connections"
  "/remote-mcp/connections/linear"
  "/remote-mcp/connections/notion"
  "/remote-mcp/connections/sentry"
  "/remote-mcp/connections/gmail"
  "/remote-mcp/connections/my-local-test-server"
  "/managed-mcp/connections"
)

{
  echo "# MCP 端点认证要求矩阵"
  echo "# collected_at_utc: $STAMP"
  echo
  printf "%-46s %-12s %-12s %s\n" "ENDPOINT" "NO_AUTH" "WITH_AUTH" "VERDICT"
  for ep in "${ENDPOINTS[@]}"; do
    na=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE$ep")
    wa=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
         -H "Authorization: Bearer $TOKEN" "$BASE$ep")
    if [ "$na" = "$wa" ] && [ "$na" = "200" ]; then
      v="UNAUTHENTICATED"
    elif [ "$na" = "$wa" ]; then
      v="same($na)"
    else
      v="AUTH_ENFORCED"
    fi
    printf "%-46s %-12s %-12s %s\n" "$ep" "$na" "$wa" "$v"
  done
} > "$OUT/api_auth_matrix.txt"

# ---- B. 连接状态快照 ---------------------------------------------------------
curl -s --max-time 10 "$BASE/remote-mcp/connections"  > "$OUT/remote_mcp_connections.json"
curl -s --max-time 10 "$BASE/managed-mcp/connections" > "$OUT/managed_mcp_connections.json"

# ---- C. 静态常量：provider 枚举、状态机、scope ------------------------------
# 这些是 zod 枚举，编译进 cli.js，决定了「能不能注册自建 server」这一问题的答案。
{
  echo "# 从 dist/cli.js 提取的 MCP 常量"
  echo "# cli_js_sha256: $(sha256sum "$CLI_JS" | cut -d' ' -f1)"
  echo
  echo "## remote-mcp provider 枚举（zod enum，编译期固定）"
  grep -oE 'Yd=\["linear"[^]]*\]' "$CLI_JS" | head -1
  echo
  echo "## remote-mcp scope profile 枚举"
  grep -oE '\["linear_read_write"[^]]*\]' "$CLI_JS" | head -1
  echo
  echo "## 授权状态机"
  grep -oE 'c\.enum\(\["disconnected","authorizing","connected","needs_reconnect"\]\)' "$CLI_JS" | head -1
  echo
  echo "## capability 探测状态"
  grep -oE 'c\.enum\(\["not_probed","ready","incompatible"\]\)' "$CLI_JS" | head -1
  echo
  echo "## 上游 MCP 端点（硬编码常量，无 env 覆盖）"
  grep -oE 'https://mcp\.(linear\.app|notion\.com|sentry\.dev)[a-z0-9./_-]*' "$CLI_JS" | sort -u
  echo
  echo "## probe 失败原因码"
  grep -oE 'remote_mcp_[a-z_]+' "$CLI_JS" | sort -u
} > "$OUT/mcp_constants.txt"

# ---- D. 环境变量旋钮清单 -----------------------------------------------------
# 其中规划/解析类旋钮直接关系到结构化输出截断问题。
grep -oE 'SOLOCO_[A-Z0-9_]+' "$CLI_JS" | sort -u > "$OUT/env_knobs.txt"

# ---- E. 本地凭据落盘面 -------------------------------------------------------
{
  echo "# ~/.soloco 权限快照（仅元数据，不含内容）"
  ls -la "$HOME_DIR" | awk '{print $1, $3, $4, $5, $9}'
  echo
  echo "# MCP 相关表的行数（只读打开，不修改）"
  for t in credential_records payment_connections settings; do
    n=$(sqlite3 -readonly "file:$HOME_DIR/daemon.db?mode=ro" \
        "select count(*) from $t;" 2>/dev/null || echo "n/a")
    echo "$t: $n"
  done
} > "$OUT/local_surface.txt"

# ---- F. 脱敏 ---------------------------------------------------------------
# 仓库惯例：产物中的用户名一律替换为 <user>（与 docs 第 14-4 节一致）。
# 只处理本目录产物，不触碰被测系统。
ME="$(id -un)"
for f in "$OUT"/*; do
  [ -f "$f" ] || continue
  sed -i "s#/home/$ME#/home/<user>#g; s#\\b$ME\\b#<user>#g" "$f"
done

echo "done -> $OUT"
ls -1 "$OUT"

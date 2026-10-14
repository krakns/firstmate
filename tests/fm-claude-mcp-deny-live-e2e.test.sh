#!/usr/bin/env bash
# Default-on live guard for config/worker-mcp-deny (docs/configuration.md
# "Worker MCP server deny list") against the real installed Claude Code.
#
# fm-spawn keeps a primary-reserved MCP server out of every Claude worker by
# passing Claude Code's deniedMcpServers key in the per-launch --settings
# value. Whether Claude honors that key from --settings is vendor behavior, so
# a fake can only restate the assumption. This guard builds the key with the
# production parser (bin/fm-exclude-tools-lib.sh), launches the REAL claude
# with two throwaway MCP servers, and reads the session's init event: the
# denied server must be absent while the other one stays. The same launch
# without the key must list both, so the absence is the key at work rather
# than a server Claude never loaded.
#
# A throwaway HOME keeps the operator's own MCP servers (and a one-owner
# server such as Peekaboo) from starting, and a dead ANTHROPIC_BASE_URL plus a
# kill right after the init event means no prompt reaches a model and no
# tokens are spent, so the shared live gate runs it by default wherever claude
# is installed. Run it after every Claude Code upgrade and before trusting the
# "Worker MCP server deny list" entry in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CLAUDE_MCP_DENY_LIVE_E2E claude jq
# shellcheck source=bin/fm-exclude-tools-lib.sh
. "$ROOT/bin/fm-exclude-tools-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-mcp-deny-live)
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME" "$TMP_ROOT/config"
unset CLAUDE_CONFIG_DIR
VERSION=$(claude --version 2>/dev/null | head -1)

printf '{"mcpServers":{"fmprobe-denied":{"command":"/usr/bin/false"},"fmprobe-kept":{"command":"/usr/bin/false"}}}\n' \
  >"$TMP_ROOT/mcp.json"
printf '%s\n' '# reserved for the primary' fmprobe-denied >"$TMP_ROOT/config/worker-mcp-deny"
DENY=$(fm_worker_mcp_deny_json "$TMP_ROOT/config") || fail "the production parser refused the probe deny list"

# init_servers <settings-json>: print the sorted MCP server names from the
# real claude's stream-json init event, then stop it before any model call.
init_servers() {
  local out="$TMP_ROOT/stream.$RANDOM" pid i
  (
    cd "$TMP_ROOT" || exit 1
    exec env ANTHROPIC_API_KEY=sk-fm-live-probe ANTHROPIC_BASE_URL=http://127.0.0.1:9 \
      claude -p probe --setting-sources '' --strict-mcp-config --mcp-config "$TMP_ROOT/mcp.json" \
      --settings "$1" --output-format stream-json --verbose </dev/null >"$out" 2>/dev/null
  ) &
  pid=$!
  for i in $(seq 1 150); do
    grep -q '"subtype":"init"' "$out" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  grep '"subtype":"init"' "$out" | head -1 | jq -c '[.mcp_servers[].name] | sort'
}

base=$(init_servers '{}')
[ "$base" = '["fmprobe-denied","fmprobe-kept"]' ] \
  || fail "claude $VERSION did not load both probe servers without a deny list (got '${base:-no init event}')"
denied=$(init_servers "{\"deniedMcpServers\":$DENY}")
[ "$denied" = '["fmprobe-kept"]' ] \
  || fail "claude $VERSION did not honor deniedMcpServers from --settings (got '${denied:-no init event}')"
pass "claude $VERSION: deniedMcpServers in --settings drops the denied MCP server and keeps the rest"

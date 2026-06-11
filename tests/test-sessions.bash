#!/usr/bin/env bash
# Backend.sessions() against a real herdr: starts an agent, queries sidekick.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/_lib.bash"

trap stop_test_session EXIT
start_test_session

# Start a fake "claude" agent in the test session's current workspace.
HERDR_SOCKET_PATH="$SESSION_SOCK" herdr agent start claude \
  --cwd "$PWD" --no-focus -- sleep 30 \
  >/dev/null 2>&1 || fail "herdr agent start failed"

# Wait for the agent to appear in agent list (matches either `agent` or `name` field).
wait_for 5 bash -c '
  HERDR_SOCKET_PATH="$1" herdr agent list | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
agents=(d.get(\"result\") or {}).get(\"agents\") or d.get(\"agents\") or []
print(any((a.get(\"agent\") or a.get(\"name\"))==\"claude\" for a in agents))
" | grep -q True
' _ "$SESSION_SOCK" || fail "claude agent did not appear in agent list"

# Drive the backend through Lua and verify it surfaces the session.
out=$(eval_lua_file '
require("sidekick_herdr").setup({ socket = vim.env.SIDEKICK_HERDR_SESSION_SOCK })
local c = require("sidekick.config")
c.cli.tools = c.cli.tools or {}
c.cli.tools.claude = { cmd = { "claude" } }
local s = require("sidekick_herdr.session")
local r = s.sessions()
print(string.format("n=%d", #r))
for _, st in ipairs(r) do
  print(string.format("id=%s tool=%s cwd=%s ws=%s", st.id, st.tool.name, st.cwd, st.mux_session))
end
')
echo "$out"
echo "$out" | grep -q 'n=1' || fail "expected 1 session, got: $out"
echo "$out" | grep -q 'tool=claude' || fail "tool name not surfaced: $out"
echo "$out" | grep -q "$PWD" || fail "cwd not surfaced: $out"

# Cleanup the agent pane before stopping the session.
HERDR_SOCKET_PATH="$SESSION_SOCK" herdr pane list \
  | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
for p in (d.get("result") or {}).get("panes",[]):
  if (p.get("agent") or p.get("name"))=="claude":
    print(p["pane_id"])
' | while read -r pid; do
    [ -n "$pid" ] && HERDR_SOCKET_PATH="$SESSION_SOCK" herdr pane close "$pid" >/dev/null 2>&1 || true
  done

pass "test-sessions"

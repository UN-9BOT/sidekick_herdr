#!/usr/bin/env bash
# Real send() + dump() against a fake agent in a fresh herdr session.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/_lib.bash"

trap stop_test_session EXIT
start_test_session

# Start a fake agent that prints a sentinel so we can dump it.
HERDR_SOCKET_PATH="$SESSION_SOCK" herdr agent start echosrv \
  --cwd "$PWD" --no-focus -- /bin/sh -c 'while :; do read line; echo "echo:$line"; done' \
  >/dev/null 2>&1 || fail "herdr agent start failed"

# Wait for the agent to appear in agent list.
wait_for 5 bash -c '
  HERDR_SOCKET_PATH="$1" herdr agent list | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
agents=(d.get(\"result\") or {}).get(\"agents\") or d.get(\"agents\") or []
print(any((a.get(\"agent\") or a.get(\"name\"))==\"echosrv\" for a in agents))
" | grep -q True
' _ "$SESSION_SOCK" || fail "echosrv agent did not appear"

# Run send() + dump() through the backend.
out=$(eval_lua_file '
require("sidekick_herdr").setup({ socket = vim.env.SIDEKICK_HERDR_SESSION_SOCK })
local c = require("sidekick.config")
c.cli.tools = c.cli.tools or {}
c.cli.tools.echosrv = { cmd = { "echosrv" } }
c.cli.mux.dump = 50

local Backend = require("sidekick_herdr.session")
local Session = require("sidekick.cli.session")
local r = Backend.sessions()
if #r ~= 1 then print("ERR: n="..#r); os.exit(1) end
local sess = Session.new({ tool = r[1].tool, cwd = r[1].cwd, backend = "herdr", sid = r[1].id, id = r[1].id })
sess.herdr_pane_id = r[1].herdr_pane_id
sess.mux_session = r[1].mux_session
sess.started = true
sess:send("hello from test")
sess:submit()
vim.wait(500, function() return false end)
local dump = sess:dump()
print("DUMP_BEGIN")
print(dump or "(nil)")
print("DUMP_END")
')
echo "$out"
echo "$out" | grep -q 'DUMP_BEGIN' || fail "no dump output"
# The echosrv echoes "echo:hello from test"
echo "$out" | grep -q 'hello from test' || fail "dump did not contain sent text: $out"

# Cleanup the agent pane.
HERDR_SOCKET_PATH="$SESSION_SOCK" herdr pane list \
  | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
for p in (d.get("result") or {}).get("panes",[]):
  if (p.get("agent") or p.get("name"))=="echosrv":
    print(p["pane_id"])
' | while read -r pid; do
    [ -n "$pid" ] && HERDR_SOCKET_PATH="$SESSION_SOCK" herdr pane close "$pid" >/dev/null 2>&1 || true
  done

pass "test-send-dump"

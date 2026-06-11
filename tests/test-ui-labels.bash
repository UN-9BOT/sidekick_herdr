#!/usr/bin/env bash
# Verify the UI extension: sessions() carries herdr_workspace_label and
# herdr_tab_label, and the patched select.format appends them as a tail segment.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/_lib.bash"

trap stop_test_session EXIT
start_test_session

# Rename a workspace and a tab so we can verify labels, not just ids.
HERDR_SOCKET_PATH="$SESSION_SOCK" herdr workspace create \
  --cwd "$PWD" --label "ui-test-ws" --no-focus >/dev/null 2>&1 || true
HERDR_SOCKET_PATH="$SESSION_SOCK" herdr workspace rename \
  "$(HERDR_SOCKET_PATH=$SESSION_SOCK herdr workspace list | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
ws=(d.get("result") or {}).get("workspaces") or d.get("workspaces") or []
print(ws[0]["workspace_id"] if ws else "")
')" "ui-test-ws" >/dev/null 2>&1 || true

# Start a fake agent in this workspace and tab.
HERDR_SOCKET_PATH="$SESSION_SOCK" herdr agent start ui-agent \
  --cwd "$PWD" --no-focus -- sleep 30 >/dev/null 2>&1 || fail "agent start failed"

# Rename its tab (the first tab in that workspace).
HERDR_SOCKET_PATH="$SESSION_SOCK" herdr tab list | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
tabs=(d.get("result") or {}).get("tabs") or d.get("tabs") or []
print(tabs[0]["tab_id"] if tabs else "")
' | while read -r tid; do
    [ -n "$tid" ] && HERDR_SOCKET_PATH="$SESSION_SOCK" herdr tab rename "$tid" "ui-test-tab" >/dev/null 2>&1 || true
  done

wait_for 5 bash -c '
  HERDR_SOCKET_PATH="$1" herdr agent list | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
agents=(d.get(\"result\") or {}).get(\"agents\") or d.get(\"agents\") or []
print(any((a.get(\"agent\") or a.get(\"name\"))==\"ui-agent\" for a in agents))
" | grep -q True
' _ "$SESSION_SOCK" || fail "ui-agent did not appear"

# Drive the full pipeline: setup() (which patches select.format), then sessions().
out=$(eval_lua_file '
require("sidekick_herdr").setup({ socket = vim.env.SIDEKICK_HERDR_SESSION_SOCK })
local c = require("sidekick.config")
c.cli.tools = c.cli.tools or {}
c.cli.tools["ui-agent"] = { cmd = { "ui-agent" } }
local s = require("sidekick_herdr.session")
s._reset_label_cache()
local r = s.sessions()
if #r ~= 1 then print("ERR: n="..#r); os.exit(1) end
print("ws_id="..tostring(r[1].herdr_workspace_id))
print("ws_label="..tostring(r[1].herdr_workspace_label))
print("tab_id="..tostring(r[1].herdr_tab_id))
print("tab_label="..tostring(r[1].herdr_tab_label))

-- Verify the patched select.format adds a tail segment for herdr sessions.
local Select = require("sidekick.cli.ui.select")
assert(Select._herdr_patched, "select.format was not patched")
local state = { tool = r[1].tool, session = r[1] }
local out2 = Select.format(state)
local found_ws, found_tab = false, false
for _, seg in ipairs(out2) do
  if type(seg[1]) == "string" then
    if seg[1]:find("ui%-test%-ws", 1) then found_ws = true end
    if seg[1]:find("ui%-test%-tab", 1) then found_tab = true end
  end
end
print("format_appends_ws="..tostring(found_ws))
print("format_appends_tab="..tostring(found_tab))
')
echo "$out"
echo "$out" | grep -q 'ws_label=ui-test-ws' || fail "workspace label not propagated: $out"
echo "$out" | grep -q 'tab_label=ui-test-tab' || fail "tab label not propagated: $out"
echo "$out" | grep -q 'format_appends_ws=true' || fail "select.format did not append ws: $out"
echo "$out" | grep -q 'format_appends_tab=true' || fail "select.format did not append tab: $out"

# Cleanup the agent pane.
HERDR_SOCKET_PATH="$SESSION_SOCK" herdr pane list \
  | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
for p in (d.get("result") or {}).get("panes",[]):
  if (p.get("agent") or p.get("name"))=="ui-agent":
    print(p["pane_id"])
' | while read -r pid; do
    [ -n "$pid" ] && HERDR_SOCKET_PATH="$SESSION_SOCK" herdr pane close "$pid" >/dev/null 2>&1 || true
  done

pass "test-ui-labels"

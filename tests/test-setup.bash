#!/usr/bin/env bash
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/_lib.bash"

trap stop_test_session EXIT
start_test_session

out=$(eval_lua_file '
require("sidekick_herdr").setup({ socket = vim.env.SIDEKICK_HERDR_SESSION_SOCK })
local s = require("sidekick.cli.session")
local c = require("sidekick.config")
print("backend="..(s.backends.herdr and "yes" or "no").." mux="..c.cli.mux.backend)
')
echo "$out"
echo "$out" | grep -q 'backend=yes' || fail "backend not registered"
echo "$out" | grep -q 'mux=herdr' || fail "mux.backend not set"

pass "test-setup"

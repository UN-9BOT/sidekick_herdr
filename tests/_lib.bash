set -eu

PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MINIT="$PLUGIN_ROOT/tests/minit.lua"

export HERDR_TEST="${HERDR_TEST:-1}"

TESTS_TMP="${TESTS_TMP:-$(mktemp -d -t sidekick-herdr-tests.XXXXXX)}"
HERDR_CONFIG_DIR="$TESTS_TMP/herdr-config"
mkdir -p "$HERDR_CONFIG_DIR"

SESSION_NAME="shk-$$-$RANDOM"
SESSION_DIR="/home/unbot/.config/herdr/sessions/$SESSION_NAME"
SESSION_SOCK="$SESSION_DIR/herdr.sock"
SESSION_LOG="$TESTS_TMP/herdr-server.log"
PLUGIN_LOG="$TESTS_TMP/plugin.log"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

start_test_session() {
  cat >"$HERDR_CONFIG_DIR/herdr.toml" <<'TOML'
[experimental]
allow_nested = true
TOML
  HERDR_CONFIG_PATH="$HERDR_CONFIG_DIR/herdr.toml" \
    setsid herdr --session "$SESSION_NAME" </dev/null >"$SESSION_LOG" 2>&1 &
  disown 2>/dev/null || true
  local deadline=$((SECONDS + 10))
  while [ $SECONDS -lt $deadline ]; do
    if [ -S "$SESSION_SOCK" ] && HERDR_SOCKET_PATH="$SESSION_SOCK" \
         herdr workspace list >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  echo "--- session log ---" >&2
  cat "$SESSION_LOG" >&2 || true
  fail "herdr session $SESSION_NAME did not become ready in 10s"
}

stop_test_session() {
  HERDR_SOCKET_PATH="$SESSION_SOCK" herdr session stop "$SESSION_NAME" >/dev/null 2>&1 || true
  HERDR_SOCKET_PATH="$SESSION_SOCK" herdr session delete "$SESSION_NAME" >/dev/null 2>&1 || true
  rm -rf "$SESSION_DIR" 2>/dev/null || true
}

# Write $1 to a tmp lua file and execute it via `nvim -l`. Output to stdout.
# In -l mode print() works. Use SIDEKICK_HERDR_SESSION env to pass socket.
eval_lua_file() {
  local code="$1"
  local f="$TESTS_TMP/eval_$$.lua"
  # Inline bootstrap (rtp + sidekick + plenary paths) so the file is self-contained.
  cat > "$f" <<EOF
local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local plugin_root = vim.fn.fnamemodify(script_dir .. "/..", ":p")
-- resolve SIDEKICK_HERDR_PLUGIN_ROOT passed by caller (parent of tests/)
if vim.env.SIDEKICK_HERDR_PLUGIN_ROOT and vim.env.SIDEKICK_HERDR_PLUGIN_ROOT ~= "" then
  plugin_root = vim.env.SIDEKICK_HERDR_PLUGIN_ROOT:gsub("/$","") .. "/"
end
vim.opt.rtp:prepend(plugin_root)
local function expand_home(p)
  if p:sub(1, 2) == "~/" then return vim.fn.expand("~") .. p:sub(2) end
  return p
end
local function add(path)
  local abs = vim.fn.fnamemodify(expand_home(path), ":p"):gsub("/$", "")
  if vim.fn.isdirectory(abs) == 1 then
    vim.opt.rtp:append(abs)
    package.path = package.path .. ";" .. abs .. "/lua/?.lua" .. ";" .. abs .. "/lua/?/init.lua"
  end
end
add("~/.local/share/nvim/lazy/plenary.nvim")
add("~/.local/share/nvim/lazy/sidekick.nvim")
package.path = package.path .. ";" .. plugin_root .. "lua/?.lua" .. ";" .. plugin_root .. "lua/?/init.lua"
$code
EOF
  SIDEKICK_HERDR_SESSION_SOCK="$SESSION_SOCK" \
  SIDEKICK_HERDR_CONFIG_PATH="$HERDR_CONFIG_DIR/herdr.toml" \
  SIDEKICK_HERDR_PLUGIN_ROOT="$PLUGIN_ROOT" \
    nvim -l "$f" 2>&1
}

wait_for() {
  local timeout_s="$1"; shift
  local deadline=$((SECONDS + timeout_s))
  while [ $SECONDS -lt $deadline ]; do
    if "$@"; then return 0; fi
    sleep 0.1
  done
  return 1
}

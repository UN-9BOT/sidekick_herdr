---@module 'luassert'

local Session
local Util
local Config

local function stub_exec(returns)
  local original = Util.exec
  local calls = {}
  Util.exec = function(cmd, opts)
    calls[#calls + 1] = { cmd = vim.deepcopy(cmd), opts = opts or {} }
    local r = returns(cmd, opts or {})
    if type(r) == "table" and r.__split then
      return r.lines, r.raw
    end
    if type(r) == "string" then
      return nil, r
    end
    return r
  end
  return function() Util.exec = original end, calls
end

local function make_tool(name, cmd, opts)
  return setmetatable(vim.tbl_extend("force", { name = name, cmd = cmd, env = {} }, opts or {}), {
    __index = function(_, k) return nil end,
  })
end

local function make_session(state)
  state = state or {}
  state.tool = state.tool or make_tool("claude", { "claude" })
  state.backend = state.backend or "herdr"
  state.cwd = state.cwd or "/tmp/proj"
  return Session.new(state)
end

local function scrub_herdr_env()
  vim.env.HERDR_SOCKET_PATH = nil
  vim.env.HERDR_CONFIG_PATH = nil
end
local function reload_herdr()
  package.loaded["sidekick_herdr"] = nil
  package.loaded["sidekick_herdr.session"] = nil
  return require("sidekick_herdr")
end

local function reset_session_backend()
  Session = require("sidekick.cli.session")
  Session.backends["herdr"] = nil
  Session.did_setup = false
end

describe("sidekick_herdr.setup", function()
  before_each(function()
    scrub_herdr_env()
    vim.fn.executable = function(_) return 1 end
    Util = require("sidekick.util")
    reset_session_backend()
    reload_herdr()
  end)

  it("registers the herdr backend and sets mux.backend", function()
    require("sidekick_herdr").setup()
    assert.is_not_nil(Session.backends["herdr"])
    assert.are.equal("herdr", require("sidekick.config").cli.mux.backend)
  end)

  it("is idempotent on repeated setup", function()
    require("sidekick_herdr").setup()
    require("sidekick_herdr").setup()
    assert.is_not_nil(Session.backends["herdr"])
  end)

  it("warns and does not register when binary missing", function()
    vim.fn.executable = function(_) return 0 end
    local warned
    local original_warn = Util.warn
    Util.warn = function(m) warned = m end
    require("sidekick_herdr").setup()
    Util.warn = original_warn
    local flat = vim.tbl_flatten({ warned })
    assert.is_true(vim.tbl_contains(flat, "sidekick_herdr: executable `herdr` not found in PATH"))
    assert.is_nil(Session.backends["herdr"])
  end)
end)

describe("sidekick_herdr.session.start", function()
  before_each(function()
    scrub_herdr_env()
    vim.fn.executable = function(_) return 1 end
    Util = require("sidekick.util")
    reset_session_backend()
    reload_herdr().setup()
  end)

  it("builds herdr agent start command and clears HERDR env", function()
    local s = make_session({ sid = "claude abcdef" })
    local ret = s:start()
    assert.are.same({
      "herdr", "agent", "start", "claude", "--cwd", "/tmp/proj", "--no-focus", "--", "claude",
    }, ret.cmd)
    assert.are.same({ HERDR = false, HERDR_CONFIG_PATH = false }, ret.env)
  end)

  it("serialises additional tool cmd arguments", function()
    local s = make_session({ tool = make_tool("codex", { "codex", "--flag", "value" }), sid = "codex 1" })
    local ret = s:start()
    assert.are.same({
      "herdr", "agent", "start", "codex", "--cwd", "/tmp/proj", "--no-focus", "--",
      "codex", "--flag", "value",
    }, ret.cmd)
  end)
end)

describe("sidekick_herdr.session.send", function()
  local restore, calls
  before_each(function()
    scrub_herdr_env()
    vim.fn.executable = function(_) return 1 end
    Util = require("sidekick.util")
    reset_session_backend()
    reload_herdr().setup()
    restore, calls = stub_exec(function() return {} end)
  end)
  after_each(function() restore() end)

  it("sends text via pane send-text when mux_focus is off", function()
    local s = make_session({ sid = "claude 1" })
    s.tool = make_tool("claude", { "claude" }, { mux_focus = false })
    s.herdr_pane_id = "p1"
    s:send("hello")
    assert.are.equal(1, #calls)
    assert.are.same({ "herdr", "pane", "send-text", "p1", "hello" }, calls[1].cmd)
  end)

  it("sends Escape [, I first and defers text when mux_focus is on", function()
    vim.defer_fn = function(fn, _ms) fn() end
    local s = make_session({ sid = "claude 1" })
    s.tool = make_tool("claude", { "claude" }, { mux_focus = true })
    s.herdr_pane_id = "p1"
    s:send("hello")
    assert.are.equal(2, #calls)
    assert.are.same({ "herdr", "pane", "send-keys", "p1", "Escape", "[", "I" }, calls[1].cmd)
    assert.are.same({ "herdr", "pane", "send-text", "p1", "hello" }, calls[2].cmd)
  end)
end)

describe("sidekick_herdr.session.submit", function()
  local restore, calls
  before_each(function()
    scrub_herdr_env()
    vim.fn.executable = function(_) return 1 end
    Util = require("sidekick.util")
    reset_session_backend()
    reload_herdr().setup()
    restore, calls = stub_exec(function() return {} end)
  end)
  after_each(function() restore() end)

  it("sends Enter via pane send-keys", function()
    local s = make_session({ sid = "claude 1" })
    s.herdr_pane_id = "p1"
    s:submit()
    assert.are.same({ "herdr", "pane", "send-keys", "p1", "Enter" }, calls[1].cmd)
  end)
end)

describe("sidekick_herdr.session.is_running", function()
  local restore
  before_each(function()
    scrub_herdr_env()
    vim.fn.executable = function(_) return 1 end
    Util = require("sidekick.util")
    reset_session_backend()
    reload_herdr().setup()
  end)
  after_each(function() restore() end)

  it("returns false when herdr_pane_id is missing", function()
    restore = stub_exec(function() return {} end)
    local s = make_session()
    assert.is_false(s:is_running())
  end)

  it("returns true when pane get succeeds", function()
    restore = stub_exec(function() return { "{}" } end)
    local s = make_session()
    s.herdr_pane_id = "p1"
    assert.is_true(s:is_running())
  end)

  it("returns false when pane get fails", function()
    restore = stub_exec(function() return nil end)
    local s = make_session()
    s.herdr_pane_id = "p1"
    assert.is_false(s:is_running())
  end)
end)

describe("sidekick_herdr.session.dump", function()
  local restore, calls
  before_each(function()
    scrub_herdr_env()
    vim.fn.executable = function(_) return 1 end
    Util = require("sidekick.util")
    Config = require("sidekick.config")
    reset_session_backend()
    reload_herdr().setup()
    Config.cli.mux.dump = 50
    restore, calls = stub_exec(function() return "raw-bytes" end)
  end)
  after_each(function() restore() end)

  it("uses --lines from Config.cli.mux.dump and returns raw stdout", function()
    local s = make_session()
    s.herdr_pane_id = "p1"
    local out = s:dump()
    assert.are.equal("raw-bytes", out)
    local cmd = calls[1].cmd
    assert.are.equal("herdr", cmd[1])
    assert.are.equal("pane", cmd[2])
    assert.are.equal("read", cmd[3])
    assert.are.equal("p1", cmd[4])
    assert.are.equal("50", cmd[6])
  end)
end)

describe("sidekick_herdr.session.sessions", function()
  local restore
  before_each(function()
    scrub_herdr_env()
    vim.fn.executable = function(_) return 1 end
    Util = require("sidekick.util")
    Config = require("sidekick.config")
    reset_session_backend()
    reload_herdr().setup()
    Config.cli.tools = Config.cli.tools or {}
    Config.cli.tools.claude = { cmd = { "claude" } }
  end)
  after_each(function() restore() end)

  it("returns empty when herdr agent list is not parseable", function()
    restore = stub_exec(function() return {} end)
    local s = require("sidekick_herdr.session")
    assert.are.same({}, s.sessions())
  end)

  it("parses agent list and returns states only for known tools", function()
    local payload = vim.json.encode({
      result = {
        agents = {
          { agent = "claude", pane_id = "p1", workspace_id = "w1", foreground_cwd = "/tmp/c" },
          { agent = "vim", pane_id = "p2", workspace_id = "w1", foreground_cwd = "/tmp/v" },
        },
      },
    })
    restore = stub_exec(function() return { payload } end)
    local s = require("sidekick_herdr.session")
    local states = s.sessions()
    assert.are.equal(1, #states)
    assert.are.equal("herdr p1", states[1].id)
    assert.are.equal("/tmp/c", states[1].cwd)
    assert.are.equal("w1", states[1].mux_session)
    assert.are.equal("claude", states[1].tool.name)
  end)

  it("falls back to cwd when foreground_cwd is missing", function()
    local payload = vim.json.encode({
      result = {
        agents = {
          { agent = "claude", pane_id = "p1", workspace_id = "w1", cwd = "/tmp/c" },
        },
      },
    })
    restore = stub_exec(function() return { payload } end)
    local s = require("sidekick_herdr.session")
    local states = s.sessions()
    assert.are.equal("/tmp/c", states[1].cwd)
  end)
end)

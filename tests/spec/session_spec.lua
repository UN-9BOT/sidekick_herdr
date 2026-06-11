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

  it("start() returns nil and synchronously spawns herdr agent", function()
    local spawned_with
    local s = make_session({ sid = "claude abcdef" })
    s._spawn_agent = function(self) spawned_with = self.tool.name end
    local ret = s:start()
    assert.is_nil(ret, "start() must return nil so sidekick does not open a terminal wrapper")
    assert.are.equal("claude", spawned_with)
  end)

  it("_spawn_agent builds herdr agent start with shellescaped args", function()
    local captured_cmd, captured_env
    local orig_system = vim.system
    vim.system = function(cmd, opts)
      captured_cmd = cmd
      captured_env = opts and opts.env or nil
      return { wait = function() return { code = 0, stderr = "" } end }
    end
    local orig_exec = Util.exec
    Util.exec = function() return {}, "{}" end
    local s = make_session({ tool = make_tool("codex", { "codex", "--flag", "value" }), sid = "codex 1" })
    s:_spawn_agent()
    vim.system = orig_system
    Util.exec = orig_exec
    assert.are.equal("sh", captured_cmd[1])
    assert.are.equal("-c", captured_cmd[2])
    local shell_cmd = captured_cmd[3]
    assert.is_truthy(shell_cmd:find("herdr", 1, true), shell_cmd)
    assert.is_truthy(shell_cmd:find("agent", 1, true), shell_cmd)
    assert.is_truthy(shell_cmd:find("start", 1, true), shell_cmd)
    assert.is_truthy(shell_cmd:find("codex", 1, true), shell_cmd)
    assert.is_truthy(shell_cmd:find("flag", 1, true), shell_cmd)
    assert.is_truthy(shell_cmd:find("value", 1, true), shell_cmd)
    assert.is_truthy(shell_cmd:find(">/dev/null 2>&1", 1, true), shell_cmd)
    assert.are.equal(false, captured_env.HERDR)
    assert.are.equal(false, captured_env.HERDR_CONFIG_PATH)
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

  it("auto-resolves the pane id by polling herdr agent list, then submits", function()
    -- Stub resolve_pane to populate the pane id on the first call.
    -- The stub_exec in before_each returns {} -> resolve_pane would normally
    -- keep polling until it gives up; we shortcut that by overriding
    -- resolve_pane on this session.
    local s = make_session({ sid = "claude 1" })
    s.cwd = "/tmp/proj"
    s.resolve_pane = function(self)
      self.herdr_pane_id = "w999-1"
      return true
    end
    s:submit()
    assert.are.equal(1, #calls, "expected exactly one herdr CLI call")
    assert.are.same({ "herdr", "pane", "send-keys", "w999-1", "Enter" }, calls[1].cmd)
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
          { agent = "claude", pane_id = "p1", workspace_id = "w1", tab_id = "w1:1", foreground_cwd = "/tmp/c" },
          { agent = "vim", pane_id = "p2", workspace_id = "w1", foreground_cwd = "/tmp/v" },
        },
      },
    })
    restore = stub_exec(function() return { payload } end)
    local s = require("sidekick_herdr.session")
    s._reset_label_cache()
    -- Stub workspace list and tab list returns
    local original_exec = Util.exec
    Util.exec = function(cmd, opts)
      if cmd[2] == "workspace" and cmd[3] == "list" then
        return { vim.json.encode({ result = { workspaces = { { workspace_id = "w1", label = "myrepo" } } } }) }
      elseif cmd[2] == "tab" and cmd[3] == "list" then
        return { vim.json.encode({ result = { tabs = { { tab_id = "w1:1", label = "build" } } } }) }
      end
      return original_exec(cmd, opts)
    end
    local states = s.sessions()
    Util.exec = original_exec
    assert.are.equal(1, #states)
    -- id must equal the sidekick-style sid so M._attached lookup works
    -- across M.sessions() discovery (otherwise sidekick detaches every cycle).
    local Session = require("sidekick.cli.session")
    assert.are.equal(Session.sid({ tool = "claude", cwd = "/tmp/c" }), states[1].id)
    assert.are.equal("p1", states[1].herdr_pane_id)
    assert.are.equal("/tmp/c", states[1].cwd)
    assert.are.equal("w1", states[1].mux_session)
    assert.are.equal("claude", states[1].tool.name)
    assert.are.equal("w1", states[1].herdr_workspace_id)
    assert.are.equal("myrepo", states[1].herdr_workspace_label)
    assert.are.equal("w1:1", states[1].herdr_tab_id)
    assert.are.equal("build", states[1].herdr_tab_label)
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

describe("sidekick_herdr._patch_select", function()
  before_each(function()
    package.loaded["sidekick_herdr"] = nil
    package.loaded["sidekick_herdr.session"] = nil
    package.loaded["sidekick.cli.ui.select"] = nil
  end)

  it("rewrites [herdr:...] to include ws/tab inside brackets and drops cwd tail", function()
    -- Mimic real sidekick format: tool name + [herdr:w123] + cwd tail.
    local fake = { format = function(state, _picker)
      local s = state.session
      local backend = s.mux_backend or s.backend
      local mux = s.mux_session or ""
      local tail = s.cwd or ""
      return {
        { state.tool.name, "Normal" },
        { " " },
        { "[" .. backend .. (mux ~= "" and (":" .. mux) or "") .. "]", "Special" },
        { " " },
        { tail, "Directory" },
      }
    end }
    package.loaded["sidekick.cli.ui.select"] = fake
    local sh = require("sidekick_herdr")
    sh._patch_select()

    local herdr_state = {
      tool = { name = "claude" },
      session = {
        backend = "herdr",
        cwd = "/tmp/c",
        mux_backend = "herdr",
        mux_session = "w123",
        herdr_workspace_label = "myrepo",
        herdr_tab_label = "build",
      },
    }
    local tmux_state = {
      tool = { name = "codex" },
      session = { backend = "tmux", cwd = "/tmp/c", mux_session = "s1" },
    }
    local out_herdr = fake.format(herdr_state)
    local out_tmux = fake.format(tmux_state)

    local function find(out, predicate)
      for _, seg in ipairs(out) do
        if type(seg[1]) == "string" and predicate(seg[1]) then
          return seg
        end
      end
    end
    local function has_text(out, needle)
      return find(out, function(s) return s:find(needle, 1, true) ~= nil end) ~= nil
    end

    local herdr_bracket = find(out_herdr, function(s) return s:match("^%[herdr:") ~= nil end)
    assert.is_not_nil(herdr_bracket, "herdr output should still contain a [herdr:...] segment")
    assert.are.equal("[herdr:myrepo:build]", herdr_bracket[1])

    -- No standalone ws=/tab= segments anymore (they live inside the brackets)
    assert.is_nil(find(out_herdr, function(s) return s:find("ws=", 1, true) ~= nil end),
      "ws= must not appear as a separate segment")
    assert.is_nil(find(out_herdr, function(s) return s:find("tab=", 1, true) ~= nil end),
      "tab= must not appear as a separate segment")

    -- cwd tail must be gone
    assert.is_false(has_text(out_herdr, "/tmp/c"), "cwd tail must be dropped for herdr")

    -- tmux is untouched
    local tmux_bracket = find(out_tmux, function(s) return s:match("^%[tmux") ~= nil end)
    assert.is_not_nil(tmux_bracket, "tmux output should keep its [tmux:...] segment")
    assert.are.equal("[tmux:s1]", tmux_bracket[1])
    assert.is_true(has_text(out_tmux, "/tmp/c"), "tmux cwd tail must be preserved")
  end)

  it("falls through unchanged for herdr sessions without ws/tab labels", function()
    local fake = { format = function(state)
      return { { state.tool.name, "Normal" }, { " " }, { "[herdr:w123]", "Special" }, { " " }, { "/tmp/c", "Directory" } }
    end }
    package.loaded["sidekick.cli.ui.select"] = fake
    local sh = require("sidekick_herdr")
    sh._patch_select()

    local out = fake.format({
      tool = { name = "claude" },
      session = { backend = "herdr", cwd = "/tmp/c", mux_backend = "herdr", mux_session = "w123" },
    })
    -- No labels -> original format is returned, including cwd
    assert.is_true((function()
      for _, seg in ipairs(out) do
        if type(seg[1]) == "string" and seg[1] == "/tmp/c" then return true end
      end
      return false
    end)(), "cwd should be preserved when no ws/tab labels are available")
    local bracket_found = false
    for _, seg in ipairs(out) do
      if type(seg[1]) == "string" and seg[1] == "[herdr:w123]" then bracket_found = true end
    end
    assert.is_true(bracket_found, "original [herdr:w123] segment should be preserved")
  end)

  it("is idempotent", function()
    local fake = { format = function() return {} end }
    package.loaded["sidekick.cli.ui.select"] = fake
    local sh = require("sidekick_herdr")
    sh._patch_select()
    sh._patch_select()
    sh._patch_select()
    -- After 3 calls, still exactly one wrap layer: the second call sees _herdr_patched flag and returns.
    assert.is_true(fake._herdr_patched)
  end)
end)

describe("sidekick_herdr.session attach stability", function()
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

  it("state id returned by sessions() equals the sid used by Session.attach()", function()
    -- Stub herdr CLI to return one agent
    local Util0 = Util
    local agent_json = vim.json.encode({
      result = { agents = { { agent = "claude", pane_id = "p1", workspace_id = "w1", tab_id = "w1:1", foreground_cwd = "/tmp/c" } } },
    })
    local ws_json = vim.json.encode({ result = { workspaces = { { workspace_id = "w1", label = "myrepo" } } } })
    local tab_json = vim.json.encode({ result = { tabs = { { tab_id = "w1:1", label = "build" } } } })
    local stubbed = {}
    local restore = stub_exec(function(cmd)
      stubbed[#stubbed + 1] = cmd
      if cmd[2] == "agent" and cmd[3] == "list" then return { agent_json } end
      if cmd[2] == "workspace" and cmd[3] == "list" then return { ws_json } end
      if cmd[2] == "tab" and cmd[3] == "list" then return { tab_json } end
      return {}
    end)
    local s = require("sidekick_herdr.session")
    s._reset_label_cache()
    local SidekickSession = require("sidekick.cli.session")
    local states = s.sessions()
    restore()
    -- The id must match what SidekickSession.new({tool="claude",cwd="/tmp/c"}) produces.
    local sid = SidekickSession.sid({ tool = "claude", cwd = "/tmp/c" })
    assert.are.equal(sid, states[1].id)
    -- Simulate sidekick: when it wraps sessions() in Session.new(), the id is
    -- preserved (Session.new only sets self.id = self.id or self.sid, but here
    -- self.id is already set to sid). The important bit: M._attached[sid] stays
    -- stable across discovery cycles.
  end)

  it("attached session survives a sessions() discovery cycle", function()
    -- The crucial integration check: after `M._attached[sid] = session`,
    -- a subsequent sessions() discovery must include the same id so the
    -- prune loop in sidekick.cli.session.sessions() does not detach us.
    local SidekickSession = require("sidekick.cli.session")
    local agent_json = vim.json.encode({
      result = { agents = { { agent = "claude", pane_id = "p1", workspace_id = "w1", tab_id = "w1:1", foreground_cwd = "/tmp/proj" } } },
    })
    local restore = stub_exec(function(cmd)
      if cmd[2] == "agent" and cmd[3] == "list" then return { agent_json } end
      return { "[]" }
    end)
    local s = require("sidekick_herdr.session")
    s._reset_label_cache()
    local fake_session = SidekickSession.new({ tool = "claude", cwd = "/tmp/proj", backend = "herdr" })
    fake_session.herdr_pane_id = "p1"
    SidekickSession.attach(fake_session)
    -- Now sidekick runs the discovery pass...
    local _ = SidekickSession.sessions()
    restore()
    -- ...and the attach entry must still be there.
    local sid = fake_session.id
    assert.is_not_nil(SidekickSession._attached[sid],
      "attached session was pruned because sessions() id did not match attach id")
  end)
end)

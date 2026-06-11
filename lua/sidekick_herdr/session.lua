---@class sidekick_herdr.Session: sidekick.cli.Session
---@field herdr_pane_id? string
---@field herdr_workspace_id? string
---@field herdr_tab_id? string
local M = {}
M.__index = M
M.priority = 50
M.external = false

local function env()
  return require("sidekick_herdr").env()
end

local function exec(cmd, opts)
  local Util = require("sidekick.util")
  opts = opts or {}
  local merged = vim.tbl_extend("force", env(), opts.env or {})
  opts = vim.tbl_extend("force", { env = merged }, opts)
  return Util.exec(cmd, opts)
end

---@return any
local function json(cmd, opts)
  local lines, raw = exec(cmd, opts)
  if not lines or not lines[1] or lines[1] == "" then
    return nil, raw
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok then
    return nil, raw
  end
  return decoded
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  -- herdr agent start writes a JSON status line to stdout, which would land
  -- in sidekick's terminal buffer as visible garbage. Wrap the call in
  -- `sh -c` and redirect stdout+stderr to /dev/null so the terminal only
  -- ever shows the tool's own output.
  local args = { "herdr", "agent", "start", self.tool.name, "--cwd", self.cwd, "--no-focus", "--" }
  for _, c in ipairs(self.tool.cmd) do
    args[#args + 1] = c
  end
  local quoted = {} ---@type string[]
  for _, a in ipairs(args) do
    quoted[#quoted + 1] = vim.fn.shellescape(a)
  end
  return {
    cmd = { "sh", "-c", table.concat(quoted, " ") .. " >/dev/null 2>&1" },
    env = vim.tbl_extend("force", {
      HERDR = false,
      HERDR_CONFIG_PATH = false,
    }, env()),
  }
end

---@return sidekick.cli.terminal.Cmd?
function M:attach()
  return nil
end

--- Resolve the freshly started pane id, workspace id, and tab id.
---@return boolean ok
function M:resolve_pane()
  local decoded = json({ "herdr", "agent", "list" }, { notify = false })
  if type(decoded) ~= "table" then
    return false
  end
  local agents = (decoded.result and decoded.result.agents) or decoded.agents or {}
  for _, a in ipairs(agents) do
    if (a.agent or a.name) == self.tool.name and a.foreground_cwd == self.cwd then
      self.herdr_pane_id = a.pane_id
      self.herdr_workspace_id = a.workspace_id
      self.herdr_tab_id = a.tab_id
      self.mux_session = self.sid
      self.started = true
      return true
    end
  end
  return false
end

function M:is_running()
  if not self.herdr_pane_id then
    return false
  end
  local lines = exec({ "herdr", "pane", "get", self.herdr_pane_id }, { notify = false })
  return lines ~= nil
end

function M:_guard_pane(op)
  if not self.herdr_pane_id or self.herdr_pane_id == "" then
    local ok, Util = pcall(require, "sidekick.util")
    if ok then
      Util.warn(("sidekick_herdr: %s called before herdr_pane_id is known; " ..
        "the session was never started or the pane disappeared. " ..
        "Run SidekickCliAttach/Start to (re)attach."):format(op))
    end
    return false
  end
  return true
end

function M:send(text)
  if not self:_guard_pane("send") then return end
  local function send()
    exec({ "herdr", "pane", "send-text", self.herdr_pane_id, text }, { notify = true })
  end
  if self.tool.mux_focus then
    exec({ "herdr", "pane", "send-keys", self.herdr_pane_id, "Escape", "[", "I" }, { notify = false })
    vim.defer_fn(send, 50)
  else
    send()
  end
end

function M:submit()
  if not self:_guard_pane("submit") then return end
  exec({ "herdr", "pane", "send-keys", self.herdr_pane_id, "Enter" }, { notify = true })
end

function M:dump()
  local Config = require("sidekick.config")
  local n = Config.cli.mux.dump or 1000
  local lines, raw = exec({ "herdr", "pane", "read", self.herdr_pane_id, "--lines", tostring(n), "--format", "ansi" }, {
    notify = false,
  })
  return raw
end

---Fetch label maps for workspaces and tabs in the current herdr session.
---Cached per-process to avoid extra CLI calls on each sessions() invocation.
---@return table<string,string>, table<string,string>  workspace_id->label, tab_id->label
local _ws_labels, _tab_labels
local function label_maps()
  if _ws_labels and _tab_labels then
    return _ws_labels, _tab_labels
  end
  _ws_labels, _tab_labels = {}, {}

  local ws_decoded = json({ "herdr", "workspace", "list" }, { notify = false })
  if type(ws_decoded) == "table" then
    local ws = (ws_decoded.result and ws_decoded.result.workspaces) or ws_decoded.workspaces or {}
    for _, w in ipairs(ws) do
      if w.workspace_id and w.label then
        _ws_labels[w.workspace_id] = w.label
      end
    end
  end

  local tab_decoded = json({ "herdr", "tab", "list" }, { notify = false })
  if type(tab_decoded) == "table" then
    local tabs = (tab_decoded.result and tab_decoded.result.tabs) or tab_decoded.tabs or {}
    for _, t in ipairs(tabs) do
      if t.tab_id and t.label then
        _tab_labels[t.tab_id] = t.label
      end
    end
  end

  return _ws_labels, _tab_labels
end

---@return sidekick.cli.session.State[]
function M.sessions()
  local Config = require("sidekick.config")
  local decoded = json({ "herdr", "agent", "list" }, { notify = false })
  if type(decoded) ~= "table" then
    return {}
  end
  local agents = (decoded.result and decoded.result.agents) or decoded.agents or {}
  local tools = Config.tools()
  local ws_labels, tab_labels = label_maps()
  local ret = {} ---@type sidekick.cli.session.State[]
  for _, a in ipairs(agents) do
    local name = a.agent or a.name
    local tool = tools[name]
    if tool then
      local cwd = a.foreground_cwd or a.cwd
      ---@type sidekick.cli.session.State
      local state = {
        id = "herdr " .. a.pane_id,
        cwd = cwd,
        tool = tool,
        backend = "herdr",
        started = true,
        mux_session = a.workspace_id,
        pids = {},
        -- herdr-specific labels surfaced in the UI
        herdr_workspace_id = a.workspace_id,
        herdr_workspace_label = a.workspace_id and ws_labels[a.workspace_id] or nil,
        herdr_tab_id = a.tab_id,
        herdr_tab_label = a.tab_id and tab_labels[a.tab_id] or nil,
      }
      ret[#ret + 1] = state
    end
  end
  return ret
end

---Exposed for tests and for the UI extension: returns the in-memory label maps.
---@return table<string,string>, table<string,string>
function M.label_maps()
  return label_maps()
end

---Reset the cached label maps. Useful for tests.
function M._reset_label_cache()
  _ws_labels, _tab_labels = nil, nil
end

return M

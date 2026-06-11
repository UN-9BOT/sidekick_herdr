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
  -- We do NOT return a Cmd here. Returning a Cmd would make sidekick wrap
  -- the call in a `jobstart({term=true})` terminal buffer; instead we want
  -- the tool to live in a real herdr pane from the start, and have
  -- `M:send` / `M:submit` route text into that pane via `herdr pane send-text`.
  -- Returning nil makes `Session.attach` skip the terminal wrapper and
  -- mark `self` as the attached session directly.
  --
  -- However, the agent has to actually exist in herdr first. Invoke
  -- `herdr agent start` synchronously (it returns once the pane is up)
  -- and then resolve the pane id so subsequent `send`/`submit` calls work.
  self:_spawn_agent()
  return nil
end

---@return sidekick.cli.terminal.Cmd?
function M:attach()
  -- Already started: nothing to do. Returning nil keeps sidekick from
  -- opening a second terminal window.
  return nil
end

---Run `herdr agent start` for this session's tool synchronously. No-op
---when the pane is already known.
function M:_spawn_agent()
  if self.herdr_pane_id and self.herdr_pane_id ~= "" then
    return
  end
  local args = { "herdr", "agent", "start", self.tool.name, "--cwd", self.cwd, "--no-focus", "--" }
  for _, c in ipairs(self.tool.cmd) do
    args[#args + 1] = c
  end
  local quoted = {} ---@type string[]
  for _, a in ipairs(args) do
    quoted[#quoted + 1] = vim.fn.shellescape(a)
  end
  local merged_env = vim.tbl_extend("force", env(), {
    HERDR = false,
    HERDR_CONFIG_PATH = false,
  })
  -- Block until herdr has created the pane. `herdr agent start` returns
  -- only after the pane is registered, so the very next `herdr agent list`
  -- call should find it.
  local cmd = { "sh", "-c", table.concat(quoted, " ") .. " >/dev/null 2>&1" }
  local result = vim.system(cmd, { env = merged_env, text = true }):wait()
  if result.code ~= 0 then
    local ok, Util = pcall(require, "sidekick.util")
    if ok then
      local err = (result.stderr or ""):gsub("\\n", " ")
      Util.error(("sidekick_herdr: herdr agent start failed (code=%d): %s"):format(result.code, err))
    end
    return
  end
  self.started = true
  self:_ensure_pane_resolved(10, 100)
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

---@param max_attempts? integer
---@param delay_ms? integer
---@return boolean ok
function M:_ensure_pane_resolved(max_attempts, delay_ms)
  if self.herdr_pane_id and self.herdr_pane_id ~= "" then
    return true
  end
  max_attempts = max_attempts or 5
  delay_ms = delay_ms or 200
  for _ = 1, max_attempts do
    if self:resolve_pane() then
      return true
    end
    vim.wait(delay_ms, function() return false end)
  end
  return false
end

function M:send(text)
  if not self:_ensure_pane_resolved() then
    local ok, Util = pcall(require, "sidekick.util")
    if ok then
      Util.warn(("sidekick_herdr: cannot send — no herdr pane found for tool `%s` in cwd `%s`. " ..
        "Is `herdr agent list` showing it? If you just attached, give herdr a moment to register the pane."):format(self.tool.name, self.cwd))
    end
    return
  end
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
  if not self:_ensure_pane_resolved() then
    local ok, Util = pcall(require, "sidekick.util")
    if ok then
      Util.warn("sidekick_herdr: cannot submit — no herdr pane resolved.")
    end
    return
  end
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
  local Session = require("sidekick.cli.session")
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
      -- Use the same sid that Session.new({tool=name, cwd=cwd}) would
      -- produce. This is critical: sidekick stores `M._attached[session.id]`
      -- and prunes entries whose id does not show up in `backend:sessions()`.
      -- If we returned a different id (e.g. "herdr <pane_id>") the
      -- attach entry would be wiped on the next discovery pass and the
      -- next `send` would re-open the picker.
      local sid = Session.sid({ tool = name, cwd = cwd })
      ---@type sidekick.cli.session.State
      local state = {
        id = sid,
        cwd = cwd,
        tool = tool,
        backend = "herdr",
        started = true,
        mux_session = a.workspace_id,
        pids = {},
        -- herdr-specific labels surfaced in the UI
        herdr_pane_id = a.pane_id,
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

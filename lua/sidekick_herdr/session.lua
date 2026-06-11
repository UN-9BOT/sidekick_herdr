---@class sidekick_herdr.Session: sidekick.cli.Session
---@field herdr_pane_id? string
---@field herdr_workspace_id? string
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
  if vim.tbl_isempty(env()) then
    return Util.exec(cmd, opts)
  end
  -- pass env to vim.system so HERDR_SOCKET_PATH / HERDR_* are honoured
  local merged = vim.tbl_extend("force", env(), opts.env or {})
  opts = vim.tbl_extend("force", { env = merged }, opts)
  opts.env = merged
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
  local cmd = { "herdr", "agent", "start", self.tool.name, "--cwd", self.cwd, "--no-focus", "--" }
  for _, c in ipairs(self.tool.cmd) do
    cmd[#cmd + 1] = c
  end
  return {
    cmd = cmd,
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

--- Resolve the freshly started pane id and workspace id.
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

function M:send(text)
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

---@return sidekick.cli.session.State[]
function M.sessions()
  local Config = require("sidekick.config")
  local decoded = json({ "herdr", "agent", "list" }, { notify = false })
  if type(decoded) ~= "table" then
    return {}
  end
  local agents = (decoded.result and decoded.result.agents) or decoded.agents or {}
  local tools = Config.tools()
  local ret = {} ---@type sidekick.cli.session.State[]
  for _, a in ipairs(agents) do
    local name = a.agent or a.name
    local tool = tools[name]
    if tool then
      local cwd = a.foreground_cwd or a.cwd
      ret[#ret + 1] = {
        id = "herdr " .. a.pane_id,
        cwd = cwd,
        tool = tool,
        mux_session = a.workspace_id,
        pids = {},
      }
    end
  end
  return ret
end

return M

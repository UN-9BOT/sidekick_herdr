local M = {}

M._registered = false

---@class sidekick_herdr.SetupOpts
---@field backend? string name to register (default: "herdr")
---@field binary? string executable name (default: "herdr")
---@field socket? string HERDR_SOCKET_PATH override; scopes every herdr CLI call to one session
---@field config_path? string HERDR_CONFIG_PATH override

---@type sidekick_herdr.SetupOpts
M.opts = { backend = "herdr", binary = "herdr" }

---@return table<string, string|false>
function M.env()
  local e = {}
  if M.opts.socket then
    e.HERDR_SOCKET_PATH = M.opts.socket
  elseif vim.env.HERDR_SOCKET_PATH and vim.env.HERDR_SOCKET_PATH ~= "" then
    e.HERDR_SOCKET_PATH = vim.env.HERDR_SOCKET_PATH
  end
  if M.opts.config_path then
    e.HERDR_CONFIG_PATH = M.opts.config_path
  elseif vim.env.HERDR_CONFIG_PATH and vim.env.HERDR_CONFIG_PATH ~= "" then
    e.HERDR_CONFIG_PATH = vim.env.HERDR_CONFIG_PATH
  end
  return e
end

---Monkey-patch sidekick.cli.ui.select.format to append herdr workspace/tab labels
---for sessions whose backend is `herdr`. Idempotent.
function M._patch_select()
  local ok, Select = pcall(require, "sidekick.cli.ui.select")
  if not ok or not Select or not Select.format or Select._herdr_patched then
    return
  end
  local original = Select.format
  ---@diagnostic disable-next-line: duplicate-set-field
  Select.format = function(state, picker)
    local ret = original(state, picker)
    local session = state and state.session
    if session and session.backend == "herdr" then
      local ws = session.herdr_workspace_label
      local tab = session.herdr_tab_label
      if ws or tab then
        local label = string.format("  ws=%s tab=%s", tostring(ws or "?"), tostring(tab or "?"))
        ret[#ret + 1] = { label, "Comment" }
      end
    end
    return ret
  end
  Select._herdr_patched = true
end

---@param opts? sidekick_herdr.SetupOpts
function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})

  if vim.fn.executable(M.opts.binary or "herdr") ~= 1 then
    local ok_util, Util = pcall(require, "sidekick.util")
    if ok_util then
      Util.warn({
        ("sidekick_herdr: executable `%s` not found in PATH"):format(M.opts.binary or "herdr"),
        "Install herdr or set `binary` in setup().",
      })
    end
    return
  end

  local ok_session, Session = pcall(require, "sidekick.cli.session")
  if not ok_session then
    return
  end

  local ok_config, Config = pcall(require, "sidekick.config")
  if ok_config then
    pcall(function()
      Config.cli.mux.backend = M.opts.backend
    end)
  end

  if M._registered then
    return
  end
  M._registered = true
  Session.register(M.opts.backend, require("sidekick_herdr.session"))
  M._patch_select()
end

return M

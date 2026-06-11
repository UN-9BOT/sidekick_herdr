local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local plugin_root = vim.fn.fnamemodify(script_dir .. "/..", ":p")
vim.opt.rtp:prepend(plugin_root)

local function expand_home(p)
  if p:sub(1, 2) == "~/" then
    return vim.fn.expand("~") .. p:sub(2)
  end
  return p
end

local function add(path)
  local abs = vim.fn.fnamemodify(expand_home(path), ":p"):gsub("/$", "")
  if vim.fn.isdirectory(abs) == 1 then
    vim.opt.rtp:append(abs)
    package.path = package.path .. ";" .. abs .. "/lua/?.lua" .. ";" .. abs .. "/lua/?/init.lua"
  else
    io.stderr:write("missing: " .. abs .. "\n")
  end
end
add("~/.local/share/nvim/lazy/plenary.nvim")
add("~/.local/share/nvim/lazy/sidekick.nvim")

package.path = package.path
  .. ";"
  .. plugin_root .. "/lua/?.lua"
  .. ";"
  .. plugin_root .. "/lua/?/init.lua"

require("plenary.busted")

local arg = _G.arg or {}
local target = arg[1]
if target then
  require("plenary.busted").run(target)
end

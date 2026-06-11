if vim.g.loaded_sidekick_herdr == 1 then
  return
end
vim.g.loaded_sidekick_herdr = 1

vim.api.nvim_create_user_command("SidekickHerdr", function(cmd)
  local action = cmd.args
  if action == "status" then
    local ok, Session = pcall(require, "sidekick.cli.session")
    if ok and Session.backends.herdr then
      vim.notify("sidekick_herdr: registered", vim.log.levels.INFO)
    else
      vim.notify("sidekick_herdr: NOT registered (call setup() first)", vim.log.levels.WARN)
    end
  else
    vim.notify("sidekick_herdr: unknown action '" .. tostring(action) .. "' (try: status)", vim.log.levels.WARN)
  end
end, {
  nargs = 1,
  complete = function()
    return { "status" }
  end,
  desc = "sidekick_herdr: backend status",
})

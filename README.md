# sidekick_herdr

Herdr multiplexer backend for [sidekick.nvim](https://github.com/folke/sidekick.nvim).

Sidekick.nvim is a Neovim plugin for AI CLI tools. It ships with built-in support
for `tmux` and `zellij` as session multiplexers (`sidekick.cli.session.tmux` /
`zellij`). This plugin adds `herdr` — a Rust-based terminal workspace manager for AI
coding agents — to that list, **without forking sidekick**.

## Requirements

- Neovim ≥ 0.10
- [sidekick.nvim](https://github.com/folke/sidekick.nvim) — the plugin being extended
- [herdr](https://herdr.dev) ≥ 0.6.9 — must be on `$PATH` (`herdr --version`)

## Installation (lazy.nvim)

```lua
{
  "folke/sidekick.nvim", -- required
},
{
  dir = "/home/unbot/code/pets/sidekick_herdr_root/sidekick_herdr", -- local checkout
  dependencies = { "folke/sidekick.nvim" },
  config = function()
    require("sidekick_herdr").setup({})
  end,
}
```

`setup({})` is idempotent and safe to call multiple times. It:

1. Warns if `herdr` is missing from `$PATH`.
2. Registers a new session backend named `herdr` in `require("sidekick.cli.session")`.
3. Sets `require("sidekick.config").cli.mux.backend = "herdr"` so sidekick routes
   CLI sessions through the new backend.

## Configuration

`require("sidekick_herdr").setup({ ... })` accepts:

| key            | type     | default  | description                                                |
| -------------- | -------- | -------- | ---------------------------------------------------------- |
| `backend`      | `string` | `"herdr"`| name to register in `sidekick.cli.session.backends`        |
| `binary`       | `string` | `"herdr"`| executable name to look for in `$PATH`                     |
| `socket`       | `string?`| `nil`    | path to herdr's per-session API socket                     |
| `config_path`  | `string?`| `nil`    | `HERDR_CONFIG_PATH` override (e.g. for nested-herdr tests) |

`socket` and `config_path` are forwarded as `HERDR_SOCKET_PATH` / `HERDR_CONFIG_PATH`
to every `herdr` CLI invocation made by the backend. This scopes discovery and
`pane send`/`pane read` calls to a single herdr session — important when the host
has multiple herdr servers running.

If unset, the backend falls back to whatever `HERDR_SOCKET_PATH` /
`HERDR_CONFIG_PATH` is already in the environment.

## What it does

Once `setup()` runs, every Sidekick CLI tool (claude, codex, copilot, …) starts
inside an existing or new herdr pane in the current workspace. The agent name in
herdr is the tool name (`tool.name`).

### CLI mapping

| Sidekick call            | herdr command                                                                       |
| ------------------------ | ----------------------------------------------------------------------------------- |
| `start`                  | `herdr agent start <tool.name> --cwd <cwd> --no-focus -- <tool.cmd...>`             |
| `send`                   | `herdr pane send-text <pane_id> <text>` (with optional `Escape [, I` focus prelude) |
| `submit`                 | `herdr pane send-keys <pane_id> Enter`                                              |
| `dump`                   | `herdr pane read <pane_id> --lines <Config.cli.mux.dump> --format ansi`             |
| `is_running`             | `herdr pane get <pane_id>`                                                          |
| discovery (`sessions()`) | `herdr agent list`, filtered by sidekick tool names                                 |

## Known limitations

- **Validation warning**: `sidekick.config` validates `cli.mux.backend` against
  `{"tmux", "zellij"}`. Setting `backend = "herdr"` may print a one-time warning
  during sidekick `setup()`. The value is still applied and works. To silence the
  warning upstream, add `"herdr"` to the whitelist at
  `lua/sidekick/config.lua:225`.
- **PIDs**: herdr does not expose pane PIDs, so the sidekick session state always
  has an empty `pids = {}` list. This is fine for sidekick's UI/dedup.
- **Fresh sessions**: until herdr's agent detection has had a chance to inspect a
  pane, `herdr agent list` reports the agent under the `name` field (not `agent`).
  The backend matches either.

## Commands

- `:SidekickHerdr status` — prints whether the `herdr` backend is registered.

## Development

Run the full test suite (unit + e2e):

```bash
./tests/run.sh
```

Unit tests use `plenary.busted` and stub `sidekick.util.exec`. No live herdr
required; they always run.

E2E tests are bash scripts that follow the pattern from `herdr-neolazygit/tests/`:

- each test gets a unique herdr session (`shk-<pid>-<rand>`),
- sessions are started with `setsid herdr --session <name> &
  HERDR_CONFIG_PATH=<tmp>/herdr.toml` (the `toml` enables `allow_nested`),
- every test calls `trap stop_test_session EXIT`, which runs
  `herdr session stop` + `herdr session delete` + `rm -rf` on the session dir,
- so the host's `default` herdr session is never touched.

If `herdr --version` succeeds, e2e tests auto-run. Force them with `HERDR_E2E=1
./tests/run.sh` or skip them with `HERDR_E2E=0`.

## File layout

```
sidekick_herdr/
├── README.md
├── plugin/sidekick_herdr.lua            # :SidekickHerdr command
├── lua/sidekick_herdr/init.lua          # setup({...})
├── lua/sidekick_herdr/session.lua       # sidekick.cli.Session backend
└── tests/
    ├── run.sh                           # entry point
    ├── minit.lua                        # unit-test bootstrap (plenary.busted)
    ├── _lib.bash                        # bash test helpers (per-session herdr)
    ├── test-setup.bash                  # e2e: setup({socket=...}) registers backend
    ├── test-sessions.bash               # e2e: Backend.sessions() discovers agent
    ├── test-send-dump.bash              # e2e: Backend.send() + dump() roundtrip
    └── spec/session_spec.lua            # 15 unit tests (plenary.busted)
```

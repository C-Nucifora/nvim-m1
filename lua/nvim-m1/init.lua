--- nvim-m1: single-call setup for M1 script (`.m1scr`) support in Neovim.
---
--- Wires tree-sitter highlighting, the m1-lsp language server, format-on-save
--- (m1-fmt) and standalone linting (m1-lint) — the Neovim equivalent of
--- m1-vscode. Optional integrations (conform.nvim, nvim-lint, blink.cmp) are
--- used when present and degrade gracefully when absent.
---
---     require("nvim-m1").setup()
---
local config = require("nvim-m1.config")
local treesitter = require("nvim-m1.treesitter")
local lsp = require("nvim-m1.lsp")
local format = require("nvim-m1.format")
local lint = require("nvim-m1.lint")
local project = require("nvim-m1.project")
local install = require("nvim-m1.install")

local M = {}

--- The resolved configuration from the last setup() call.
---@type NvimM1Config?
M.config = nil

--- Project-verb command names registered through proj_cmd() (init.lua), mapped
--- to the `desc` the helper produced. Routing every single-argument m1-project
--- verb through that one helper is what guarantees the `M.config or
--- config.defaults` fallback can't be forgotten per verb (#69); this table lets
--- tests assert nothing slipped back to a hand-rolled registration without
--- introspecting Neovim's command registry (whose `definition` field does not
--- carry a Lua command's `desc` on recent Neovim).
---@type table<string, string>
M._proj_cmds = {}

--- Register the m1scr/m1prj filetypes. Safe to call repeatedly and before
--- setup() (the ftdetect/ and plugin/ shims call it so `ft = "m1scr"` lazy
--- triggers fire).
function M.register_filetypes()
  vim.filetype.add({ extension = { m1scr = "m1scr", m1prj = "m1prj" } })
end

--- Start tree-sitter on the given buffer and remember it for FileType events.
---@param cfg NvimM1Config
local function wire_buffers(cfg)
  if not cfg.treesitter then
    return
  end
  local group = vim.api.nvim_create_augroup("NvimM1Buffer", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "m1scr",
    desc = "nvim-m1: start tree-sitter",
    callback = function(args)
      treesitter.start(args.buf)
    end,
  })

  -- .m1prj is XML; give it basic XML highlighting (the LSP attaches for
  -- rename-from-declaration, but publishes no diagnostics for it).
  if cfg.attach_m1prj then
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = "m1prj",
      desc = "nvim-m1: XML highlighting for the project file",
      callback = function()
        vim.bo.syntax = "xml"
      end,
    })
  end

  -- Buffers already open at setup() time predate this autocmd — including the
  -- very buffer whose FileType event lazy-loaded the plugin (e.g. opening a
  -- `Project.m1prj` directly with `ft = { "m1scr", "m1prj" }`). Re-apply by
  -- filename so highlighting/XML start without needing a second file.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("%.m1scr$") then
        if vim.bo[buf].filetype ~= "m1scr" then
          vim.bo[buf].filetype = "m1scr"
        else
          treesitter.start(buf)
        end
      elseif cfg.attach_m1prj and name:match("%.m1prj$") then
        if vim.bo[buf].filetype ~= "m1prj" then
          vim.bo[buf].filetype = "m1prj"
        end
        -- Defer so we win the race with Neovim's own FileType->syntax handler
        -- for the buffer whose FileType event lazy-loaded the plugin.
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            vim.bo[buf].syntax = "xml"
          end
        end)
      end
    end
  end
end

--- Generate a default `m1-tools.toml` in the project root by running the
--- server's `--scaffold-config` (so the file matches the installed tool
--- versions and never drifts), then open it. The same config the m1-vscode
--- "Generate m1-tools.toml" command produces — shared via the server.
---@param cfg NvimM1Config
local function generate_config(cfg)
  local bin = lsp.resolve_cmd(cfg)
  if not bin then
    vim.notify("nvim-m1: m1-lsp not found (set opts.server_path)", vim.log.levels.ERROR)
    return
  end
  -- Place it at the M1 project root (nearest Project.m1prj above the buffer),
  -- else the current working directory. Shares project.lua's one discovery rule.
  local marker = project.project_file()
  local root = marker and vim.fs.dirname(marker) or vim.fn.getcwd()
  local target = root .. "/m1-tools.toml"

  if vim.fn.filereadable(target) == 1 then
    local answer = vim.fn.confirm(
      "m1-tools.toml already exists. Overwrite with defaults?",
      "&Yes\n&No",
      2
    )
    if answer ~= 1 then
      return
    end
  end

  -- :wait() pumps the event loop instead of hard-blocking, and the timeout
  -- turns a hung server into a clean error rather than a freeze (#68). The
  -- scaffolded config is needed synchronously to write the file below.
  local ran, res = pcall(function()
    return vim.system({ bin, "--scaffold-config" }, { text = true }):wait(10000)
  end)
  if not ran or res.code ~= 0 then
    local detail = ran and (res.stderr or res.stdout or "") or "timed out"
    vim.notify("nvim-m1: --scaffold-config failed: " .. detail, vim.log.levels.ERROR)
    return
  end
  local out = res.stdout or ""

  local fh, err = io.open(target, "w")
  if not fh then
    vim.notify(
      "nvim-m1: cannot write " .. target .. ": " .. (err or "?"),
      vim.log.levels.ERROR
    )
    return
  end
  fh:write(out)
  fh:close()
  vim.cmd("edit " .. vim.fn.fnameescape(target))
  vim.notify("nvim-m1: generated " .. target)
end

--- Convenience user commands and keymaps.
local function user_commands()
  vim.api.nvim_create_user_command("M1Format", function()
    format.format(0, M.config or config.defaults)
  end, { desc = "nvim-m1: format the current buffer" })

  vim.api.nvim_create_user_command("M1FormatToggle", function()
    vim.g.nvim_m1_format_on_save = not vim.g.nvim_m1_format_on_save
    vim.notify(
      "M1 format-on-save: " .. (vim.g.nvim_m1_format_on_save and "ON" or "OFF")
    )
  end, { desc = "nvim-m1: toggle format-on-save" })

  vim.api.nvim_create_user_command("M1Lint", function()
    lint.lint(0)
  end, { desc = "nvim-m1: lint the current buffer" })

  vim.api.nvim_create_user_command("M1GenerateConfig", function()
    generate_config(M.config or config.defaults)
  end, {
    desc = "nvim-m1: write a default m1-tools.toml to the project root",
  })

  -- Register a project command that always passes the resolved config, falling
  -- back to config.defaults when invoked before setup() (M.config is nil until
  -- then). Loop-driven so the fallback can't be forgotten per verb — #69 was two
  -- hand-rolled commands (M1SetType/M1SetUnit) that passed raw M.config and so
  -- indexed nil pre-setup; routing every verb through here makes that impossible.
  -- `suffix` overrides the default " (m1-project)" parenthetical for the rare
  -- verb that needs an extra hint (e.g. M1DeleteComponent confirms first).
  local function proj_cmd(name, fn, desc, suffix)
    local full = "nvim-m1: " .. desc .. (suffix or " (m1-project)")
    M._proj_cmds[name] = full
    vim.api.nvim_create_user_command(name, function()
      project[fn](M.config or config.defaults)
    end, { desc = full })
  end

  proj_cmd("M1CreateChannel", "create_channel", "create a channel in Project.m1prj")
  proj_cmd("M1SetSecurity", "set_security", "set a component's security level")
  proj_cmd("M1SetType", "set_type", "set a component's storage type")
  proj_cmd("M1SetUnit", "set_unit", "set a component's display unit")
  proj_cmd("M1SetCallRate", "set_call_rate", "set a script's execution rate")

  -- #51: the m1-project verbs added through v0.7.0 (create-group, delete/rename-component, validate).
  proj_cmd("M1CreateGroup", "create_group", "create a group in Project.m1prj")
  proj_cmd(
    "M1DeleteComponent",
    "delete_component",
    "delete a component",
    " (m1-project, confirms first)"
  )
  proj_cmd(
    "M1RenameComponent",
    "rename_component",
    "rename a component + its trigger references"
  )
  proj_cmd(
    "M1ValidateProject",
    "validate",
    "validate Project.m1prj into the quickfix list"
  )
  -- #102: the pre-competition security-matrix audit view (parity with
  -- m1-vscode's m1.showSecurityMatrix). Renders into a read-only scratch
  -- buffer, so the suffix notes it's a view rather than a mutation.
  proj_cmd(
    "M1SecurityMatrix",
    "security_matrix",
    "show the secured-component security matrix",
    " (m1-project, audit view)"
  )

  -- #61: the remaining m1-project verbs added through v0.7.0 (create-parameter/function, set-quantity/format/dps/display-range/validation, add/remove-tag).
  proj_cmd(
    "M1CreateParameter",
    "create_parameter",
    "create a parameter in Project.m1prj"
  )
  proj_cmd(
    "M1CreateFunction",
    "create_function",
    "create a (calculate-on-demand) function"
  )
  proj_cmd(
    "M1CreateScheduledFunction",
    "create_scheduled_function",
    "create a scheduled function"
  )
  proj_cmd("M1SetQuantity", "set_quantity", "set a component's physical quantity")
  proj_cmd(
    "M1SetValidation",
    "set_validation",
    "set a parameter's validation bounds (T043 remedy)"
  )
  proj_cmd("M1SetFormat", "set_format", "set a component's display format")
  proj_cmd("M1SetDps", "set_dps", "set a component's display decimal places")
  proj_cmd("M1SetDisplayRange", "set_display_range", "set a component's display range")
  proj_cmd("M1AddTag", "add_tag", "add a System/Type tag to a component (T092 remedy)")
  proj_cmd("M1RemoveTag", "remove_tag", "remove a tag from a component")

  -- #76: the m1-project create-constant / create-table verbs (pinned at v0.7.0).
  proj_cmd("M1CreateConstant", "create_constant", "create a constant in Project.m1prj")
  proj_cmd("M1CreateTable", "create_table", "create a 1-3 axis table in Project.m1prj")

  vim.api.nvim_create_user_command(
    "M1Install",
    function()
      M._install_tools_async()
    end,
    { desc = "nvim-m1: download the bundled M1 toolchain (m1-lsp/fmt/lint/project)" }
  )

  -- :M1Update is an alias — install always fetches the pinned versions.
  vim.api.nvim_create_user_command(
    "M1Update",
    function()
      M._install_tools_async()
    end,
    { desc = "nvim-m1: re-download the bundled M1 toolchain at the pinned versions" }
  )

  -- Parity with m1-vscode's `m1.restartServer`. A live m1-lsp keeps running
  -- across a toolchain update, so stale behaviour after :M1Update needs a full
  -- stop+re-attach to cycle the process — and on the native (0.11+) LSP path
  -- this plugin prefers, nvim-lspconfig's :LspRestart isn't available. This
  -- command works on every supported Neovim.
  vim.api.nvim_create_user_command("M1RestartServer", function()
    local ok, reason = lsp.restart(M.config or config.defaults)
    if ok then
      vim.notify("nvim-m1: m1-lsp restarted")
    else
      vim.notify(
        "nvim-m1: could not restart m1-lsp: " .. (reason or "unknown"),
        vim.log.levels.ERROR
      )
    end
  end, { desc = "nvim-m1: restart the m1-lsp server (use after :M1Update)" })
end

--- Download the given tools (default: all) WITHOUT blocking the editor, then
--- (re)register the language server: `vim.lsp.enable` (0.11+) attaches the
--- freshly-installed m1-lsp to already-open M1 buffers, so the toolchain
--- repair needs no `:e` or restart. Shared by :M1Install/:M1Update and the
--- first-open self-heal (#65).
---@param tools? string[]
function M._install_tools_async(tools)
  install.install_async(tools, function(ok)
    if ok and M.config and M.config.lsp then
      require("nvim-m1.lsp").setup(M.config)
    end
  end)
end

--- Whether setup() has already run its once-only side effects (the bundle
--- self-heal). Filetype/command/augroup registration is overwrite-safe and
--- re-runs every call; the self-heal must not, or repeated setup() calls would
--- re-schedule overlapping install.install() runs that race each other. (#26)
--- This guards only repeated setup() calls; a self-heal overlapping a manual
--- :M1Install/:M1Update is serialised at the install layer by the in-flight
--- guard in install.install_async.
M._setup_done = false

--- Configure M1 script support. Idempotent.
---@param opts? table  See |NvimM1Config|.
function M.setup(opts)
  local cfg = config.resolve(opts)
  M.config = cfg

  M.register_filetypes()
  treesitter.register(cfg)
  wire_buffers(cfg)

  if cfg.lsp then
    lsp.setup(cfg)
    require("nvim-m1.codelens").setup(cfg)
  end
  -- Always register the format/lint backends so :M1Format and :M1Lint work; the
  -- on-save autocmds are gated internally by cfg.format_on_save / lint_on_save.
  format.setup(cfg)
  lint.setup(cfg)

  user_commands()

  -- If the language server isn't found on $PATH or among the bundled binaries,
  -- nudge the user to install it. The lazy `build` hook normally does this on
  -- install/update; this covers a setup without the hook.
  if cfg.lsp and not lsp.resolve_cmd(cfg) then
    vim.schedule(function()
      vim.notify(
        "nvim-m1: m1-lsp not found — run :M1Install to download the bundled toolchain "
          .. "(or set opts.server_path). See :checkhealth nvim-m1.",
        vim.log.levels.WARN
      )
    end)
  end

  -- Self-heal a stale bundle: if the on-disk binaries trail the pinned versions
  -- (e.g. a `Lazy sync` whose build hook ran against an older pin), reinstall
  -- just the stale tools so opening an M1 file repairs the toolchain with no
  -- manual :M1Install. Only fires when binaries are actually bundled + behind.
  -- (#26)
  --
  -- Guarded to run at most once per session: repeated setup() calls (or a setup
  -- call landing while an earlier scheduled heal is still downloading) would
  -- otherwise re-schedule overlapping install.install() runs that race each
  -- other writing the same binaries/manifest. Filetype/command/augroup
  -- registration above is overwrite-safe and intentionally re-runs every call;
  -- only this one-shot heal needs the guard so the "Idempotent" claim holds.
  if not M._setup_done then
    M._setup_done = true
    local stale = install.stale_tools()
    if #stale > 0 then
      vim.schedule(function()
        vim.notify(
          ("nvim-m1: bundled toolchain out of date (%s) — refreshing to the pinned versions…"):format(
            table.concat(stale, ", ")
          ),
          vim.log.levels.INFO
        )
        -- Async: the downloads + provenance checks run off the UI thread, so
        -- the first .m1scr open no longer freezes for the whole refresh (#65).
        M._install_tools_async(stale)
      end)
    end
  end

  return M
end

return M

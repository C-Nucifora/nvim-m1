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

local M = {}

--- The resolved configuration from the last setup() call.
---@type NvimM1Config?
M.config = nil

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
  -- else the current working directory.
  local cur = vim.api.nvim_buf_get_name(0)
  local start = (cur ~= "" and vim.fs.dirname(cur)) or vim.fn.getcwd()
  local marker = vim.fs.find({ "Project.m1prj" }, { path = start, upward = true })[1]
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

  local out = vim.fn.system({ bin, "--scaffold-config" })
  if vim.v.shell_error ~= 0 then
    vim.notify("nvim-m1: --scaffold-config failed: " .. out, vim.log.levels.ERROR)
    return
  end

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

  vim.api.nvim_create_user_command("M1CreateChannel", function()
    project.create_channel(M.config or config.defaults)
  end, { desc = "nvim-m1: create a channel in Project.m1prj (m1-project)" })

  vim.api.nvim_create_user_command("M1SetSecurity", function()
    project.set_security(M.config or config.defaults)
  end, { desc = "nvim-m1: set a component's security level (m1-project)" })

  vim.api.nvim_create_user_command("M1SetCallRate", function()
    project.set_call_rate(M.config or config.defaults)
  end, { desc = "nvim-m1: set a script's execution rate (m1-project)" })

  vim.api.nvim_create_user_command(
    "M1Install",
    function()
      require("nvim-m1.install").install()
    end,
    { desc = "nvim-m1: build the bundled M1 toolchain from source (m1-lsp/fmt/lint/project)" }
  )

  -- :M1Update is an alias — install always builds the pinned versions.
  vim.api.nvim_create_user_command(
    "M1Update",
    function()
      require("nvim-m1.install").install()
    end,
    { desc = "nvim-m1: rebuild the bundled M1 toolchain from source at the pinned versions" }
  )
end

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
        "nvim-m1: m1-lsp not found — run :M1Install to build the bundled toolchain from source "
          .. "(or set opts.server_path). See :checkhealth nvim-m1.",
        vim.log.levels.WARN
      )
    end)
  end

  return M
end

return M

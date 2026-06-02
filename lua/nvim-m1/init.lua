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

  -- Buffers already open at setup() time (e.g. `nvim file.m1scr`) predate the
  -- extension->filetype mapping, so re-trigger by filename.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("%.m1scr$") then
        if vim.bo[buf].filetype ~= "m1scr" then
          vim.bo[buf].filetype = "m1scr"
        else
          treesitter.start(buf)
        end
      end
    end
  end
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
  return M
end

return M

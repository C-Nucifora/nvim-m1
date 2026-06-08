--- nvim-m1: formatting via m1-fmt.
---
--- If conform.nvim is installed, m1-fmt is registered as a conform formatter
--- (so :ConformInfo and manual `require("conform").format()` work). Otherwise
--- formatting falls back to the LSP, which m1-lsp also provides. Either way a
--- BufWritePre autocmd formats on save, gated by `vim.g.nvim_m1_format_on_save`
--- so it can be toggled at runtime.
local M = {}

local GROUP = "NvimM1Format"

--- conform formatter definition for m1-fmt (stdin, filename-aware). `command`
--- resolves at format time to the bundled binary when m1-fmt isn't on $PATH.
M.conform_formatter = {
  command = function()
    return require("nvim-m1.install").resolve("m1-fmt") or "m1-fmt"
  end,
  args = { "--stdin-filename", "$FILENAME" },
  stdin = true,
}

--- Register the m1-fmt conform formatter, if conform is present.
---@return boolean present  true if conform.nvim was found
local function register_conform()
  local ok, conform = pcall(require, "conform")
  if not ok then
    return false
  end
  -- Merge into existing conform config rather than clobbering the user's.
  conform.formatters = conform.formatters or {}
  conform.formatters.m1_fmt =
    vim.tbl_deep_extend("force", M.conform_formatter, conform.formatters.m1_fmt or {})
  conform.formatters_by_ft = conform.formatters_by_ft or {}
  conform.formatters_by_ft.m1scr = conform.formatters_by_ft.m1scr or { "m1_fmt" }
  return true
end

--- Format a buffer with whichever backend is available.
---@param bufnr integer
---@param cfg NvimM1Config
function M.format(bufnr, cfg)
  local ok, conform = pcall(require, "conform")
  if ok then
    conform.format({
      bufnr = bufnr,
      formatters = { "m1_fmt" },
      timeout_ms = cfg.format_timeout_ms,
    })
  else
    vim.lsp.buf.format({
      async = false,
      bufnr = bufnr,
      timeout_ms = cfg.format_timeout_ms,
    })
  end
end

--- Wire format-on-save for .m1scr buffers.
---@param cfg NvimM1Config
function M.setup(cfg)
  register_conform()

  -- setup() seeds the runtime gate from the config; :M1FormatToggle flips it at
  -- runtime. The gate is read at FIRE time (below), never snapshotted into
  -- whether the hook exists — so toggling on works even when the user started
  -- with format_on_save = false. (mirrors lint.lua's deferred-decision design)
  vim.g.nvim_m1_format_on_save = cfg.format_on_save

  -- Always (re)create the group and wire the BufWritePre hook. The hook itself
  -- is gated by `vim.g.nvim_m1_format_on_save` at fire time, so a setup with
  -- format_on_save = false simply leaves the gate off — :M1FormatToggle can then
  -- enable it without a re-setup. (Manual :M1Format works regardless.)
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    pattern = "*.m1scr",
    desc = "nvim-m1: format on save (gated by g:nvim_m1_format_on_save)",
    callback = function(args)
      if vim.g.nvim_m1_format_on_save then
        M.format(args.buf, cfg)
      end
    end,
  })
end

return M

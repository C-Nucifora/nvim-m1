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

  -- setup() is authoritative for the toggle; :M1FormatToggle overrides at runtime.
  vim.g.nvim_m1_format_on_save = cfg.format_on_save

  -- Always (re)create the group so disabling clears a previously-wired hook.
  -- Manual formatting (:M1Format) works regardless of the save hook.
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  if not cfg.format_on_save then
    return
  end

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    pattern = "*.m1scr",
    desc = "nvim-m1: format on save",
    callback = function(args)
      if vim.g.nvim_m1_format_on_save then
        M.format(args.buf, cfg)
      end
    end,
  })
end

return M

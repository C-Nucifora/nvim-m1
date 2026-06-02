--- nvim-m1: single-call setup for M1 script support in Neovim.
--- Wires nvim-treesitter, nvim-lspconfig, conform.nvim, and nvim-lint.
local M = {}

---@class NvimM1Opts
---@field server_path? string  Path to m1-lsp binary (default: $PATH / bundled)
---@field format_on_save? boolean  Enable format-on-save via conform.nvim (default: true)
---@field lint_on_save? boolean  Enable lint-on-save via nvim-lint (default: true)

local defaults = {
  server_path  = nil,
  format_on_save = true,
  lint_on_save   = true,
}

--- Register the m1 tree-sitter grammar with nvim-treesitter.
local function setup_treesitter()
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok then return end
  local cfg = parsers.get_parser_configs()
  if cfg.m1 then return end
  cfg.m1 = {
    install_info = {
      url    = "https://github.com/C-Nucifora/tree-sitter-m1",
      files  = { "src/parser.c", "src/scanner.c" },
      branch = "main",
    },
    filetype = "m1scr",
  }
  -- TODO: trigger TSInstall if not installed
end

--- Register m1-lsp with nvim-lspconfig and start the server.
---@param opts NvimM1Opts
local function setup_lsp(opts)
  local ok_lsp, lspconfig = pcall(require, "lspconfig")
  local ok_cfg, configs   = pcall(require, "lspconfig.configs")
  if not ok_lsp or not ok_cfg then return end

  if not configs.m1_lsp then
    configs.m1_lsp = {
      default_config = {
        cmd              = { opts.server_path or "m1-lsp" },
        filetypes        = { "m1scr" },
        root_dir         = lspconfig.util.root_pattern("Project.m1prj", ".git"),
        single_file_support = true,
      },
    }
  end
  lspconfig.m1_lsp.setup({})
end

--- Wire m1-fmt into conform.nvim for format-on-save.
local function setup_format()
  local ok, conform = pcall(require, "conform")
  if not ok then return end
  conform.setup({
    formatters_by_ft = { m1scr = { "m1_fmt" } },
    formatters = {
      m1_fmt = { command = "m1-fmt", args = { "--stdin-filepath", "$FILENAME" }, stdin = true },
    },
    format_on_save = { timeout_ms = 500, lsp_fallback = false },
  })
end

--- Wire m1-lint into nvim-lint for lint-on-save.
local function setup_lint()
  local ok, lint = pcall(require, "lint")
  if not ok then return end
  -- TODO: define m1-lint linter parser once m1-lint stabilises its output format
  lint.linters_by_ft = lint.linters_by_ft or {}
  lint.linters_by_ft.m1scr = { "m1_lint" }
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost" }, {
    pattern  = "*.m1scr",
    callback = function() lint.try_lint() end,
  })
end

---@param opts? NvimM1Opts
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts or {})

  -- File type detection
  vim.filetype.add({ extension = { m1scr = "m1scr" } })

  setup_treesitter()
  setup_lsp(opts)
  if opts.format_on_save then setup_format() end
  if opts.lint_on_save   then setup_lint()   end
end

return M

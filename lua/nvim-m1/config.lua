--- nvim-m1 configuration: defaults, merge, and normalisation.
---
--- The public option surface is intentionally flat and matches the keys
--- documented in the README (`server_path`, `format_on_save`, `lint_on_save`).
--- A handful of extra keys tune behaviour that the defaults already get right.
local M = {}

---@class NvimM1Config
---@field server_path? string        Path to the m1-lsp binary. nil = search $PATH for "m1-lsp".
---@field filetypes string[]         Script filetypes to wire (default: { "m1scr" }).
---@field attach_m1prj boolean       Also attach m1-lsp to Project.m1prj so a channel/parameter
---                                   can be renamed from its declaration (default: true).
---@field root_markers string[]      Files that mark a project root (default: { "Project.m1prj", ".git" }).
---@field treesitter boolean         Register + start the `m1` tree-sitter parser (default: true).
---@field auto_install_parser boolean  Run :TSInstall m1 if the parser is missing (default: true).
---@field lsp boolean                Register + enable m1-lsp (default: true).
---@field capabilities? table        LSP client capabilities (default: blink.cmp's if present, else stock).
---@field on_attach? fun(client:vim.lsp.Client, bufnr:integer)  Extra per-buffer LSP setup.
---@field settings? table            Unified m1-lsp config forwarded to the server (lint/format/
---                                   diagnostics), e.g. `{ lint = { max_line_length = 100 },
---                                   diagnostics = { ignore = { "T041" } } }`. A workspace
---                                   `m1-tools.toml` overrides these. See :M1GenerateConfig.
---@field format_on_save boolean     Format .m1scr buffers on write (default: true).
---@field format_timeout_ms integer  Format timeout (default: 5000).
---@field lint_on_save boolean       Lint .m1scr buffers on write (default: true).
---@field lint_on_insert_leave boolean  Also lint on InsertLeave (default: false).

---@type NvimM1Config
M.defaults = {
  server_path = nil,
  filetypes = { "m1scr" },
  attach_m1prj = true,
  root_markers = { "Project.m1prj", ".git" },

  treesitter = true,
  auto_install_parser = true,

  lsp = true,
  capabilities = nil,
  on_attach = nil,
  settings = {},

  format_on_save = true,
  format_timeout_ms = 5000,

  lint_on_save = true,
  lint_on_insert_leave = false,
}

--- Merge user opts over the defaults and validate the result.
---@param opts? table
---@return NvimM1Config
function M.resolve(opts)
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  vim.validate({
    server_path = { cfg.server_path, "string", true },
    filetypes = { cfg.filetypes, "table" },
    attach_m1prj = { cfg.attach_m1prj, "boolean" },
    root_markers = { cfg.root_markers, "table" },
    treesitter = { cfg.treesitter, "boolean" },
    auto_install_parser = { cfg.auto_install_parser, "boolean" },
    lsp = { cfg.lsp, "boolean" },
    capabilities = { cfg.capabilities, "table", true },
    on_attach = { cfg.on_attach, "function", true },
    settings = { cfg.settings, "table" },
    format_on_save = { cfg.format_on_save, "boolean" },
    format_timeout_ms = { cfg.format_timeout_ms, "number" },
    lint_on_save = { cfg.lint_on_save, "boolean" },
    lint_on_insert_leave = { cfg.lint_on_insert_leave, "boolean" },
  })

  -- The set of filetypes the LSP attaches to: scripts, plus the project file
  -- when attach_m1prj is on (rename a channel from its <Component> declaration).
  cfg.lsp_filetypes = vim.deepcopy(cfg.filetypes)
  if cfg.attach_m1prj and not vim.tbl_contains(cfg.lsp_filetypes, "m1prj") then
    table.insert(cfg.lsp_filetypes, "m1prj")
  end

  return cfg
end

return M

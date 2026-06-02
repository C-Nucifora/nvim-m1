--- nvim-m1: tree-sitter wiring for the `m1` grammar.
---
--- The grammar, queries (highlights/folds/indents/injections/locals) and the
--- `m1scr` runtime all live in tree-sitter-m1. This module only teaches
--- nvim-treesitter where to fetch/build the parser and starts highlighting on
--- m1scr buffers.
local M = {}

--- Register the `m1` parser config with nvim-treesitter (idempotent) and map
--- the `m1` language to the `m1scr` filetype.
---@param cfg NvimM1Config
---@return boolean registered  true if nvim-treesitter was present
function M.register(cfg)
  -- Map language -> filetype regardless of nvim-treesitter so a parser already
  -- on the runtimepath lights up m1scr buffers.
  pcall(vim.treesitter.language.register, "m1", "m1scr")

  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok then
    return false
  end

  -- nvim-treesitter exposes either get_parser_configs() (classic/master) or a
  -- writable table; support both shapes.
  local configs = type(parsers.get_parser_configs) == "function"
      and parsers.get_parser_configs()
    or parsers

  if not configs.m1 then
    configs.m1 = {
      install_info = {
        url = "https://github.com/C-Nucifora/tree-sitter-m1",
        files = { "src/parser.c", "src/scanner.c" },
        branch = "main",
      },
      filetype = "m1scr",
    }
  end

  if cfg.auto_install_parser and not M.parser_installed() then
    -- :TSInstall is a no-op once the compiled parser is on the rtp; guard it so
    -- a headless/missing-compiler environment never errors out of setup().
    pcall(vim.cmd, "silent! TSInstall m1")
  end

  return true
end

--- Whether a compiled `m1` parser is available to Neovim.
---@return boolean
function M.parser_installed()
  return pcall(vim.treesitter.language.add, "m1")
end

--- Start tree-sitter highlighting on a buffer (no-op if the parser is missing).
---@param bufnr integer
function M.start(bufnr)
  pcall(vim.treesitter.start, bufnr, "m1")
end

return M

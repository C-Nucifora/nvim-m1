-- Minimal init for headless plenary-busted runs.
--
-- Puts this plugin and its test deps on the runtimepath. plenary is located via
-- $PLENARY_PATH (set by scripts/test.sh) or the standard lazy.nvim data dir.
local here =
  vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

vim.opt.runtimepath:prepend(root)

local function add(path)
  if path ~= "" and vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:append(path)
    return true
  end
  return false
end

local plenary = vim.env.PLENARY_PATH or ""
if not add(plenary) then
  add(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
end

-- tree-sitter-m1 (the `m1` grammar + queries) on the rtp enables the parser
-- integration spec (tests/parser_spec.lua); without it that spec is pending.
-- Resolved from $TREE_SITTER_M1_PATH (set by CI / scripts/test.sh), the sibling
-- checkout in the m1-tools layout, or the lazy data dir.
local grammar = vim.env.TREE_SITTER_M1_PATH or ""
if not add(grammar) then
  if not add(vim.fn.fnamemodify(root, ":h") .. "/tree-sitter-m1") then
    add(vim.fn.stdpath("data") .. "/lazy/tree-sitter-m1")
  end
end

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")

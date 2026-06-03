--- Integration test: the `m1` parser actually compiles and highlights.
---
--- This guards the regression where nvim-m1 leaned on nvim-treesitter's legacy
--- `:TSInstall`/`install_info` path (dropped by the main-branch rewrite, now the
--- default) and so never built the parser — highlighting silently failed while
--- every unit spec still passed. The plain specs only cover graceful degradation
--- WITHOUT the grammar; this one requires the tree-sitter-m1 sources on the
--- runtimepath (CI checks them out; the dev layout uses the sibling
--- `../tree-sitter-m1`, wired by `tests/minimal_init.lua`) plus a C compiler,
--- then asserts real end-to-end highlighting.
local ts = require("nvim-m1.treesitter")

local function grammar_on_rtp()
  for _, p in ipairs(vim.api.nvim_get_runtime_file("src/parser.c", true)) do
    if p:match("tree%-sitter%-m1") then
      return true
    end
  end
  return false
end

local function have_compiler()
  return vim.fn.exepath("cc") ~= ""
    or vim.fn.exepath("gcc") ~= ""
    or vim.fn.exepath("clang") ~= ""
end

if not (grammar_on_rtp() and have_compiler()) then
  describe("nvim-m1.treesitter parser (integration)", function()
    pending("requires tree-sitter-m1 sources on the rtp + a C compiler")
  end)
  return
end

describe("nvim-m1.treesitter parser (integration)", function()
  local cfg = require("nvim-m1.config").defaults

  it("compiles and loads the `m1` parser from the grammar sources", function()
    assert.is_true(ts.register(cfg))
    assert.is_true(ts.parser_installed())
  end)

  it("highlights a .m1scr buffer (parser + queries actually wired)", function()
    ts.register(cfg)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "local count = 1;",
      "if (count eq 1)",
      "{",
      "\tcount += 1;",
      "}",
    })
    vim.bo[buf].filetype = "m1scr"

    ts.start(buf)
    assert.is_not_nil(
      vim.treesitter.highlighter.active[buf],
      "tree-sitter highlighter should be active on the m1scr buffer"
    )

    local q = vim.treesitter.query.get("m1", "highlights")
    assert.is_not_nil(q, "the m1 `highlights` query should be registered")

    local parser = assert(vim.treesitter.get_parser(buf, "m1"))
    local root = parser:parse()[1]:root()
    local captures = 0
    for _ in q:iter_captures(root, buf, 0, -1) do
      captures = captures + 1
    end
    assert.is_true(captures > 0, "the highlights query should produce captures")
  end)
end)

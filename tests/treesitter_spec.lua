--- Regression tests for nvim-m1.treesitter parser detection.
local ts = require("nvim-m1.treesitter")

describe("nvim-m1.treesitter", function()
  it("parser_installed() returns a boolean", function()
    assert.equals("boolean", type(ts.parser_installed()))
  end)

  it("parser_installed() is false when no `m1` parser is on the runtimepath", function()
    -- Regression: the old `return pcall(vim.treesitter.language.add, "m1")`
    -- returned pcall's success flag, so it was always true even with no parser
    -- — which made register() skip compilation and highlighting never started.
    -- `language.add` returns nil (not false, and without raising) when the
    -- parser is missing, so detection must check for an exact `true`.
    assert.is_false(ts.parser_installed())
  end)

  it(
    "register() does not error and reports no parser without a compiler/grammar",
    function()
      -- With neither the grammar sources nor a built parser on the rtp, register()
      -- must degrade gracefully (return false) rather than raise out of setup().
      local cfg = require("nvim-m1.config").defaults
      local ok, installed = pcall(ts.register, cfg)
      assert.is_true(ok)
      assert.equals("boolean", type(installed))
    end
  )
end)

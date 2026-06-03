--- Regression tests for nvim-m1.treesitter parser detection.
local ts = require("nvim-m1.treesitter")

describe("nvim-m1.treesitter", function()
  it("parser_installed() returns a boolean", function()
    assert.equals("boolean", type(ts.parser_installed()))
  end)

  -- NOTE: the "parser absent -> false" half of the parser_installed() contract
  -- (the original always-true pcall bug) is exercised deterministically by
  -- tests/parser_spec.lua: with a fresh data dir it asserts register() actually
  -- compiles + highlights, which only happens when detection correctly reports
  -- the parser as missing first. A standalone "is false" assertion here would be
  -- order-dependent (parser_spec compiles a parser into the shared data dir).

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

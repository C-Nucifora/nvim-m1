--- Regression: the conform.nvim formatter must use m1-fmt's real flag.
local format = require("nvim-m1.format")

describe("nvim-m1.format conform integration", function()
  it("passes --stdin-filename (m1-fmt's flag), not --stdin-filepath (#9)", function()
    local args = format.conform_formatter.args
    assert.equals("--stdin-filename", args[1])
    assert.equals("$FILENAME", args[2])
  end)
end)

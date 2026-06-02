local lint = require("nvim-m1.lint")

-- A synthetic m1-lint --format json report (schema version 2). No project data.
local REPORT = vim.json.encode({
  version = 2,
  files = {
    {
      path = "/tmp/sample.m1scr",
      syntax_errors = {
        {
          code = "syntax",
          severity = "error",
          message = "syntax error",
          range = {
            start = { line = 0, column = 0 },
            ["end"] = { line = 2, column = 3 },
          },
        },
      },
      diagnostics = {
        {
          code = "L006",
          name = "float-eq-comparison",
          severity = "error",
          message = "never compare floats with equality operators; use a tolerance check",
          range = {
            start = { line = 0, column = 0 },
            ["end"] = { line = 1, column = 10 },
          },
          fixable = false,
        },
        {
          code = "L004",
          name = "eq-operator-preferred",
          severity = "warning",
          message = "use `eq` instead of `==`",
          range = {
            start = { line = 1, column = 4 },
            ["end"] = { line = 1, column = 6 },
          },
          fixable = true,
        },
      },
    },
  },
  summary = { errors = 2, warnings = 1, files = 1 },
})

describe("nvim-m1.lint.parse", function()
  it("flattens syntax_errors and diagnostics into vim.diagnostic items", function()
    local items = lint.parse(REPORT)
    assert.equals(3, #items)
  end)

  it("maps positions 1:1 (0-indexed) and severities", function()
    local items = lint.parse(REPORT)
    -- syntax error comes first
    assert.equals(vim.diagnostic.severity.ERROR, items[1].severity)
    -- find the L004 entry
    local l004
    for _, d in ipairs(items) do
      if d.code == "L004" then
        l004 = d
      end
    end
    assert.is_not_nil(l004)
    assert.equals(1, l004.lnum)
    assert.equals(4, l004.col)
    assert.equals(1, l004.end_lnum)
    assert.equals(6, l004.end_col)
    assert.equals(vim.diagnostic.severity.WARN, l004.severity)
    assert.equals("m1-lint", l004.source)
  end)

  it("selects the matching file when several are reported", function()
    local multi = vim.json.encode({
      version = 2,
      files = {
        {
          path = "/tmp/a.m1scr",
          diagnostics = {
            {
              code = "L001",
              severity = "warning",
              range = {
                start = { line = 0, column = 0 },
                ["end"] = { line = 0, column = 1 },
              },
            },
          },
        },
        {
          path = "/tmp/b.m1scr",
          diagnostics = {
            {
              code = "L002",
              severity = "warning",
              range = {
                start = { line = 9, column = 0 },
                ["end"] = { line = 9, column = 1 },
              },
            },
          },
        },
      },
    })
    local items = lint.parse(multi, "/tmp/b.m1scr")
    assert.equals(1, #items)
    assert.equals("L002", items[1].code)
    assert.equals(9, items[1].lnum)
  end)

  it("is total on empty / malformed input", function()
    assert.same({}, lint.parse(""))
    assert.same({}, lint.parse("not json"))
    assert.same({}, lint.parse(vim.json.encode({ version = 2 })))
  end)
end)

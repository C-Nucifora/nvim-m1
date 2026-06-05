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

describe("nvim-m1.lint.lsp_attached (defer to the server, #25)", function()
  local client_name = require("nvim-m1.lsp").client_name
  local saved_get_clients

  before_each(function()
    saved_get_clients = vim.lsp.get_clients
  end)
  after_each(function()
    vim.lsp.get_clients = saved_get_clients
  end)

  it("is true when an m1lsp client is attached to the buffer", function()
    vim.lsp.get_clients = function()
      return { { name = client_name }, { name = "lua_ls" } }
    end
    assert.is_true(lint.lsp_attached(0))
  end)

  it("is false when only other servers are attached", function()
    vim.lsp.get_clients = function()
      return { { name = "lua_ls" } }
    end
    assert.is_false(lint.lsp_attached(0))
  end)

  it("is false when no client is attached", function()
    vim.lsp.get_clients = function()
      return {}
    end
    assert.is_false(lint.lsp_attached(0))
  end)
end)

describe("nvim-m1.lint.lint (no double-publish, #25)", function()
  local saved_get_clients, saved_system, saved_resolve
  local install = require("nvim-m1.install")
  local buf

  before_each(function()
    saved_get_clients = vim.lsp.get_clients
    saved_system = vim.system
    saved_resolve = install.resolve
    -- Make the standalone backend *reachable* so the only thing that can stop
    -- it is the LSP-attached guard (not a missing binary / unnamed buffer).
    install.resolve = function()
      return "/fake/m1-lint"
    end
    buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/dedup.m1scr")
  end)
  after_each(function()
    vim.lsp.get_clients = saved_get_clients
    vim.system = saved_system
    install.resolve = saved_resolve
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("does NOT run the standalone linter when m1lsp is attached", function()
    vim.lsp.get_clients = function()
      return { { name = require("nvim-m1.lsp").client_name } }
    end
    local ran = false
    vim.system = function()
      ran = true
      return { wait = function() end }
    end
    lint.lint(buf)
    vim.wait(50)
    assert.is_false(ran, "standalone linter must defer to m1-lsp's diagnostics")
  end)
end)

describe("nvim-m1.lint.setup autocmd gating (#25)", function()
  -- The runtime guard alone can't stop the BufReadPost hook: it fires before the
  -- async LSP attach, so the standalone linter must not be *wired* at all when
  -- m1-lsp will provide diagnostics.
  local lsp = require("nvim-m1.lsp")
  local saved_resolve

  local function autocmds()
    return vim.api.nvim_get_autocmds({ group = "NvimM1Lint" })
  end

  before_each(function()
    saved_resolve = lsp.resolve_cmd
  end)
  after_each(function()
    lsp.resolve_cmd = saved_resolve
  end)

  it("does NOT wire the save/read hook when m1-lsp will attach", function()
    lsp.resolve_cmd = function()
      return "/usr/bin/m1-lsp"
    end
    lint.setup({ lint_on_save = true, lsp = true })
    assert.equals(0, #autocmds())
  end)

  it("wires the save/read hook when the LSP is disabled", function()
    lsp.resolve_cmd = function()
      return "/usr/bin/m1-lsp"
    end
    lint.setup({ lint_on_save = true, lsp = false })
    assert.is_true(#autocmds() >= 1)
  end)

  it("wires the save/read hook as a fallback when m1-lsp is not found", function()
    lsp.resolve_cmd = function()
      return nil
    end
    lint.setup({ lint_on_save = true, lsp = true })
    assert.is_true(#autocmds() >= 1)
  end)
end)

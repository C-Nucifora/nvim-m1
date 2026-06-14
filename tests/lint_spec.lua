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

describe("nvim-m1.lint.setup autocmd gating (#25, deferred decision)", function()
  -- The hook is now ALWAYS wired when lint_on_save is set; whether it actually
  -- runs the standalone linter is decided at fire time by M.lsp_will_lint, so a
  -- later :M1Install (which makes m1-lsp resolvable) is honoured without a
  -- re-setup. The runtime guard still can't stop the BufReadPost hook firing
  -- before the async LSP attach — but the fire-time check resolves the server
  -- even before it attaches, so it steps aside correctly anyway.
  local lsp = require("nvim-m1.lsp")
  local saved_resolve

  -- Count only the save/read hook (the LspAttach cleanup handler is wired
  -- unconditionally now — see the "late LSP attach" describe — so a group-wide
  -- count would conflate the two).
  local function autocmds()
    return vim.api.nvim_get_autocmds({
      group = "NvimM1Lint",
      event = { "BufWritePost", "BufReadPost", "InsertLeave" },
    })
  end

  before_each(function()
    saved_resolve = lsp.resolve_cmd
  end)
  after_each(function()
    lsp.resolve_cmd = saved_resolve
  end)

  it("wires the save/read hook even when m1-lsp will attach", function()
    lsp.resolve_cmd = function()
      return "/usr/bin/m1-lsp"
    end
    lint.setup({ lint_on_save = true, lsp = true })
    assert.is_true(#autocmds() >= 1)
  end)

  it("does NOT wire the save/read hook when lint_on_save is disabled", function()
    lsp.resolve_cmd = function()
      return nil
    end
    lint.setup({ lint_on_save = false, lsp = false })
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

describe("nvim-m1.lint NS clearing on late LSP attach (#25 timeline)", function()
  -- The standalone fallback linter publishes into its own namespace. If the LSP
  -- was unresolvable at BufReadPost the standalone runner publishes there; when
  -- m1-lsp later attaches (e.g. via :M1Install) it publishes the SAME lint
  -- diagnostics through its own namespace. The stale standalone set must be
  -- cleared, or every warning shows twice until the next re-read.
  local lsp = require("nvim-m1.lsp")
  local saved_get_clients, saved_resolve_cmd
  local buf

  -- Seed the standalone linter's namespace with a diagnostic, as a prior
  -- BufReadPost run (before the LSP was available) would have.
  local function seed_ns(b)
    vim.diagnostic.set(lint.namespace(), b, {
      {
        lnum = 0,
        col = 0,
        end_lnum = 0,
        end_col = 1,
        severity = vim.diagnostic.severity.WARN,
        message = "stale standalone lint",
        source = "m1-lint",
      },
    })
  end

  local function ns_count(b)
    return #vim.diagnostic.get(b, { namespace = lint.namespace() })
  end

  before_each(function()
    saved_get_clients = vim.lsp.get_clients
    saved_resolve_cmd = lsp.resolve_cmd
    buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/late-attach.m1scr")
    vim.bo[buf].filetype = "m1scr"
  end)
  after_each(function()
    vim.lsp.get_clients = saved_get_clients
    lsp.resolve_cmd = saved_resolve_cmd
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.diagnostic.reset(lint.namespace(), buf)
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("exposes the standalone-linter namespace", function()
    assert.is_number(lint.namespace())
  end)

  it("M.lint clears stale standalone diagnostics when m1lsp is attached", function()
    seed_ns(buf)
    assert.equals(1, ns_count(buf))
    vim.lsp.get_clients = function()
      return { { name = lsp.client_name } }
    end
    -- LSP attached: M.lint must bail (no double-publish) AND clear the stale set
    -- it left behind on an earlier standalone run.
    lint.lint(buf)
    assert.equals(0, ns_count(buf))
  end)

  it("the fire-time defer path clears stale standalone diagnostics", function()
    seed_ns(buf)
    assert.equals(1, ns_count(buf))
    -- m1-lsp is resolvable (about to attach), so the autocmd callback defers to
    -- it. Deferring must also clear any prior standalone run for this buffer.
    lsp.resolve_cmd = function()
      return "/usr/bin/m1-lsp"
    end
    vim.lsp.get_clients = function()
      return {}
    end
    lint.setup({ lint_on_save = true, lsp = true })
    local cbs = vim.api.nvim_get_autocmds({
      group = "NvimM1Lint",
      event = "BufReadPost",
    })
    assert.is_true(#cbs >= 1)
    -- Fire the read hook the way Neovim would.
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
    vim.wait(20)
    assert.equals(0, ns_count(buf))
  end)

  it("registers an LspAttach handler that clears NS once m1lsp is attached", function()
    seed_ns(buf)
    assert.equals(1, ns_count(buf))
    lint.setup({ lint_on_save = true, lsp = true })
    -- Simulate m1-lsp attaching after a standalone run: it is now in the
    -- buffer's client list. The handler must clear the standalone namespace so
    -- the LSP's diagnostics are not doubled.
    vim.lsp.get_clients = function()
      return { { name = lsp.client_name } }
    end
    vim.api.nvim_exec_autocmds("LspAttach", {
      buffer = buf,
      data = { client_id = 1 },
      modeline = false,
    })
    vim.wait(20)
    assert.equals(0, ns_count(buf))
  end)

  it("LspAttach for a non-m1lsp client does NOT clear NS", function()
    seed_ns(buf)
    lint.setup({ lint_on_save = true, lsp = true })
    -- A different server attaching (m1lsp absent from the client list) must not
    -- wipe the standalone fallback set.
    vim.lsp.get_clients = function()
      return { { name = "lua_ls" } }
    end
    vim.api.nvim_exec_autocmds("LspAttach", {
      buffer = buf,
      data = { client_id = 424242 },
      modeline = false,
    })
    vim.wait(20)
    assert.equals(1, ns_count(buf))
  end)
end)

describe("nvim-m1.lint.lsp_will_lint (fire-time decision, #25)", function()
  local lsp = require("nvim-m1.lsp")
  local config = require("nvim-m1.config")
  local saved_resolve, saved_get_clients

  before_each(function()
    saved_resolve = lsp.resolve_cmd
    saved_get_clients = vim.lsp.get_clients
    -- Not attached unless a test says so.
    vim.lsp.get_clients = function()
      return {}
    end
  end)
  after_each(function()
    lsp.resolve_cmd = saved_resolve
    vim.lsp.get_clients = saved_get_clients
  end)

  it("is true when m1-lsp is enabled and resolvable (about to attach)", function()
    lsp.resolve_cmd = function()
      return "/usr/bin/m1-lsp"
    end
    assert.is_true(lint.lsp_will_lint(0, config.resolve({ lsp = true })))
  end)

  it("is false when m1-lsp is enabled but not found (standalone runs)", function()
    lsp.resolve_cmd = function()
      return nil
    end
    assert.is_false(lint.lsp_will_lint(0, config.resolve({ lsp = true })))
  end)

  it("is false when the LSP is disabled", function()
    lsp.resolve_cmd = function()
      return "/usr/bin/m1-lsp"
    end
    assert.is_false(lint.lsp_will_lint(0, config.resolve({ lsp = false })))
  end)

  it(
    "is true when an m1lsp client is already attached, regardless of resolve",
    function()
      lsp.resolve_cmd = function()
        return nil
      end
      vim.lsp.get_clients = function()
        return { { name = lsp.client_name } }
      end
      assert.is_true(lint.lsp_will_lint(0, config.resolve({ lsp = true })))
    end
  )
end)

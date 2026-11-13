local lint = require("nvim-m1.lint")
local install = require("nvim-m1.install")

local function report(diagnostic)
  return vim.json.encode({
    version = 2,
    files = { { path = "<stdin>", diagnostics = diagnostic and { diagnostic } or {} } },
  })
end

local warning = {
  code = "L004",
  message = "obsolete warning",
  range = { start = { line = 0, column = 0 }, ["end"] = { line = 0, column = 1 } },
}

describe("standalone lint source identity", function()
  local saved_system, saved_resolve, saved_clients, saved_backend
  local buffers, callbacks

  before_each(function()
    saved_system, saved_resolve, saved_clients =
      vim.system, install.resolve, vim.lsp.get_clients
    saved_backend = package.loaded.lint
    package.loaded.lint = nil
    buffers, callbacks = {}, {}
    install.resolve = function()
      return "/fake/m1-lint"
    end
    vim.lsp.get_clients = function()
      return {}
    end
    vim.system = function(_, _, callback)
      table.insert(callbacks, callback)
      return {}
    end
  end)
  after_each(function()
    vim.system, install.resolve, vim.lsp.get_clients =
      saved_system, saved_resolve, saved_clients
    package.loaded.lint = saved_backend
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  local function buffer()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Out = 1;" })
    table.insert(buffers, buf)
    return buf
  end

  local function complete(index, diagnostic)
    callbacks[index]({ code = 0, stdout = report(diagnostic) })
    vim.wait(20)
  end

  it("resolves buffer zero before asynchronous publication", function()
    local origin, other = buffer(), buffer()
    vim.api.nvim_set_current_buf(origin)
    lint.run_builtin(0)
    vim.api.nvim_set_current_buf(other)
    complete(1, warning)
    assert.equals(1, #vim.diagnostic.get(origin, { namespace = lint.namespace() }))
    assert.equals(0, #vim.diagnostic.get(other, { namespace = lint.namespace() }))
  end)

  it("keeps the newest result when completions arrive in reverse order", function()
    local buf = buffer()
    lint.run_builtin(buf)
    lint.run_builtin(buf)
    complete(2, nil)
    complete(1, warning)
    assert.same({}, vim.diagnostic.get(buf, { namespace = lint.namespace() }))
  end)

  it("drops a result after an edit without another lint run", function()
    local buf = buffer()
    lint.run_builtin(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Out = 2;" })
    complete(1, warning)
    assert.same({}, vim.diagnostic.get(buf, { namespace = lint.namespace() }))
  end)

  it("drops a result after m1-lsp attaches", function()
    local buf = buffer()
    lint.run_builtin(buf)
    vim.lsp.get_clients = function()
      return { { name = require("nvim-m1.lsp").client_name } }
    end
    complete(1, warning)
    assert.same({}, vim.diagnostic.get(buf, { namespace = lint.namespace() }))
  end)

  it("ignores completion after the source buffer is wiped", function()
    local buf = buffer()
    lint.run_builtin(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    complete(1, warning)
  end)

  it("keeps nvim-lint parser state separate for every run and buffer", function()
    local first, second = buffer(), buffer()
    vim.api.nvim_set_current_buf(first)
    local old = lint.linter()
    local newest = lint.linter()
    vim.api.nvim_set_current_buf(second)
    local other = lint.linter()
    assert.equals(1, #newest.parser(report(warning), first))
    assert.same({}, old.parser(report(warning), first))
    assert.equals(1, #other.parser(report(warning), second))
    local changed = lint.linter()
    vim.api.nvim_buf_set_lines(second, 0, -1, false, { "Out = 2;" })
    assert.same({}, changed.parser(report(warning), second))
  end)

  it("invalidates a pending run even if the LSP detaches before completion", function()
    local buf = buffer()
    lint.setup({ lsp = false, lint_on_save = false })
    lint.run_builtin(buf)
    vim.lsp.get_clients = function()
      return { { name = require("nvim-m1.lsp").client_name } }
    end
    vim.api.nvim_exec_autocmds("LspAttach", { buffer = buf, data = { client_id = 1 } })
    vim.lsp.get_clients = function()
      return {}
    end
    complete(1, warning)
    assert.same({}, vim.diagnostic.get(buf, { namespace = lint.namespace() }))
  end)

  it("retains wrapped factory snapshots after repeated setup", function()
    local backend = { linters = {} }
    package.loaded.lint = backend
    local buf = buffer()
    vim.api.nvim_set_current_buf(buf)
    lint.setup({ lsp = false, lint_on_save = false })
    local original = backend.linters.m1_lint
    backend.linters.m1_lint = function()
      local definition = original()
      definition.cmd = "/custom/m1-lint"
      return definition
    end
    lint.setup({ lsp = false, lint_on_save = false })
    local definition = backend.linters.m1_lint()
    assert.equals("/custom/m1-lint", definition.cmd)
    assert.equals(1, #definition.parser(report(warning), buf))
  end)

  it("stale optional completion preserves a newer published diagnostic", function()
    local namespace = vim.api.nvim_create_namespace("nvim-m1-test-optional")
    package.loaded.lint = {
      get_namespace = function()
        return namespace
      end,
    }
    local buf = buffer()
    vim.api.nvim_set_current_buf(buf)
    local old, newest = lint.linter(), lint.linter()
    local diagnostic = vim.deepcopy(warning)
    diagnostic.message = "new warning"
    vim.diagnostic.set(namespace, buf, newest.parser(report(diagnostic), buf))
    vim.diagnostic.set(namespace, buf, old.parser(report(warning), buf))
    assert.equals(
      "new warning",
      vim.diagnostic.get(buf, { namespace = namespace })[1].message
    )
  end)

  it("invokes nvim-lint in the requested buffer context", function()
    local origin, other = buffer(), buffer()
    local selected
    package.loaded.lint = {
      try_lint = function()
        selected = vim.api.nvim_get_current_buf()
      end,
    }
    vim.api.nvim_set_current_buf(other)
    lint.lint(origin)
    assert.equals(origin, selected)
    assert.equals(other, vim.api.nvim_get_current_buf())
  end)
end)

describe("standalone diagnostic coordinates", function()
  it("inherits each missing end field from the start without source text", function()
    local d = { range = { start = { line = 3, column = 4 }, ["end"] = {} } }
    local item = lint.parse(report(d))[1]
    assert.same({ 3, 4, 3, 4 }, { item.lnum, item.col, item.end_lnum, item.end_col })
    d.range["end"].line = 5
    item = lint.parse(report(d))[1]
    assert.same({ 5, 4 }, { item.end_lnum, item.end_col })
  end)

  it("prefers byte ranges from the submitted Unicode source", function()
    local source = "/* é😀 */ Out=1;  \n// é"
    local d = {
      code = "L007",
      message = "operator spacing",
      range = { start = { line = 0, column = 12 }, ["end"] = { line = 0, column = 13 } },
      byte_range = { start = 16, ["end"] = 17 },
    }
    local item = lint.parse(report(d), nil, source)[1]
    assert.same({ 0, 16, 0, 17 }, { item.lnum, item.col, item.end_lnum, item.end_col })
    d.byte_range = { start = #source, ["end"] = #source }
    d.range = { start = { line = 1, column = 5 }, ["end"] = { line = 1, column = 5 } }
    item = lint.parse(report(d), nil, source)[1]
    assert.same({ 1, 6 }, { item.lnum, item.col })
  end)

  it(
    "converts scalar columns including combining characters without byte ranges",
    function()
      local source = "/* é😀é */ Out=1;"
      local column = vim.fn.strchars("/* é😀é */ Out")
      local byte = #"/* é😀é */ Out"
      local d = {
        message = "operator spacing",
        range = {
          start = { line = 0, column = column },
          ["end"] = { line = 0, column = column + 1 },
        },
      }
      local item = lint.parse(report(d), nil, source)[1]
      assert.same({ byte, byte + 1 }, { item.col, item.end_col })
    end
  )
end)

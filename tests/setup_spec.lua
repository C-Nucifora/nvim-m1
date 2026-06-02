local nvim_m1 = require("nvim-m1")
local lint = require("nvim-m1.lint")

describe("nvim-m1.setup", function()
  it("runs cleanly and is idempotent", function()
    assert.has_no.errors(function()
      nvim_m1.setup()
      nvim_m1.setup({ format_on_save = false, lint_on_save = false })
    end)
  end)

  it("registers the m1scr and m1prj filetypes", function()
    nvim_m1.setup()
    assert.equals("m1scr", vim.filetype.match({ filename = "Foo.m1scr" }))
    assert.equals("m1prj", vim.filetype.match({ filename = "Project.m1prj" }))
  end)

  it("registers the m1lsp config via the native API when m1-lsp is on $PATH", function()
    if vim.fn.executable("m1-lsp") ~= 1 then
      pending("m1-lsp not on $PATH")
      return
    end
    -- Regression: vim.lsp.config is a *callable table*, so setup() must not
    -- mistake it for "absent" and skip native registration.
    if vim.lsp.config == nil then
      pending("Neovim without native vim.lsp.config")
      return
    end
    nvim_m1.setup()
    assert.is_not_nil(
      vim.lsp.config[require("nvim-m1.lsp").client_name],
      "native m1lsp config should be registered"
    )
  end)

  it("creates the user commands", function()
    nvim_m1.setup()
    local cmds = vim.api.nvim_get_commands({})
    assert.is_not_nil(cmds.M1Format)
    assert.is_not_nil(cmds.M1Lint)
    assert.is_not_nil(cmds.M1FormatToggle)
  end)

  it("only wires format-on-save when enabled", function()
    nvim_m1.setup({ format_on_save = false })
    assert.is_false(vim.g.nvim_m1_format_on_save)
    local autocmds = vim.api.nvim_get_autocmds({ group = "NvimM1Format" })
    assert.equals(0, #autocmds)
  end)

  it("wires a BufWritePre format hook when enabled", function()
    vim.g.nvim_m1_format_on_save = nil
    nvim_m1.setup({ format_on_save = true })
    local autocmds =
      vim.api.nvim_get_autocmds({ group = "NvimM1Format", event = "BufWritePre" })
    assert.is_true(#autocmds >= 1)
  end)
end)

describe("nvim-m1.lint end-to-end (needs m1-lint on $PATH)", function()
  local has_m1lint = vim.fn.executable("m1-lint") == 1

  it("produces diagnostics from the real binary", function()
    if not has_m1lint then
      pending("m1-lint not on $PATH")
      return
    end
    -- Synthetic script that trips L004 (== over eq) and L006 (float ==).
    local path = vim.fn.tempname() .. ".m1scr"
    vim.fn.writefile({ "Number x", "  if x == 1.0", "  end", "end" }, path)

    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.api.nvim_set_current_buf(bufnr)

    lint.run_builtin(bufnr)
    -- run_builtin schedules an async vim.system; pump until diagnostics arrive.
    vim.wait(5000, function()
      return #vim.diagnostic.get(bufnr) > 0
    end, 50)

    local diags = vim.diagnostic.get(bufnr)
    assert.is_true(#diags > 0, "expected lint diagnostics from m1-lint")
    local codes = vim.tbl_map(function(d)
      return d.code
    end, diags)
    assert.is_true(
      vim.tbl_contains(codes, "L004") or vim.tbl_contains(codes, "L006"),
      "expected an L004/L006 finding, got " .. vim.inspect(codes)
    )
  end)
end)

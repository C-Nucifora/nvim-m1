local config = require("nvim-m1.config")

describe("nvim-m1.config", function()
  it("returns the documented defaults", function()
    local cfg = config.resolve()
    assert.equals(nil, cfg.server_path)
    assert.is_true(cfg.format_on_save)
    assert.is_true(cfg.lint_on_save)
    assert.same({ "m1scr" }, cfg.filetypes)
  end)

  it("merges user opts over the defaults", function()
    local cfg = config.resolve({ server_path = "/opt/m1-lsp", format_on_save = false })
    assert.equals("/opt/m1-lsp", cfg.server_path)
    assert.is_false(cfg.format_on_save)
    -- untouched keys keep their defaults
    assert.is_true(cfg.lint_on_save)
  end)

  it("adds m1prj to the LSP filetypes when attach_m1prj is on", function()
    local cfg = config.resolve()
    assert.is_true(vim.tbl_contains(cfg.lsp_filetypes, "m1scr"))
    assert.is_true(vim.tbl_contains(cfg.lsp_filetypes, "m1prj"))
  end)

  it("omits m1prj from the LSP filetypes when attach_m1prj is off", function()
    local cfg = config.resolve({ attach_m1prj = false })
    assert.is_false(vim.tbl_contains(cfg.lsp_filetypes, "m1prj"))
    -- the script filetypes table is not mutated
    assert.same({ "m1scr" }, cfg.filetypes)
  end)

  it("rejects a wrongly-typed option", function()
    assert.has_error(function()
      config.resolve({ format_on_save = "yes" })
    end)
  end)
end)

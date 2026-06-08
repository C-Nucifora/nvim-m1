--- Regression: the conform.nvim formatter must use m1-fmt's real flag.
local format = require("nvim-m1.format")

describe("nvim-m1.format conform integration", function()
  it("passes --stdin-filename (m1-fmt's flag), not --stdin-filepath (#9)", function()
    local args = format.conform_formatter.args
    assert.equals("--stdin-filename", args[1])
    assert.equals("$FILENAME", args[2])
  end)
end)

describe("nvim-m1.format :M1FormatToggle works when starting disabled", function()
  -- Regression: the BufWritePre hook must be wired regardless of the initial
  -- `format_on_save`, and gated at FIRE time by `vim.g.nvim_m1_format_on_save`
  -- (mirroring lint.lua). Otherwise a user who starts with format_on_save=false
  -- and then runs :M1FormatToggle (which only flips the global) gets no
  -- formatting on save — the README's "toggle for this session" silently fails.
  local saved_global

  local function format_autocmds()
    return vim.api.nvim_get_autocmds({ group = "NvimM1Format" })
  end

  before_each(function()
    saved_global = vim.g.nvim_m1_format_on_save
  end)
  after_each(function()
    vim.g.nvim_m1_format_on_save = saved_global
  end)

  it("wires the save hook even when format_on_save is disabled", function()
    format.setup({ format_on_save = false, format_timeout_ms = 5000 })
    assert.is_true(
      #format_autocmds() >= 1,
      "BufWritePre hook must exist so :M1FormatToggle can enable it at runtime"
    )
  end)

  it("sets the runtime gate to the configured default", function()
    format.setup({ format_on_save = false, format_timeout_ms = 5000 })
    assert.is_false(vim.g.nvim_m1_format_on_save)
    format.setup({ format_on_save = true, format_timeout_ms = 5000 })
    assert.is_true(vim.g.nvim_m1_format_on_save)
  end)

  it("runs the formatter on save only after the gate is toggled on", function()
    format.setup({ format_on_save = false, format_timeout_ms = 5000 })

    local saved_format = format.format
    local ran = 0
    format.format = function()
      ran = ran + 1
    end

    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/toggle.m1scr")

    local ok, err = pcall(function()
      -- Gate is OFF (started disabled): firing the hook must NOT format.
      vim.api.nvim_exec_autocmds("BufWritePre", { buffer = buf })
      assert.equals(0, ran)

      -- :M1FormatToggle flips the global ON; the hook (which must already exist)
      -- now formats on the next save.
      vim.g.nvim_m1_format_on_save = true
      vim.api.nvim_exec_autocmds("BufWritePre", { buffer = buf })
      assert.equals(1, ran)
    end)

    format.format = saved_format
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    assert.is_true(ok, tostring(err))
  end)
end)

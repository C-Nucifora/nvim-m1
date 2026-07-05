local codelens = require("nvim-m1.codelens")
local config = require("nvim-m1.config")

describe("nvim-m1.codelens", function()
  before_each(function()
    -- `vim.lsp.commands` rejects nil via __newindex; rawset to clear for isolation.
    rawset(vim.lsp.commands, "m1.revealLocation", nil)
  end)

  it("defaults codelens to true", function()
    assert.is_true(config.resolve().codelens)
  end)

  it("registers the m1.revealLocation command on setup", function()
    codelens.setup({ codelens = true })
    assert.is_function(rawget(vim.lsp.commands, "m1.revealLocation"))
  end)

  it("does not register the command when codelens is disabled", function()
    codelens.setup({ codelens = false })
    assert.is_nil(rawget(vim.lsp.commands, "m1.revealLocation"))
  end)

  it("reveal command jumps to the given 0-based line", function()
    local tmp = vim.fn.tempname() .. ".m1prj"
    vim.fn.writefile({ "line0", "line1", "line2", "line3" }, tmp)
    codelens.setup({ codelens = true })
    -- LSP arg line 2 (0-based) -> nvim cursor row 3 (1-based).
    rawget(vim.lsp.commands, "m1.revealLocation")({
      arguments = { vim.uri_from_fname(tmp), 2 },
    }, {})
    assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

describe("nvim-m1.codelens no duplicate autocmds on LSP re-attach", function()
  -- Re-attaching (e.g. :M1RestartServer, or an LSP detach/attach cycle) fires
  -- LspAttach again for the same buffer. Without clearing, each re-attach used
  -- to stack another copy of the per-buffer refresh autocmds in the group.
  local saved_get_client
  local buf

  before_each(function()
    saved_get_client = vim.lsp.get_client_by_id
    vim.lsp.get_client_by_id = function()
      return {
        name = require("nvim-m1.lsp").client_name,
        server_capabilities = { codeLensProvider = {} },
      }
    end
    buf = vim.api.nvim_create_buf(false, false)
  end)
  after_each(function()
    vim.lsp.get_client_by_id = saved_get_client
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  local function buf_autocmds()
    return vim.api.nvim_get_autocmds({ group = "NvimM1CodeLens", buffer = buf })
  end

  it("re-attaching does not stack the per-buffer refresh autocmds", function()
    codelens.setup({ codelens = true })
    vim.api.nvim_exec_autocmds(
      "LspAttach",
      { buffer = buf, data = { client_id = 1 }, modeline = false }
    )
    local first = #buf_autocmds()
    assert.is_true(
      first >= 1,
      "the per-buffer refresh autocmds must be wired on attach"
    )
    vim.api.nvim_exec_autocmds(
      "LspAttach",
      { buffer = buf, data = { client_id = 1 }, modeline = false }
    )
    assert.equals(
      first,
      #buf_autocmds(),
      "a second attach must not duplicate the buffer-local autocmds"
    )
  end)
end)

describe("nvim-m1.codelens refresh shim (#66)", function()
  local codelens = require("nvim-m1.codelens")

  it("prefers vim.lsp.codelens.enable over the deprecated refresh (0.12+)", function()
    local saved_enable, saved_refresh =
      vim.lsp.codelens.enable, vim.lsp.codelens.refresh
    local enabled, refreshed = 0, 0
    vim.lsp.codelens.enable = function()
      enabled = enabled + 1
    end
    vim.lsp.codelens.refresh = function()
      refreshed = refreshed + 1
    end
    codelens._refresh_buf(0)
    vim.lsp.codelens.enable, vim.lsp.codelens.refresh = saved_enable, saved_refresh
    assert.equals(1, enabled)
    assert.equals(0, refreshed)
  end)

  it("falls back to refresh when enable is unavailable (0.10/0.11)", function()
    local saved_enable, saved_refresh =
      vim.lsp.codelens.enable, vim.lsp.codelens.refresh
    local refreshed = 0
    vim.lsp.codelens.enable = nil
    vim.lsp.codelens.refresh = function()
      refreshed = refreshed + 1
    end
    codelens._refresh_buf(0)
    vim.lsp.codelens.enable, vim.lsp.codelens.refresh = saved_enable, saved_refresh
    assert.equals(1, refreshed)
  end)
end)

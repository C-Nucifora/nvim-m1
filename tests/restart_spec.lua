-- :M1RestartServer / lsp.restart() — parity with m1-vscode's m1.restartServer.
--
-- A live m1-lsp keeps running across a toolchain update, so stale behaviour
-- after :M1Update needs a full stop+re-attach to cycle the process. On the
-- native (0.11+) LSP path this plugin prefers, nvim-lspconfig's :LspRestart is
-- unavailable, so this command (and the lsp.restart() it drives) is the only
-- portable way to cycle a stale server. These tests pin the contract that
-- distinguishes it from the install self-heal's re-enable-without-stop:
-- restart() MUST stop the live clients first.
describe("nvim-m1 :M1RestartServer", function()
  it("registers the user command via setup()", function()
    require("nvim-m1").setup()
    -- Note: nvim_get_commands().<cmd>.definition does NOT carry a Lua command's
    -- desc on recent Neovim (same footgun as the proj_cmd spec), so this only
    -- asserts the command exists — the desc/behaviour is exercised by the
    -- lsp.restart() tests below.
    assert.is_not_nil(
      vim.api.nvim_get_commands({}).M1RestartServer,
      "M1RestartServer user command must exist"
    )
  end)
end)

describe("nvim-m1.lsp.restart", function()
  local lsp = require("nvim-m1.lsp")
  local config = require("nvim-m1.config")

  -- Capture and restore the vim.lsp surface restart() drives so each test runs
  -- against a clean mock and the real API is left untouched afterwards.
  local saved
  before_each(function()
    saved = {
      get_clients = vim.lsp.get_clients,
      stop_client = vim.lsp.stop_client,
      enable = vim.lsp.enable,
      config = rawget(vim.lsp, "config"),
    }
  end)
  after_each(function()
    vim.lsp.get_clients = saved.get_clients
    vim.lsp.stop_client = saved.stop_client
    vim.lsp.enable = saved.enable
    rawset(vim.lsp, "config", saved.config)
  end)

  it("stops the live m1lsp clients (force) before re-attaching", function()
    -- Force the native (0.11+) branch deterministically.
    rawset(
      vim.lsp,
      "config",
      saved.config or setmetatable({}, { __call = function() end })
    )

    local clients = { { id = 7, name = lsp.client_name } }
    local stopped_ids, stopped_force
    local enable_calls = {}

    vim.lsp.get_clients = function(filter)
      assert.are.equal(lsp.client_name, filter and filter.name)
      return clients
    end
    vim.lsp.stop_client = function(ids, force)
      stopped_ids, stopped_force = ids, force
      clients = {} -- the clients have now exited
    end
    vim.lsp.enable = function(name, enabled)
      enable_calls[#enable_calls + 1] = { name = name, enabled = enabled }
    end

    local ok = lsp.restart(config.defaults)
    assert.is_true(ok, "restart should succeed when the server stops")

    -- The defining behaviour vs the self-heal's re-enable: it STOPS first.
    assert.are.same({ 7 }, stopped_ids, "must stop the live client by id")
    assert.is_true(stopped_force, "must force-stop so a hung binary can't block")

    -- And then re-enables (off→on) so the config re-attaches to open buffers.
    assert.is_true(#enable_calls >= 1, "must re-enable the m1lsp config")
    assert.are.equal(
      lsp.client_name,
      enable_calls[#enable_calls].name,
      "re-enable targets the m1lsp client"
    )
    assert.is_nil(
      enable_calls[#enable_calls].enabled,
      "final enable call turns the config back on"
    )
  end)

  it("re-enables even with no client running (cold start)", function()
    rawset(
      vim.lsp,
      "config",
      saved.config or setmetatable({}, { __call = function() end })
    )
    local stop_called = false
    local enabled = false
    vim.lsp.get_clients = function()
      return {}
    end
    vim.lsp.stop_client = function()
      stop_called = true
    end
    vim.lsp.enable = function(_, on)
      if on == nil then
        enabled = true
      end
    end

    local ok = lsp.restart(config.defaults)
    assert.is_true(ok)
    assert.is_false(stop_called, "nothing to stop when no client is running")
    assert.is_true(enabled, "still (re)enables so a fresh server attaches")
  end)
end)

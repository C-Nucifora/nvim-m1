local config = require("nvim-m1.config")
local lsp = require("nvim-m1.lsp")

describe("nvim-m1.lsp semantic-token compatibility", function()
  it("disables range requests before Neovim can race them with full/delta", function()
    local client = {
      server_capabilities = {
        semanticTokensProvider = {
          range = true,
          full = { delta = true },
          legend = { tokenTypes = { "property" }, tokenModifiers = {} },
        },
      },
    }

    assert.is_function(
      lsp.on_init,
      "m1lsp needs an on_init compatibility hook before semantic highlighting starts"
    )
    if lsp.on_init then
      lsp.on_init(client)
    end

    local provider = client.server_capabilities.semanticTokensProvider
    assert.is_false(provider.range, "range must be disabled to remove the Neovim race")
    assert.same(
      { delta = true },
      provider.full,
      "full/delta highlighting must remain enabled"
    )
    assert.same(
      { tokenTypes = { "property" }, tokenModifiers = {} },
      provider.legend,
      "the server's semantic-token legend must remain untouched"
    )
  end)

  it("wires the compatibility hook through the native Neovim LSP path", function()
    local saved = {
      config = rawget(vim.lsp, "config"),
      enable = vim.lsp.enable,
      resolve_cmd = lsp.resolve_cmd,
    }
    local registered

    rawset(
      vim.lsp,
      "config",
      setmetatable({}, {
        __call = function(_, name, opts)
          assert.equals(lsp.client_name, name)
          registered = opts
        end,
      })
    )
    vim.lsp.enable = function() end
    lsp.resolve_cmd = function()
      return "/tmp/m1-lsp"
    end

    local ok, err = pcall(lsp.setup, config.resolve({}))

    rawset(vim.lsp, "config", saved.config)
    vim.lsp.enable = saved.enable
    lsp.resolve_cmd = saved.resolve_cmd

    assert.is_true(ok, err)
    assert.is_not_nil(registered, "native setup must register m1lsp")
    assert.is_function(
      registered.on_init,
      "native setup must register the compatibility hook"
    )
    assert.equals(lsp.on_init, registered.on_init)
  end)

  it("wires the compatibility hook through the nvim-lspconfig fallback", function()
    local saved = {
      config = rawget(vim.lsp, "config"),
      enable = vim.lsp.enable,
      resolve_cmd = lsp.resolve_cmd,
      lspconfig = package.loaded["lspconfig"],
      configs = package.loaded["lspconfig.configs"],
    }
    local registered
    local fake_lspconfig = {
      util = {
        root_pattern = function()
          return function() end
        end,
      },
      m1lsp = {
        setup = function(opts)
          registered = opts
        end,
      },
    }

    rawset(vim.lsp, "config", nil)
    vim.lsp.enable = nil
    lsp.resolve_cmd = function()
      return "/tmp/m1-lsp"
    end
    package.loaded["lspconfig"] = fake_lspconfig
    package.loaded["lspconfig.configs"] = {}

    local ok, err = pcall(lsp.setup, config.resolve({}))

    rawset(vim.lsp, "config", saved.config)
    vim.lsp.enable = saved.enable
    lsp.resolve_cmd = saved.resolve_cmd
    package.loaded["lspconfig"] = saved.lspconfig
    package.loaded["lspconfig.configs"] = saved.configs

    assert.is_true(ok, err)
    assert.is_not_nil(registered, "fallback setup must register m1lsp")
    assert.is_function(
      registered.on_init,
      "nvim-lspconfig fallback must register the compatibility hook"
    )
    assert.equals(lsp.on_init, registered.on_init)
  end)
end)

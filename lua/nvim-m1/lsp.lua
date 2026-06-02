--- nvim-m1: m1-lsp language-server wiring.
---
--- Prefers Neovim's native `vim.lsp.config`/`vim.lsp.enable` (0.11+) and falls
--- back to nvim-lspconfig on 0.10. Both paths configure the same command,
--- filetypes, root markers and capabilities.
local M = {}

--- Canonical LSP client name this plugin registers m1-lsp under. Exposed so
--- companion plugins (telescope-m1.nvim) can find the client without hardcoding
--- the name — keeping the Neovim integration in sync from one place.
M.client_name = "m1lsp"

--- Resolve the m1-lsp executable: explicit override, then $PATH.
---@param cfg NvimM1Config
---@return string? bin  Absolute/relative command, or nil if nothing is executable.
function M.resolve_cmd(cfg)
  if cfg.server_path and cfg.server_path ~= "" then
    return cfg.server_path
  end
  if vim.fn.executable("m1-lsp") == 1 then
    return "m1-lsp"
  end
  return nil
end

--- Default client capabilities, enriched with blink.cmp's if it is installed.
---@param cfg NvimM1Config
---@return table
local function capabilities(cfg)
  if cfg.capabilities then
    return cfg.capabilities
  end
  local ok, blink = pcall(require, "blink.cmp")
  if ok and type(blink.get_lsp_capabilities) == "function" then
    return blink.get_lsp_capabilities()
  end
  return vim.lsp.protocol.make_client_capabilities()
end

--- Whether the running Neovim exposes the native lsp config API (0.11+).
--- Note: `vim.lsp.config` is a *callable table* (not a function), so test for
--- presence rather than type; `vim.lsp.enable` is a plain function.
---@return boolean
local function has_native_api()
  return vim.lsp.config ~= nil and type(vim.lsp.enable) == "function"
end

--- Register and enable m1-lsp.
---@param cfg NvimM1Config
---@return boolean ok, string? reason
function M.setup(cfg)
  if not cfg.lsp then
    return false, "disabled"
  end

  local bin = M.resolve_cmd(cfg)
  if not bin then
    -- Don't error: the rest of the plugin (highlighting, lint, format via
    -- m1-fmt) still works. :checkhealth surfaces the missing binary.
    return false, "m1-lsp not found on $PATH (set opts.server_path)"
  end

  -- Forward user settings (lint/format/diagnostics) to the server at `initialize`
  -- too, not just via didChangeConfiguration — so they apply before the first
  -- diagnostics publish. A workspace `m1-tools.toml`, which the server discovers
  -- itself, overrides these (matching the m1-vscode precedence).
  local init_options = cfg.settings and { settings = cfg.settings } or nil

  if has_native_api() then
    vim.lsp.config(M.client_name, {
      cmd = { bin },
      filetypes = cfg.lsp_filetypes,
      root_markers = cfg.root_markers,
      capabilities = capabilities(cfg),
      on_attach = cfg.on_attach,
      settings = cfg.settings,
      init_options = init_options,
    })
    vim.lsp.enable(M.client_name)
    return true
  end

  -- Fallback: nvim-lspconfig (Neovim 0.10).
  local ok_lsp, lspconfig = pcall(require, "lspconfig")
  local ok_cfg, configs = pcall(require, "lspconfig.configs")
  if not ok_lsp or not ok_cfg then
    return false, "neither vim.lsp.config (0.11+) nor nvim-lspconfig is available"
  end

  if not configs.m1lsp then
    configs.m1lsp = {
      default_config = {
        cmd = { bin },
        filetypes = cfg.lsp_filetypes,
        root_dir = lspconfig.util.root_pattern(unpack(cfg.root_markers)),
        single_file_support = true,
      },
    }
  end
  lspconfig.m1lsp.setup({
    capabilities = capabilities(cfg),
    on_attach = cfg.on_attach,
    settings = cfg.settings,
    init_options = init_options,
  })
  return true
end

return M

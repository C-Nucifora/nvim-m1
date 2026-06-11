--- nvim-m1: m1-lsp code-lens display + the clickable execution-rate lens.
---
--- Neovim does not show LSP code lenses unless a plugin refreshes and renders
--- them, so m1-lsp's `⚡ N Hz` execution-rate lens is invisible out of the box.
--- This module refreshes lenses on m1 buffers, exposes `:M1CodeLensRun` to run
--- the lens under the cursor, and registers the client-side `m1.revealLocation`
--- command the rate lens targets (m1-lsp #175) — so running it jumps to the
--- script's `SelectedTrigger` declaration in `Project.m1prj`.
local M = {}

local client_name = require("nvim-m1.lsp").client_name

--- Open `uri` and place the cursor on (0-based) `line`. Target of the clickable
--- rate lens — handled CLIENT-SIDE (registered in `vim.lsp.commands`) rather
--- than round-tripping through the server's executeCommandProvider.
---@param command table  The LSP Command; `arguments` is `{ uri, line }`.
local function reveal_location(command)
  local args = command.arguments or {}
  local uri, line = args[1], args[2]
  if type(uri) ~= "string" then
    return
  end
  local bufnr = vim.uri_to_bufnr(uri)
  vim.fn.bufload(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
  local row = math.max(0, tonumber(line) or 0) + 1 -- LSP 0-based -> nvim 1-based
  pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 })
  vim.cmd("normal! zz")
end

--- True if `client` is m1-lsp and advertises code lenses.
local function is_m1_codelens_client(client)
  return client ~= nil
    and client.name == client_name
    and client.server_capabilities ~= nil
    and client.server_capabilities.codeLensProvider ~= nil
end

--- Refresh the lenses of one buffer. `vim.lsp.codelens.refresh({ bufnr })` is
--- deprecated on 0.12 (removed in 0.13) in favour of
--- `vim.lsp.codelens.enable(true, { bufnr })`, which does not exist on
--- 0.10/0.11 — use whichever this Neovim provides (#66). Exposed as
--- `M._refresh_buf` for the spec.
---@param buf integer
function M._refresh_buf(buf)
  local cl = vim.lsp.codelens
  if type(cl.enable) == "function" then
    pcall(cl.enable, true, { bufnr = buf })
  else
    pcall(cl.refresh, { bufnr = buf })
  end
end

--- Wire code-lens display + the reveal command. Idempotent (one augroup,
--- cleared on re-setup). No-op when `cfg.codelens` is false.
---@param cfg NvimM1Config
function M.setup(cfg)
  if not cfg.codelens then
    return
  end

  -- Register the reveal command once (global table; safe to overwrite).
  vim.lsp.commands["m1.revealLocation"] = function(command, _ctx)
    reveal_location(command)
  end

  local group = vim.api.nvim_create_augroup("NvimM1CodeLens", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not is_m1_codelens_client(client) then
        return
      end
      local buf = ev.buf
      M._refresh_buf(buf)
      -- Keep lenses current as the buffer is edited/navigated.
      vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
        group = group,
        buffer = buf,
        callback = function()
          M._refresh_buf(buf)
        end,
      })
      vim.api.nvim_buf_create_user_command(buf, "M1CodeLensRun", function()
        vim.lsp.codelens.run()
      end, { desc = "nvim-m1: run the code lens under the cursor" })
    end,
  })
end

return M

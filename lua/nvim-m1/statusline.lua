--- nvim-m1: statusline component (#47).
---
--- A plain-string component for lualine / heirline / mini.statusline:
--- `component()` returns `"m1 <server-version>"` when an m1-lsp client is
--- attached to the current buffer, `"m1 ✗"` when the plugin is set up but no
--- client is attached, and `""` for non-M1 buffers (so the section collapses).
---
--- lualine usage:
---   sections = { lualine_x = { require("nvim-m1.statusline").component } }
local M = {}

--- The attached m1-lsp client's version, resolved once per client id.
local version_cache = {}

---@return string
function M.component()
  if vim.bo.filetype ~= "m1scr" and vim.bo.filetype ~= "m1prj" then
    return ""
  end
  local name = require("nvim-m1.lsp").client_name
  local clients = vim.lsp.get_clients({ name = name, bufnr = 0 })
  if #clients == 0 then
    return "m1 ✗"
  end
  local c = clients[1]
  if version_cache[c.id] == nil then
    local v = vim.tbl_get(c, "server_info", "version")
    version_cache[c.id] = v and ("m1 v" .. v) or "m1 ✓"
  end
  return version_cache[c.id]
end

return M

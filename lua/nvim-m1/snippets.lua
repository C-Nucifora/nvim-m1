--- nvim-m1: optional M1-script editor snippets.
---
--- m1-lsp already completes the construct *heads* (if / when / expand / local /
--- static) as `InsertTextFormat::Snippet`, so those arrive in any snippet-aware
--- completion. This module bundles only the complement — the idioms the server
--- does NOT emit and which would otherwise have no Neovim path:
---
---   is       — a standalone `when` arm
---   ifelse   — the full if/else skeleton (the LSP only emits the no-else `if`)
---   nanguard — the ECU-legal `Calculate.IsNAN(v) ? fallback : v` guard
---   m1finite — the `// @m1:requires-finite` annotation
---   m1allow  — the `// @m1:allow(Txxx)` diagnostic suppression
---
--- The snippets live in `snippets/m1scr.json` in VS Code snippet format, so the
--- same file is consumable by LuaSnip's `from_vscode` loader. Loading is
--- entirely opt-in (like conform.nvim / nvim-lint): nvim-m1 never registers a
--- snippet engine for you.
---
---   -- LuaSnip (its from_vscode loader reads snippets/m1scr.json):
---   require("luasnip.loaders.from_vscode").load({
---     paths = { require("nvim-m1.snippets").dir() },
---   })
---
---   -- engine-free: expand one by name through Neovim's native vim.snippet
---   require("nvim-m1.snippets").expand("nanguard")
local M = {}

--- Absolute path to the bundled VS Code-format snippet file.
---@return string
function M.path()
  -- Resolve relative to this source file, not the cwd or the runtimepath order,
  -- so it works regardless of how the plugin was installed/symlinked.
  local src = debug.getinfo(1, "S").source:sub(2)
  local lua_dir = vim.fn.fnamemodify(vim.fn.resolve(src), ":p:h") -- lua/nvim-m1
  local root = vim.fn.fnamemodify(lua_dir, ":h:h") -- plugin root
  return root .. "/snippets/m1scr.json"
end

--- Directory holding the snippet file — the value to hand LuaSnip's
--- `from_vscode` loader `paths`.
---@return string
function M.dir()
  return vim.fn.fnamemodify(M.path(), ":h")
end

--- Read + JSON-decode the bundled snippets into a `name -> {prefix, body, ...}`
--- table (the VS Code snippet shape).
---@return table
function M.load()
  local path = M.path()
  local fh = assert(io.open(path, "r"), "nvim-m1: cannot read " .. path)
  local raw = fh:read("*a")
  fh:close()
  return vim.json.decode(raw)
end

--- Find a bundled snippet by its `prefix` (e.g. "nanguard") or by its display
--- name (e.g. "NaN guard").
---@param key string
---@return table? snip  the VS Code snippet table, or nil if no such snippet
function M.get(key)
  local data = M.load()
  if data[key] then
    return data[key]
  end
  for _, snip in pairs(data) do
    if snip.prefix == key then
      return snip
    end
  end
  return nil
end

--- Expand a bundled snippet at the cursor through Neovim's native
--- `vim.snippet.expand` (0.10+) — no LuaSnip or external engine required. The
--- VS Code bodies use the same `${n:placeholder}` / `$0` syntax `vim.snippet`
--- understands, so each `body` line array is joined with newlines and expanded.
---@param key string  a snippet prefix or display name (see get())
---@return boolean ok  false when the snippet is unknown or vim.snippet is absent
function M.expand(key)
  if not (vim.snippet and vim.snippet.expand) then
    return false
  end
  local snip = M.get(key)
  if not snip or type(snip.body) ~= "table" then
    return false
  end
  vim.snippet.expand(table.concat(snip.body, "\n"))
  return true
end

return M

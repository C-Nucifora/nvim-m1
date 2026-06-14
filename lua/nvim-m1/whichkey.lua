--- nvim-m1: optional which-key registration (#48).
---
--- Adds labelled bindings for the :M1* commands under a prefix (default
--- `<leader>m`) when which-key (v3, with the `add` API) is installed; a silent
--- no-op otherwise (which-key absent, or an older v2 with no `add`).
---
---   require("nvim-m1.whichkey").register()              -- <leader>m…
---   require("nvim-m1.whichkey").register({ prefix = "<leader>k" })
local M = {}

---@param opts? { prefix?: string }
function M.register(opts)
  local ok, wk = pcall(require, "which-key")
  if not ok then
    return false
  end
  -- `wk.add` is the which-key v3 API. v2 (and any future shape without it)
  -- exposes a different surface (`wk.register`); calling the missing `add`
  -- would raise "attempt to call a nil value". Guard on the API, not just the
  -- module, so an unusable which-key stays the documented silent no-op.
  if type(wk.add) ~= "function" then
    return false
  end
  local p = (opts and opts.prefix) or "<leader>m"
  wk.add({
    { p, group = "M1" },
    { p .. "f", "<cmd>M1Format<cr>", desc = "Format buffer" },
    { p .. "F", "<cmd>M1FormatToggle<cr>", desc = "Toggle format-on-save" },
    { p .. "l", "<cmd>M1Lint<cr>", desc = "Lint buffer" },
    { p .. "g", "<cmd>M1GenerateConfig<cr>", desc = "Generate m1-tools.toml" },
    { p .. "c", "<cmd>M1CreateChannel<cr>", desc = "Create channel" },
    { p .. "s", "<cmd>M1SetSecurity<cr>", desc = "Set security" },
    { p .. "t", "<cmd>M1SetType<cr>", desc = "Set storage type" },
    { p .. "u", "<cmd>M1SetUnit<cr>", desc = "Set display unit" },
    { p .. "r", "<cmd>M1SetCallRate<cr>", desc = "Set call rate" },
    { p .. "G", "<cmd>M1CreateGroup<cr>", desc = "Create group" },
    { p .. "R", "<cmd>M1RenameComponent<cr>", desc = "Rename component" },
    { p .. "D", "<cmd>M1DeleteComponent<cr>", desc = "Delete component" },
    { p .. "v", "<cmd>M1ValidateProject<cr>", desc = "Validate project" },
    { p .. "i", "<cmd>M1Install<cr>", desc = "Install/update toolchain" },
  })
  return true
end

return M

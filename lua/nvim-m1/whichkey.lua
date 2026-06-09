--- nvim-m1: optional which-key registration (#48).
---
--- Adds labelled bindings for the :M1* commands under a prefix (default
--- `<leader>m`) when which-key is installed; a silent no-op otherwise.
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
    { p .. "i", "<cmd>M1Install<cr>", desc = "Install/update toolchain" },
  })
  return true
end

return M

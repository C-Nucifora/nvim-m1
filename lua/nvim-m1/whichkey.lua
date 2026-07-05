--- nvim-m1: optional which-key registration (#48).
---
--- Adds labelled bindings for the :M1* commands under a prefix (default
--- `<leader>m`) when which-key (v3, with the `add` API) is installed; a silent
--- no-op otherwise (which-key absent, or an older v2 with no `add`).
---
---   require("nvim-m1.whichkey").register()              -- <leader>m…
---   require("nvim-m1.whichkey").register({ prefix = "<leader>k" })
---
--- The menu covers EVERY global :M1 command. This module only decides where each
--- command sits (its key + sub-group); the human-readable label is pulled from
--- nvim-m1's own command registries (`_tool_cmds` / `_proj_cmds` in init.lua),
--- so a description lives in exactly one place. A coverage test asserts every
--- registered command appears in LAYOUT, so a newly-added command can't silently
--- go unbound. (audit #3 — previously this hand-listed ~15 of ~30 commands.)
local M = {}

--- Where each :M1 command sits in the which-key tree. `top` entries hang
--- directly off the prefix; `groups` nest the large command families under a
--- sub-prefix so a single leader menu stays navigable. Keys are chosen for
--- mnemonic value; the label for each `cmd` comes from the command registries,
--- never duplicated here.
local LAYOUT = {
  top = {
    { key = "f", cmd = "M1Format" },
    { key = "F", cmd = "M1FormatToggle" },
    { key = "l", cmd = "M1Lint" },
    { key = "g", cmd = "M1GenerateConfig" },
    { key = "i", cmd = "M1Install" },
    { key = "u", cmd = "M1Update" },
    { key = "e", cmd = "M1RestartServer" },
    { key = "v", cmd = "M1ValidateProject" },
    { key = "S", cmd = "M1SecurityMatrix" },
    { key = "R", cmd = "M1RenameComponent" },
    { key = "D", cmd = "M1DeleteComponent" },
  },
  groups = {
    {
      key = "c",
      name = "Create",
      items = {
        { key = "c", cmd = "M1CreateChannel" },
        { key = "p", cmd = "M1CreateParameter" },
        { key = "f", cmd = "M1CreateFunction" },
        { key = "F", cmd = "M1CreateScheduledFunction" },
        { key = "g", cmd = "M1CreateGroup" },
        { key = "k", cmd = "M1CreateConstant" },
        { key = "t", cmd = "M1CreateTable" },
      },
    },
    {
      key = "s",
      name = "Set",
      items = {
        { key = "t", cmd = "M1SetType" },
        { key = "u", cmd = "M1SetUnit" },
        { key = "r", cmd = "M1SetCallRate" },
        { key = "q", cmd = "M1SetQuantity" },
        { key = "v", cmd = "M1SetValidation" },
        { key = "f", cmd = "M1SetFormat" },
        { key = "d", cmd = "M1SetDps" },
        { key = "D", cmd = "M1SetDisplayRange" },
        { key = "s", cmd = "M1SetSecurity" },
      },
    },
    {
      key = "t",
      name = "Tags",
      items = {
        { key = "a", cmd = "M1AddTag" },
        { key = "r", cmd = "M1RemoveTag" },
      },
    },
  },
}

--- Every command name LAYOUT binds — used by the coverage test to prove no
--- registered :M1 command is left out of the menu.
---@return table<string, boolean>
function M._covered()
  local set = {}
  for _, e in ipairs(LAYOUT.top) do
    set[e.cmd] = true
  end
  for _, g in ipairs(LAYOUT.groups) do
    for _, e in ipairs(g.items) do
      set[e.cmd] = true
    end
  end
  return set
end

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

  -- Labels come from nvim-m1's command registries, so each description is
  -- written once (in init.lua) and reused here.
  local nvim_m1 = require("nvim-m1")
  local descs =
    vim.tbl_extend("force", {}, nvim_m1._tool_cmds or {}, nvim_m1._proj_cmds or {})
  local function label(cmd)
    local full = descs[cmd]
    if not full then
      return cmd -- fall back to the command name if it isn't registered yet
    end
    local text = full:gsub("^nvim%-m1:%s*", "")
    return text:sub(1, 1):upper() .. text:sub(2)
  end

  local p = (opts and opts.prefix) or "<leader>m"
  local spec = { { p, group = "M1" } }
  for _, e in ipairs(LAYOUT.top) do
    table.insert(
      spec,
      { p .. e.key, ("<cmd>%s<cr>"):format(e.cmd), desc = label(e.cmd) }
    )
  end
  for _, g in ipairs(LAYOUT.groups) do
    table.insert(spec, { p .. g.key, group = g.name })
    for _, e in ipairs(g.items) do
      table.insert(
        spec,
        { p .. g.key .. e.key, ("<cmd>%s<cr>"):format(e.cmd), desc = label(e.cmd) }
      )
    end
  end
  wk.add(spec)
  return true
end

return M

-- which-key registration derives its menu from nvim-m1's command registries and
-- must cover EVERY global :M1 command — the previous hand-maintained list only
-- bound ~15 of ~30, so new commands silently went unbound. This spec pins the
-- coverage (so adding a command without a LAYOUT entry fails CI) and the two
-- documented silent no-op guards (which-key absent, or a v2 without `add`).
--
-- Its own spec file so setup() runs in a fresh nvim process (mirrors
-- user_commands_spec.lua: project_spec's e2e mocks leak a stray vim.schedule
-- callback that would otherwise contaminate a shared event loop on nightly).
local whichkey = require("nvim-m1.whichkey")

describe("nvim-m1.whichkey", function()
  local saved_loaded

  before_each(function()
    saved_loaded = package.loaded["which-key"]
  end)
  after_each(function()
    package.loaded["which-key"] = saved_loaded
  end)

  it("binds every global :M1 command (no drift from init.lua)", function()
    require("nvim-m1").setup()

    local added
    package.loaded["which-key"] = {
      add = function(spec)
        added = spec
      end,
    }
    assert.is_true(whichkey.register())

    -- Which commands the emitted spec actually binds (leaves carry an rhs).
    local bound = {}
    for _, e in ipairs(added) do
      local rhs = e[2]
      if type(rhs) == "string" then
        local cmd = rhs:match("<[Cc]md>(M1%w+)<[Cc]r>")
        if cmd then
          bound[cmd] = e.desc
        end
      end
    end

    -- Every registered global :M1 command must have a binding (buffer-local
    -- ones like M1CodeLensRun are not global and correctly excluded).
    for name in pairs(vim.api.nvim_get_commands({})) do
      if name:match("^M1") then
        assert.is_truthy(bound[name], name .. " must have a which-key binding")
        assert.is_truthy(
          bound[name] and #bound[name] > 0,
          name .. " must have a non-empty label derived from its registry desc"
        )
      end
    end
  end)

  it("labels come from the command registry, not hard-coded strings", function()
    local m = require("nvim-m1")
    m.setup()

    local added
    package.loaded["which-key"] = {
      add = function(spec)
        added = spec
      end,
    }
    whichkey.register()

    local by_cmd = {}
    for _, e in ipairs(added) do
      local rhs = e[2]
      if type(rhs) == "string" then
        local cmd = rhs:match("<[Cc]md>(M1%w+)<[Cc]r>")
        if cmd then
          by_cmd[cmd] = e.desc
        end
      end
    end
    -- The desc is the registry desc with the "nvim-m1: " prefix stripped and the
    -- first letter capitalised — proving it is derived, not retyped.
    assert.equals("Format the current buffer", by_cmd.M1Format)
    assert.equals(
      "Rename a component + its trigger references (m1-project)",
      by_cmd.M1RenameComponent
    )
  end)

  it("is a silent no-op when which-key is absent", function()
    package.loaded["which-key"] = nil -- and it is not on the test runtimepath
    assert.is_false(whichkey.register())
  end)

  it("is a silent no-op on a which-key v2 without the add API", function()
    package.loaded["which-key"] = { register = function() end } -- no `add`
    assert.is_false(whichkey.register())
  end)
end)

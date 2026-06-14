-- proj_cmd routing: every single-argument m1-project verb must be registered
-- through the one proj_cmd() helper in init.lua, never hand-rolled. The helper
-- bakes in the `M.config or config.defaults` fallback so it can't be forgotten
-- per verb — #69 was two hand-rolled commands (M1SetType/M1SetUnit) that passed
-- raw M.config and so indexed nil when invoked before setup(). Any verb
-- copy-pasted from a hand-rolled sibling re-opens that footgun, so this guards
-- against new verbs (and these previously hand-rolled ones) bypassing proj_cmd.
--
-- This lives in its own spec file so it runs in a fresh nvim process: the e2e
-- mocks in project_spec.lua leak a stray vim.schedule callback that, on Neovim
-- nightly, would otherwise contaminate any assertion that shares its event loop.
describe("nvim-m1 proj_cmd routing", function()
  it("routes every single-arg project verb through the proj_cmd helper", function()
    local m = require("nvim-m1")
    m.setup()
    assert.is_table(m._proj_cmds, "proj_cmd must record the verbs it registers")
    for _, name in ipairs({
      "M1CreateChannel",
      "M1SetSecurity",
      "M1SetCallRate",
      "M1CreateGroup",
      "M1DeleteComponent",
      "M1RenameComponent",
      "M1ValidateProject",
    }) do
      assert.is_string(
        m._proj_cmds[name],
        name .. " must be registered via proj_cmd, not hand-rolled"
      )
      -- The command really is registered (any nvim version exposes the name).
      assert.is_not_nil(
        vim.api.nvim_get_commands({})[name],
        name .. " user command exists"
      )
    end
  end)

  -- The desc proj_cmd builds is asserted from the helper's own record rather
  -- than nvim_get_commands().definition, which does not carry a Lua command's
  -- desc on recent Neovim. M1DeleteComponent's "(m1-project, confirms first)"
  -- hint can't come from the default " (m1-project)" suffix, so the helper takes
  -- a suffix override; assert both the default-suffix shape and the override.
  it("builds the right desc — default suffix and suffix override", function()
    local m = require("nvim-m1")
    m.setup()
    assert.are.equal(
      "nvim-m1: rename a component + its trigger references (m1-project)",
      m._proj_cmds.M1RenameComponent,
      "default suffix"
    )
    assert.are.equal(
      "nvim-m1: delete a component (m1-project, confirms first)",
      m._proj_cmds.M1DeleteComponent,
      "suffix override"
    )
  end)
end)

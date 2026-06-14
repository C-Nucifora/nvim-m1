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
-- nightly, would otherwise contaminate any command-introspecting assertion that
-- happens to share its event loop.
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
      assert.is_true(
        m._proj_cmds[name] == true,
        name .. " must be registered via proj_cmd, not hand-rolled"
      )
    end
  end)

  -- M1DeleteComponent's "(m1-project, confirms first)" hint can't come from the
  -- helper's default " (m1-project)" suffix, so proj_cmd takes a suffix override.
  -- Assert both shapes survive routing: a default-suffix verb and the override.
  it(
    "preserves command descriptions through the helper (default + override)",
    function()
      require("nvim-m1").setup()
      local cmds = vim.api.nvim_get_commands({})
      assert.are.equal(
        "nvim-m1: rename a component + its trigger references (m1-project)",
        cmds.M1RenameComponent.definition,
        "default suffix preserved"
      )
      assert.are.equal(
        "nvim-m1: delete a component (m1-project, confirms first)",
        cmds.M1DeleteComponent.definition,
        "suffix override preserved"
      )
    end
  )
end)

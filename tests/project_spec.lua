local project = require("nvim-m1.project")
local config = require("nvim-m1.config")

describe("nvim-m1.project", function()
  it("resolve_cmd prefers project_path, then $PATH", function()
    local cfg = config.resolve({ project_path = "/opt/m1-project" })
    assert.equals("/opt/m1-project", project.resolve_cmd(cfg))
    -- With no override, it returns the PATH binary or nil — never errors.
    assert.has_no.errors(function()
      project.resolve_cmd(config.resolve())
    end)
  end)

  it("registers the project-editing user commands after setup", function()
    require("nvim-m1").setup()
    local cmds = vim.api.nvim_get_commands({})
    assert.is_not_nil(cmds.M1CreateChannel)
    assert.is_not_nil(cmds.M1SetSecurity)
    assert.is_not_nil(cmds.M1SetCallRate)
  end)

  -- End-to-end: with the real m1-project binary on $PATH, the create-channel
  -- command drives the CLI and rewrites Project.m1prj.
  it("create_channel edits Project.m1prj via the real binary", function()
    if vim.fn.executable("m1-project") ~= 1 then
      pending("m1-project not on $PATH")
      return
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local prj = dir .. "/Project.m1prj"
    vim.fn.writefile({
      '<?xml version="1.0"?>',
      "<Project>",
      '  <Component Classname="BuiltIn.GroupCompound" Name="Root"/>',
      '  <Component Classname="BuiltIn.GroupCompound" Name="Root.Engine"/>',
      "</Project>",
    }, prj)
    -- A buffer inside the project so project_file() finds it.
    vim.cmd.edit(dir .. "/Main.m1scr")

    -- Feed the prompts: name, (type), (unit), (security).
    local inputs = { "Root.Engine.NewSignal", "" }
    local selects = { "f32", "Tune" }
    local orig_input, orig_select = vim.ui.input, vim.ui.select
    vim.ui.input = function(_, cb)
      cb(table.remove(inputs, 1))
    end
    vim.ui.select = function(_, _, cb)
      cb(table.remove(selects, 1))
    end

    local okp = pcall(function()
      project.create_channel(config.resolve())
    end)
    vim.ui.input, vim.ui.select = orig_input, orig_select
    assert.is_true(okp)

    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(
      written:find('Name="Root.Engine.NewSignal"', 1, true),
      "m1-project should have inserted the channel: " .. written
    )
    assert.is_truthy(written:find('Type="f32"', 1, true))
  end)
end)

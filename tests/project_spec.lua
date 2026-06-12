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
    -- #61: the remaining m1-project v0.4.0 verbs.
    for _, name in ipairs({
      "M1CreateParameter",
      "M1CreateFunction",
      "M1CreateScheduledFunction",
      "M1SetQuantity",
      "M1SetValidation",
      "M1SetFormat",
      "M1SetDps",
      "M1SetDisplayRange",
      "M1AddTag",
      "M1RemoveTag",
    }) do
      assert.is_not_nil(cmds[name], name .. " registered")
    end
  end)

  -- End-to-end (#61): set_validation drives the real CLI and writes MinMax
  -- bounds into the .m1prj — the in-editor remedy for T043.
  it("set_validation writes MinMax bounds via the real binary", function()
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
      '  <Component Classname="BuiltIn.Parameter" Name="Root.Engine.Gain"><Props Type="f32"/></Component>',
      "</Project>",
    }, prj)
    vim.cmd.edit(dir .. "/Main.m1scr")

    local inputs = { "Root.Engine.Gain", "0", "10" }
    local selects = { "MinMax" }
    local orig_input, orig_select = vim.ui.input, vim.ui.select
    vim.ui.input = function(_, cb)
      cb(table.remove(inputs, 1))
    end
    vim.ui.select = function(_, _, cb)
      cb(table.remove(selects, 1))
    end
    local okp = pcall(function()
      project.set_validation(require("nvim-m1.config").resolve())
    end)
    vim.ui.input, vim.ui.select = orig_input, orig_select
    assert.is_true(okp)

    -- The mutation runs async via vim.system; await the per-project queue
    -- rather than reading the file mid-write (#71).
    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "set_validation did not finish within 5s"
    )

    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(
      written:find("Validation", 1, true),
      "validation written:\n" .. written
    )
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

    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "create_channel did not finish within 5s"
    )

    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(
      written:find('Name="Root.Engine.NewSignal"', 1, true),
      "m1-project should have inserted the channel: " .. written
    )
    assert.is_truthy(written:find('Type="f32"', 1, true))
  end)

  -- #71: two mutations fired at one project without awaiting between them must
  -- both land. m1-project read-modify-writes Project.m1prj, so unserialized
  -- async runs would race and the last writer would clobber the first's edit.
  -- The per-project queue chains them; is_idle() lets us await the drain.
  it("serializes concurrent mutations so neither edit is lost (#71)", function()
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
    vim.cmd.edit(dir .. "/Main.m1scr")

    -- Drive create_channel twice back-to-back. Each resolves its mocked
    -- (synchronous) prompts and enqueues a mutation before the first subprocess
    -- has finished, so both target the same file "at once".
    local names = { "Root.Engine.Alpha", "Root.Engine.Beta" }
    local orig_input, orig_select = vim.ui.input, vim.ui.select
    local cfg = config.resolve()
    for _, name in ipairs(names) do
      local inputs = { name, "" } -- channel name, (no unit)
      local selects = { "f32", "Tune" } -- storage type, security
      vim.ui.input = function(_, cb)
        cb(table.remove(inputs, 1))
      end
      vim.ui.select = function(_, _, cb)
        cb(table.remove(selects, 1))
      end
      project.create_channel(cfg)
    end
    vim.ui.input, vim.ui.select = orig_input, orig_select

    assert.is_true(
      vim.wait(10000, function()
        return project.is_idle()
      end),
      "queued mutations did not drain within 10s"
    )

    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(
      written:find('Name="Root.Engine.Alpha"', 1, true),
      "first channel was lost — mutations were not serialized:\n" .. written
    )
    assert.is_truthy(
      written:find('Name="Root.Engine.Beta"', 1, true),
      "second channel missing:\n" .. written
    )
  end)
end)

describe("nvim-m1 next-gen additions", function()
  it("registers M1SetType and M1SetUnit (#46)", function()
    require("nvim-m1").setup()
    local cmds = vim.api.nvim_get_commands({})
    assert.is_not_nil(cmds.M1SetType)
    assert.is_not_nil(cmds.M1SetUnit)
  end)

  it("registers the m1-project v0.3.0 verbs (#51)", function()
    require("nvim-m1").setup()
    local cmds = vim.api.nvim_get_commands({})
    assert.is_not_nil(cmds.M1CreateGroup)
    assert.is_not_nil(cmds.M1DeleteComponent)
    assert.is_not_nil(cmds.M1RenameComponent)
    assert.is_not_nil(cmds.M1ValidateProject)
  end)

  -- End-to-end (#51): with the real binary, create-group edits the file and
  -- validate fills the quickfix list without errors.
  it("create_group + validate drive the real binary (#51)", function()
    if vim.fn.executable("m1-project") ~= 1 then
      pending("m1-project not on $PATH")
      return
    end
    local project = require("nvim-m1.project")
    local config = require("nvim-m1.config")
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
    vim.cmd.edit(dir .. "/Main.m1scr")

    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("Root.Engine.Sub")
    end
    local okp = pcall(function()
      project.create_group(config.resolve())
    end)
    vim.ui.input = orig_input
    assert.is_true(okp)
    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "create_group did not finish within 5s"
    )
    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(
      written:find('Name="Root.Engine.Sub"', 1, true),
      "m1-project should have inserted the group: " .. written
    )

    assert.has_no.errors(function()
      project.validate(config.resolve())
    end)
    local qf = vim.fn.getqflist({ title = true, items = true })
    assert.equals("m1-project validate", qf.title)
    assert.equals(0, #qf.items, "clean fixture must produce no findings")
  end)

  it("statusline component is empty outside M1 buffers (#47)", function()
    vim.cmd.enew()
    vim.bo.filetype = "lua"
    assert.equals("", require("nvim-m1.statusline").component())
  end)

  it("statusline shows the disconnected marker in M1 buffers (#47)", function()
    vim.cmd.enew()
    vim.bo.filetype = "m1scr"
    -- No client attached in the test harness.
    assert.equals("m1 ✗", require("nvim-m1.statusline").component())
  end)

  it("which-key registration is a silent no-op without which-key (#48)", function()
    assert.is_false(require("nvim-m1.whichkey").register())
  end)
end)

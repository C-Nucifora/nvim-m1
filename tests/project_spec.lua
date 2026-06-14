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

  -- #87: notify_reload must use the colon (method) form `client:notify(...)`.
  -- The dot form `client.notify(...)` is deprecated in Neovim 0.12 and a hard
  -- error in 0.13. The colon form passes the client as `self`; assert the fake
  -- client receives itself as the first argument (which the dot form omits).
  it("notify_reload calls client:notify (method form, not dot form) (#87)", function()
    local got_self, got_method, got_params
    local fake = {
      name = require("nvim-m1.lsp").client_name,
      notify = function(self, method, params)
        got_self, got_method, got_params = self, method, params
      end,
    }
    local orig = vim.lsp.get_clients
    vim.lsp.get_clients = function()
      return { fake }
    end
    local okp = pcall(function()
      project.notify_reload("/tmp/Some/Project.m1prj")
    end)
    vim.lsp.get_clients = orig
    assert.is_true(okp)
    -- Colon-call binds `self` to the client; dot-call would leave it as the
    -- method string. This is exactly what the 0.13 deprecation keys off.
    assert.are.equal(fake, got_self, "client:notify must pass the client as self")
    assert.are.equal("workspace/didChangeWatchedFiles", got_method)
    assert.is_table(got_params.changes)
    assert.are.equal(2, got_params.changes[1].type) -- 2 = Changed
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

  -- End-to-end (#61): set_quantity writes a physical quantity attribute.
  it("set_quantity writes a physical quantity via the real binary", function()
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
      '  <Component Classname="BuiltIn.Channel" Name="Root.Engine.Speed"><Props Type="f32"/></Component>',
      "</Project>",
    }, prj)
    vim.cmd.edit(dir .. "/Main.m1scr")

    local inputs = { "Root.Engine.Speed", "Angular Speed" }
    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb(table.remove(inputs, 1))
    end
    local okp = pcall(function()
      project.set_quantity(require("nvim-m1.config").resolve())
    end)
    vim.ui.input = orig_input
    assert.is_true(okp)

    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "set_quantity did not finish within 5s"
    )

    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(
      written:find("Angular Speed", 1, true),
      "quantity written:\n" .. written
    )
  end)

  -- End-to-end (#61): set_format writes a display format string.
  it("set_format writes a display format via the real binary", function()
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
      '  <Component Classname="BuiltIn.Channel" Name="Root.Engine.Speed"><Props Type="f32"/></Component>',
      "</Project>",
    }, prj)
    vim.cmd.edit(dir .. "/Main.m1scr")

    local inputs = { "Root.Engine.Speed", "%.1f" }
    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb(table.remove(inputs, 1))
    end
    local okp = pcall(function()
      project.set_format(require("nvim-m1.config").resolve())
    end)
    vim.ui.input = orig_input
    assert.is_true(okp)

    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "set_format did not finish within 5s"
    )

    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(written:find("%.1f", 1, true), "format written:\n" .. written)
  end)

  -- End-to-end (#61): set_dps writes a display decimal-places value.
  it("set_dps writes decimal places via the real binary", function()
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
      '  <Component Classname="BuiltIn.Channel" Name="Root.Engine.Speed"><Props Type="f32"/></Component>',
      "</Project>",
    }, prj)
    vim.cmd.edit(dir .. "/Main.m1scr")

    local inputs = { "Root.Engine.Speed", "2" }
    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb(table.remove(inputs, 1))
    end
    local okp = pcall(function()
      project.set_dps(require("nvim-m1.config").resolve())
    end)
    vim.ui.input = orig_input
    assert.is_true(okp)

    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "set_dps did not finish within 5s"
    )

    local written = table.concat(vim.fn.readfile(prj), "\n")
    -- m1-project writes DPS="<n>" (uppercase) into a Locale/Default element.
    assert.is_truthy(written:find("DPS", 1, true), "dps written:\n" .. written)
  end)

  -- End-to-end (#61): set_display_range writes display min/max bounds.
  it("set_display_range writes display min/max via the real binary", function()
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
      '  <Component Classname="BuiltIn.Channel" Name="Root.Engine.Speed"><Props Type="f32"/></Component>',
      "</Project>",
    }, prj)
    vim.cmd.edit(dir .. "/Main.m1scr")

    local inputs = { "Root.Engine.Speed", "0", "200" }
    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb(table.remove(inputs, 1))
    end
    local okp = pcall(function()
      project.set_display_range(require("nvim-m1.config").resolve())
    end)
    vim.ui.input = orig_input
    assert.is_true(okp)

    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "set_display_range did not finish within 5s"
    )

    local written = table.concat(vim.fn.readfile(prj), "\n")
    -- m1-project writes Max/Min as scientific notation, e.g. Max="2.0...e+02".
    assert.is_truthy(
      written:find("Max=", 1, true),
      "display range written:\n" .. written
    )
  end)

  -- End-to-end (#61): add_tag writes a tag entry on the component.
  it("add_tag writes a tag via the real binary", function()
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
      '  <Component Classname="BuiltIn.Channel" Name="Root.Engine.Speed"><Props Type="f32"/></Component>',
      "</Project>",
    }, prj)
    vim.cmd.edit(dir .. "/Main.m1scr")

    local inputs = { "Root.Engine.Speed", "System/Speed" }
    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb(table.remove(inputs, 1))
    end
    local okp = pcall(function()
      project.add_tag(require("nvim-m1.config").resolve())
    end)
    vim.ui.input = orig_input
    assert.is_true(okp)

    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "add_tag did not finish within 5s"
    )

    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(written:find("System/Speed", 1, true), "tag written:\n" .. written)
  end)

  -- End-to-end (#61): remove_tag removes a previously-added tag from a component.
  -- Uses add_tag first so the tag is written in the exact format m1-project
  -- expects; a hand-crafted fixture uses the wrong shape and remove-tag rejects it.
  it("remove_tag removes a tag via the real binary", function()
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
      '  <Component Classname="BuiltIn.Channel" Name="Root.Engine.Speed"><Props Type="f32"/></Component>',
      "</Project>",
    }, prj)
    vim.cmd.edit(dir .. "/Main.m1scr")
    local cfg = require("nvim-m1.config").resolve()

    -- Step 1: add the tag so m1-project writes it in its own format.
    local add_inputs = { "Root.Engine.Speed", "System/Speed" }
    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb(table.remove(add_inputs, 1))
    end
    local okp = pcall(function()
      project.add_tag(cfg)
    end)
    vim.ui.input = orig_input
    assert.is_true(okp)
    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "add_tag (setup for remove_tag) did not finish within 5s"
    )

    -- Step 2: remove the tag that was just written.
    local rm_inputs = { "Root.Engine.Speed", "System/Speed" }
    vim.ui.input = function(_, cb)
      cb(table.remove(rm_inputs, 1))
    end
    local okp2 = pcall(function()
      project.remove_tag(cfg)
    end)
    vim.ui.input = orig_input
    assert.is_true(okp2)

    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "remove_tag did not finish within 5s"
    )

    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_falsy(
      written:find("System/Speed", 1, true),
      "tag should have been removed:\n" .. written
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

  it("registers M1CreateConstant and M1CreateTable (#76)", function()
    require("nvim-m1").setup()
    local cmds = vim.api.nvim_get_commands({})
    assert.is_not_nil(cmds.M1CreateConstant)
    assert.is_not_nil(cmds.M1CreateTable)
  end)

  -- End-to-end (#76): create-constant writes a BuiltIn.Constant.
  it("create_constant adds a constant via the real binary (#76)", function()
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
      '  <Component Classname="BuiltIn.GroupCompound" Name="Root.Eng"/>',
      "</Project>",
    }, prj)
    vim.cmd.edit(dir .. "/Main.m1scr")

    local inputs = { "Root.Eng.K", "42" } -- name, value
    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb(table.remove(inputs, 1))
    end
    local okp = pcall(function()
      project.create_constant(config.resolve())
    end)
    vim.ui.input = orig_input
    assert.is_true(okp)
    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "create_constant did not finish"
    )
    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(
      written:find('Name="Root.Eng.K"', 1, true),
      "constant inserted:\n" .. written
    )
    assert.is_truthy(
      written:find("BuiltIn.Constant", 1, true),
      "as a Constant:\n" .. written
    )
  end)

  -- End-to-end (#76): create-table writes a BuiltIn.Table with an axis source.
  it("create_table adds a 1-axis table via the real binary (#76)", function()
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
      '  <Component Classname="BuiltIn.GroupCompound" Name="Root.Eng"/>',
      '  <Component Classname="BuiltIn.Channel" Name="Root.Eng.Speed"><Props Type="f32"/></Component>',
      "</Project>",
    }, prj)
    vim.cmd.edit(dir .. "/Main.m1scr")

    -- name (input), axis-x (select via pick_component), Y-axis blank (input).
    local inputs = { "Root.Eng.Map", "" }
    local orig_input, orig_select = vim.ui.input, vim.ui.select
    vim.ui.input = function(_, cb)
      cb(table.remove(inputs, 1))
    end
    vim.ui.select = function(_, _, cb)
      cb("Root.Eng.Speed")
    end
    local okp = pcall(function()
      project.create_table(config.resolve())
    end)
    vim.ui.input, vim.ui.select = orig_input, orig_select
    assert.is_true(okp)
    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "create_table did not finish"
    )
    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(
      written:find('Name="Root.Eng.Map"', 1, true),
      "table inserted:\n" .. written
    )
    assert.is_truthy(written:find("BuiltIn.Table", 1, true), "as a Table:\n" .. written)
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

describe("nvim-m1.project.set_call_rate_for (#26 in telescope-m1.nvim)", function()
  local project = require("nvim-m1.project")

  it("is a public function for picker delegation", function()
    assert.is_function(project.set_call_rate_for)
  end)

  it("sets a script's call rate through the serialized runner", function()
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
      '  <Component Classname="BuiltIn.MethodUser" Name="Root.Engine.Update"/>',
      '  <Component Classname="BuiltIn.GroupCompound" Name="Root.Events"/>',
      '  <Component Classname="BuiltIn.EventKernel" Name="Root.Events.On 100Hz"/>',
      "</Project>",
    }, prj)
    vim.cmd.edit(dir .. "/Main.m1scr")

    local done_ok
    -- "100Hz" exercises the case-insensitive Hz normalisation.
    project.set_call_rate_for(
      require("nvim-m1.config").resolve(),
      "Root.Engine.Update",
      "100Hz",
      {
        on_done = function(ok)
          done_ok = ok
        end,
      }
    )
    assert.is_true(
      vim.wait(5000, function()
        return done_ok ~= nil and project.is_idle()
      end),
      "set_call_rate_for did not finish within 5s"
    )
    assert.is_true(done_ok, "mutation must succeed")
    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(written:find("100Hz", 1, true), "call rate written:\n" .. written)
  end)
end)

-- :M1SetCallRate Hz suffix normalisation must be case-insensitive (#92).
-- The interactive command used `pick:gsub("Hz$", "")` which silently passed
-- "100hz" verbatim to m1-project when the user typed or pasted lowercase "hz".
-- The lower-level set_call_rate_for() already used "[Hh]z$"; this aligns them.
describe("nvim-m1.project set_call_rate Hz case-insensitivity (#92)", function()
  local project = require("nvim-m1.project")
  local saved_system, saved_resolve, saved_project_file, saved_notify
  local saved_ui_input, saved_ui_select

  before_each(function()
    saved_system = vim.system
    saved_resolve = project.resolve_cmd
    saved_project_file = project.project_file
    saved_notify = vim.notify
    saved_ui_input = vim.ui.input
    saved_ui_select = vim.ui.select
    project.resolve_cmd = function()
      return "/fake/m1-project"
    end
    project.project_file = function()
      return "/tmp/Some/Project.m1prj"
    end
    vim.notify = function() end
  end)

  after_each(function()
    vim.system = saved_system
    project.resolve_cmd = saved_resolve
    project.project_file = saved_project_file
    vim.notify = saved_notify
    vim.ui.input = saved_ui_input
    vim.ui.select = saved_ui_select
  end)

  it("strips lowercase 'hz' suffix before passing --rate to m1-project", function()
    local captured_cmd
    vim.system = function(cmd, _, cb)
      captured_cmd = vim.deepcopy(cmd)
      -- Invoke the callback synchronously so drain() completes in-test.
      vim.schedule(function()
        cb({ code = 0, stdout = "", stderr = "" })
      end)
    end

    -- Simulate the user typing a script name then picking "100hz" (lowercase).
    vim.ui.input = function(_, cb)
      cb("Root.Engine.Update")
    end
    vim.ui.select = function(_, _, cb)
      cb("100hz")
    end

    project.set_call_rate(require("nvim-m1.config").resolve())

    -- Allow vim.schedule callbacks (the drain completion handler) to run.
    assert.is_true(
      vim.wait(1000, function()
        return captured_cmd ~= nil
      end),
      "set_call_rate did not invoke vim.system within 1s"
    )

    -- Find the --rate argument in the command.
    local rate_val
    for i, v in ipairs(captured_cmd) do
      if v == "--rate" then
        rate_val = captured_cmd[i + 1]
        break
      end
    end
    assert.are.equal(
      "100",
      rate_val,
      "expected --rate 100 but got --rate "
        .. tostring(rate_val)
        .. " (Hz suffix not stripped)"
    )
  end)
end)

-- #91: :M1ValidateProject's vim.system():wait() must pass a timeout and be
-- pcall-wrapped, like every other sync call site (#68). Without a timeout a hung
-- `m1-project validate` blocks the UI thread forever; that's the freeze #68 was
-- created to prevent, regressed for this one command.
describe("nvim-m1.project.validate timeout (#91)", function()
  local saved_system, saved_resolve, saved_project_file, saved_notify
  local saved_setqflist

  before_each(function()
    saved_system = vim.system
    saved_resolve = project.resolve_cmd
    saved_project_file = project.project_file
    saved_notify = vim.notify
    saved_setqflist = vim.fn.setqflist
    project.resolve_cmd = function()
      return "/fake/m1-project"
    end
    project.project_file = function()
      return "/tmp/Some/Project.m1prj"
    end
    vim.notify = function() end
    vim.fn.setqflist = function() end
  end)
  after_each(function()
    vim.system = saved_system
    project.resolve_cmd = saved_resolve
    project.project_file = saved_project_file
    vim.notify = saved_notify
    vim.fn.setqflist = saved_setqflist
  end)

  it("passes a finite timeout to :wait (never an unbounded block)", function()
    local got_timeout = "unset"
    vim.system = function()
      return {
        wait = function(_, timeout)
          got_timeout = timeout
          return { code = 0, stdout = "", stderr = "" }
        end,
      }
    end
    project.validate(require("nvim-m1.config").resolve())
    assert.are.equal(5000, got_timeout, "validate must call :wait(5000), not :wait()")
  end)

  it("does not propagate a hung/errored :wait (pcall-guarded)", function()
    vim.system = function()
      return {
        wait = function()
          error("simulated subprocess hang/spawn failure")
        end,
      }
    end
    assert.has_no.errors(function()
      project.validate(require("nvim-m1.config").resolve())
    end)
  end)
end)

-- #94: end-to-end tests for create_parameter, create_function,
-- create_scheduled_function.
describe("nvim-m1.project create_parameter / create_function (#94)", function()
  -- End-to-end (#94): create_parameter writes a BuiltIn.Parameter component.
  it("create_parameter adds a parameter via the real binary", function()
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

    -- Prompts: name (input), type (select), unit (input, empty), security (select).
    local inputs = { "Root.Engine.Gain", "" }
    local selects = { "f32", "(none)" }
    local orig_input, orig_select = vim.ui.input, vim.ui.select
    vim.ui.input = function(_, cb)
      cb(table.remove(inputs, 1))
    end
    vim.ui.select = function(_, _, cb)
      cb(table.remove(selects, 1))
    end
    local okp = pcall(function()
      project.create_parameter(config.resolve())
    end)
    vim.ui.input, vim.ui.select = orig_input, orig_select
    assert.is_true(okp)

    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "create_parameter did not finish within 5s"
    )

    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(
      written:find('Name="Root.Engine.Gain"', 1, true),
      "parameter inserted:\n" .. written
    )
    assert.is_truthy(
      written:find("BuiltIn.Parameter", 1, true),
      "as a Parameter:\n" .. written
    )
  end)

  -- End-to-end (#94): create_function writes a BuiltIn.MethodUser component.
  it("create_function adds a function via the real binary", function()
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
      cb("Root.Engine.Update")
    end
    local okp = pcall(function()
      project.create_function(config.resolve())
    end)
    vim.ui.input = orig_input
    assert.is_true(okp)

    assert.is_true(
      vim.wait(5000, function()
        return project.is_idle()
      end),
      "create_function did not finish within 5s"
    )

    local written = table.concat(vim.fn.readfile(prj), "\n")
    assert.is_truthy(
      written:find('Name="Root.Engine.Update"', 1, true),
      "function inserted:\n" .. written
    )
  end)

  -- End-to-end (#94): create_scheduled_function writes a scheduled variant.
  it(
    "create_scheduled_function adds a scheduled function via the real binary",
    function()
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
        cb("Root.Engine.Tick")
      end
      local okp = pcall(function()
        project.create_scheduled_function(config.resolve())
      end)
      vim.ui.input = orig_input
      assert.is_true(okp)

      assert.is_true(
        vim.wait(5000, function()
          return project.is_idle()
        end),
        "create_scheduled_function did not finish within 5s"
      )

      local written = table.concat(vim.fn.readfile(prj), "\n")
      assert.is_truthy(
        written:find('Name="Root.Engine.Tick"', 1, true),
        "scheduled function inserted:\n" .. written
      )
    end
  )
end)

-- #95: end-to-end tests for set_security, set_type, set_unit and the
-- interactive :M1SetCallRate command.
describe(
  "nvim-m1.project set_security / set_type / set_unit / set_call_rate (#95)",
  function()
    -- End-to-end (#95): set_security writes a security attribute on a component.
    it("set_security writes a security level via the real binary", function()
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
        '  <Component Classname="BuiltIn.Channel" Name="Root.Engine.Speed"><Props Type="f32"/></Component>',
        "</Project>",
      }, prj)
      vim.cmd.edit(dir .. "/Main.m1scr")

      -- with_component prompts for a name (input), then security level (select).
      local inputs = { "Root.Engine.Speed" }
      local selects = { "Tune" }
      local orig_input, orig_select = vim.ui.input, vim.ui.select
      vim.ui.input = function(_, cb)
        cb(table.remove(inputs, 1))
      end
      vim.ui.select = function(_, _, cb)
        cb(table.remove(selects, 1))
      end
      local okp = pcall(function()
        project.set_security(config.resolve())
      end)
      vim.ui.input, vim.ui.select = orig_input, orig_select
      assert.is_true(okp)

      assert.is_true(
        vim.wait(5000, function()
          return project.is_idle()
        end),
        "set_security did not finish within 5s"
      )

      local written = table.concat(vim.fn.readfile(prj), "\n")
      assert.is_truthy(written:find("Tune", 1, true), "security written:\n" .. written)
    end)

    -- End-to-end (#95): set_type changes the storage type of a component.
    it("set_type writes a storage type via the real binary", function()
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
        '  <Component Classname="BuiltIn.Channel" Name="Root.Engine.Count"><Props Type="f32"/></Component>',
        "</Project>",
      }, prj)
      vim.cmd.edit(dir .. "/Main.m1scr")

      -- with_component prompts for a name (input), then type (select).
      local inputs = { "Root.Engine.Count" }
      local selects = { "u32" }
      local orig_input, orig_select = vim.ui.input, vim.ui.select
      vim.ui.input = function(_, cb)
        cb(table.remove(inputs, 1))
      end
      vim.ui.select = function(_, _, cb)
        cb(table.remove(selects, 1))
      end
      local okp = pcall(function()
        project.set_type(config.resolve())
      end)
      vim.ui.input, vim.ui.select = orig_input, orig_select
      assert.is_true(okp)

      assert.is_true(
        vim.wait(5000, function()
          return project.is_idle()
        end),
        "set_type did not finish within 5s"
      )

      local written = table.concat(vim.fn.readfile(prj), "\n")
      assert.is_truthy(
        written:find('Type="u32"', 1, true),
        "type written:\n" .. written
      )
    end)

    -- End-to-end (#95): set_unit writes a display unit onto a component.
    it("set_unit writes a display unit via the real binary", function()
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
        '  <Component Classname="BuiltIn.Channel" Name="Root.Engine.Speed"><Props Type="f32"/></Component>',
        "</Project>",
      }, prj)
      vim.cmd.edit(dir .. "/Main.m1scr")

      -- with_component prompts for a name (input), then unit (input).
      local inputs = { "Root.Engine.Speed", "rpm" }
      local orig_input = vim.ui.input
      vim.ui.input = function(_, cb)
        cb(table.remove(inputs, 1))
      end
      local okp = pcall(function()
        project.set_unit(config.resolve())
      end)
      vim.ui.input = orig_input
      assert.is_true(okp)

      assert.is_true(
        vim.wait(5000, function()
          return project.is_idle()
        end),
        "set_unit did not finish within 5s"
      )

      local written = table.concat(vim.fn.readfile(prj), "\n")
      assert.is_truthy(written:find("rpm", 1, true), "unit written:\n" .. written)
    end)

    -- End-to-end (#95): :M1SetCallRate (the interactive command) prompts for a
    -- script name and an execution rate, then writes the association to .m1prj.
    it("set_call_rate writes a call rate via the real binary", function()
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
        '  <Component Classname="BuiltIn.MethodUser" Name="Root.Engine.Update"/>',
        '  <Component Classname="BuiltIn.GroupCompound" Name="Root.Events"/>',
        '  <Component Classname="BuiltIn.EventKernel" Name="Root.Events.On 100Hz"/>',
        "</Project>",
      }, prj)
      vim.cmd.edit(dir .. "/Main.m1scr")

      -- set_call_rate prompts for a script name (input), then rate (select).
      local orig_input, orig_select = vim.ui.input, vim.ui.select
      vim.ui.input = function(_, cb)
        cb("Root.Engine.Update")
      end
      vim.ui.select = function(_, _, cb)
        cb("100Hz")
      end
      local okp = pcall(function()
        project.set_call_rate(config.resolve())
      end)
      vim.ui.input, vim.ui.select = orig_input, orig_select
      assert.is_true(okp)

      assert.is_true(
        vim.wait(5000, function()
          return project.is_idle()
        end),
        "set_call_rate did not finish within 5s"
      )

      local written = table.concat(vim.fn.readfile(prj), "\n")
      assert.is_truthy(
        written:find("100Hz", 1, true),
        "call rate written:\n" .. written
      )
    end)
  end
)

-- create_channel and create_parameter run the exact same name -> type -> unit ->
-- security prompt cascade and arg-assembly; the only thing that differs is the
-- subcommand verb. Refactoring them onto one shared helper means that contract
-- must hold: given identical prompt answers, the spawned command vectors must be
-- identical except for the verb. This intercepts the spawn (vim.system) so it
-- needs no real binary and pins the invariant against future drift.
describe(
  "nvim-m1.project create_channel / create_parameter share one cascade",
  function()
    local project = require("nvim-m1.project")
    local config = require("nvim-m1.config")

    -- Run `fn` against a throwaway project, feeding the same prompt answers
    -- (name, type, unit, security) and capturing the command vim.system would
    -- spawn. Returns the captured command vector (or nil if none was spawned).
    local function capture_cmd(fn, answers)
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local prj = dir .. "/Project.m1prj"
      vim.fn.writefile({
        '<?xml version="1.0"?>',
        "<Project>",
        '  <Component Classname="BuiltIn.GroupCompound" Name="Root"/>',
        "</Project>",
      }, prj)
      vim.cmd.edit(dir .. "/Main.m1scr")

      local inputs = { answers.name, answers.unit }
      local selects = { answers.ty, answers.sec }
      local orig_input, orig_select = vim.ui.input, vim.ui.select
      local orig_system = vim.system
      local captured
      vim.ui.input = function(_, cb)
        cb(table.remove(inputs, 1))
      end
      vim.ui.select = function(_, _, cb)
        cb(table.remove(selects, 1))
      end
      -- Intercept the spawn: record the command and never actually run it; drive
      -- the success path so the queue drains and is_idle() goes true.
      vim.system = function(cmd, _, on_exit)
        captured = cmd
        vim.schedule(function()
          on_exit({ code = 0, stdout = "", stderr = "" })
        end)
        return { wait = function() end }
      end

      local okp = pcall(function()
        fn(config.resolve())
      end)
      vim.wait(2000, function()
        return project.is_idle()
      end)
      vim.ui.input, vim.ui.select, vim.system = orig_input, orig_select, orig_system
      assert.is_true(okp)
      -- Strip the `--project <path>` pair (per-run temp dir, not part of the
      -- cascade under test) so two runs are comparable.
      if captured then
        local out = {}
        local i = 1
        while i <= #captured do
          if captured[i] == "--project" then
            i = i + 2
          else
            out[#out + 1] = captured[i]
            i = i + 1
          end
        end
        captured = out
      end
      return captured
    end

    -- The captured (project-stripped) command is `{ bin, verb, ...rest }`; drop
    -- the verb (index 2) so the two commands can be compared byte-for-byte.
    local function without_verb(cmd)
      local rest = {}
      for i = 1, #cmd do
        if i ~= 2 then
          rest[#rest + 1] = cmd[i]
        end
      end
      return rest
    end

    it("build identical commands modulo the verb for the same answers", function()
      local answers = { name = "Root.X", ty = "f32", unit = "rpm", sec = "Tune" }
      local chan = capture_cmd(project.create_channel, vim.deepcopy(answers))
      local param = capture_cmd(project.create_parameter, vim.deepcopy(answers))

      assert.is_table(chan, "create_channel should spawn m1-project")
      assert.is_table(param, "create_parameter should spawn m1-project")
      assert.equals("create-channel", chan[2])
      assert.equals("create-parameter", param[2])
      assert.same(
        without_verb(chan),
        without_verb(param),
        "the two cascades must produce identical args apart from the verb"
      )
    end)

    -- The '(none)'/empty guards must be applied identically by both paths.
    it("both omit type/unit/security args identically when skipped", function()
      local answers = { name = "Root.Y", ty = "(none)", unit = "", sec = "(none)" }
      local chan = capture_cmd(project.create_channel, vim.deepcopy(answers))
      local param = capture_cmd(project.create_parameter, vim.deepcopy(answers))

      assert.same(without_verb(chan), without_verb(param))
      -- Only `--project <prj> --name Root.Y` should remain — no optional flags.
      assert.is_nil(
        vim.tbl_contains(chan, "--type") and "found --type" or nil,
        "type must be omitted for (none)"
      )
      assert.is_falsy(vim.tbl_contains(chan, "--type"))
      assert.is_falsy(vim.tbl_contains(chan, "--unit"))
      assert.is_falsy(vim.tbl_contains(chan, "--security"))
    end)
  end
)

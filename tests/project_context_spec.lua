describe("project identity across prompts", function()
  local project = require("nvim-m1.project")
  local dir, original, buffers, pending_input, messages, cfg

  before_each(function()
    assert.equals(1, vim.fn.executable("m1-project"), "real m1-project required")
    original = {
      input = vim.ui.input,
      notify = vim.notify,
      buf = vim.api.nvim_get_current_buf(),
    }
    dir = vim.fn.tempname()
    buffers, messages = {}, {}
    for _, name in ipairs({ "a", "b", "empty" }) do
      vim.fn.mkdir(dir .. "/" .. name, "p")
      if name ~= "empty" then
        vim.fn.writefile({
          '<Project><Component Classname="BuiltIn.GroupCompound" Name="Root"/>',
          '<Component Classname="BuiltIn.Channel" Name="Root.Speed"><Props Type="f32"/></Component></Project>',
        }, dir .. "/" .. name .. "/Project.m1prj")
      end
      buffers[name] = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buffers[name], dir .. "/" .. name .. "/Main.m1scr")
    end
    cfg = require("nvim-m1.config").resolve()
    vim.ui.input = function(_, cb)
      pending_input = cb
    end
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
  end)

  after_each(function()
    vim.ui.input, vim.notify = original.input, original.notify
    vim.api.nvim_set_current_buf(original.buf)
    for _, buf in pairs(buffers) do
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    vim.fn.delete(dir, "rf")
  end)

  local function read(name)
    return table.concat(vim.fn.readfile(dir .. "/" .. name .. "/Project.m1prj"), "\n")
  end

  it("keeps a delayed unit edit on its original project", function()
    local a = read("a")
    vim.api.nvim_set_current_buf(buffers.b)
    project.set_unit(cfg, "Root.Speed")
    vim.api.nvim_set_current_buf(buffers.a)
    pending_input("rpm")
    assert.is_true(vim.wait(5000, project.is_idle))
    assert.equals(a, read("a"))
    assert.is_truthy(read("b"):find("rpm", 1, true))
  end)

  it("does not discover a different project after starting without one", function()
    local a = read("a")
    vim.api.nvim_set_current_buf(buffers.empty)
    project.set_unit(cfg, "Root.Speed")
    vim.api.nvim_set_current_buf(buffers.a)
    pending_input("rpm")
    assert.is_true(vim.wait(5000, project.is_idle))
    assert.equals(a, read("a"))
    assert.is_truthy(table.concat(messages):find("no Project.m1prj", 1, true))
  end)

  it("honors an explicit binding without changing shared config", function()
    local a = read("a")
    vim.api.nvim_set_current_buf(buffers.a)
    local bound = project.bind_project(cfg, dir .. "/b/Project.m1prj")
    project.set_unit(bound, "Root.Speed")
    pending_input("kPa")
    assert.is_true(vim.wait(5000, project.is_idle))
    assert.equals(a, read("a"))
    assert.is_truthy(read("b"):find("kPa", 1, true))
    assert.is_nil(cfg._project_file)
    assert.equals(
      vim.uv.fs_realpath(dir .. "/a/Project.m1prj"),
      vim.uv.fs_realpath(project.project_file(cfg))
    )
  end)
end)

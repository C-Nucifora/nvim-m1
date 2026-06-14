-- Security-matrix audit view (#102): parity with m1-vscode's
-- `m1.showSecurityMatrix` (vscode #78). Renders every secured channel/parameter
-- as a Component × access-level grid grouped by top-level subsystem, into a
-- read-only scratch buffer — the pre-competition audit view.
local project = require("nvim-m1.project")
local config = require("nvim-m1.config")

describe("nvim-m1.project.security_matrix", function()
  it("registers the :M1SecurityMatrix user command after setup", function()
    require("nvim-m1").setup()
    local cmds = vim.api.nvim_get_commands({})
    assert.is_not_nil(cmds.M1SecurityMatrix, "M1SecurityMatrix registered")
  end)

  it("exposes security_matrix as a public function", function()
    assert.is_function(project.security_matrix)
  end)

  -- The matrix is built from `list-components --json`, the exact payload the
  -- vscode view consumes. Intercept the spawn so no real binary is needed and
  -- the rendered buffer can be asserted deterministically.
  it(
    "renders only secured components, grouped by subsystem, with a hit column",
    function()
      local saved_system = vim.system
      local saved_resolve = project.resolve_cmd
      local saved_project_file = project.project_file
      local saved_notify = vim.notify
      project.resolve_cmd = function()
        return "/fake/m1-project"
      end
      project.project_file = function()
        return "/tmp/Some/Project.m1prj"
      end
      vim.notify = function() end

      local payload = vim.json.encode({
        { path = "Root", classname = "BuiltIn.GroupCompound", security = vim.NIL },
        {
          path = "Root.Engine.Speed",
          classname = "BuiltIn.Channel",
          security = "Tune",
        },
        {
          path = "Root.Engine.Gain",
          classname = "BuiltIn.Parameter",
          security = "Calibration",
        },
        {
          path = "Root.Chassis.Damping",
          classname = "BuiltIn.Parameter",
          security = "Master Calibration",
        },
        -- Unsecured: must be filtered out of the matrix.
        {
          path = "Root.Engine.Temp",
          classname = "BuiltIn.Channel",
          security = vim.NIL,
        },
      })
      -- Two synchronous (:wait) call sites now: the matrix sources its *columns*
      -- from `list-security` (#106) and its *rows* from `list-components`. Answer
      -- each by verb — the built-in groups for the columns, the payload for the
      -- rows — so the probe doesn't swallow the components JSON as a bogus level.
      vim.system = function(cmd)
        return {
          wait = function()
            if cmd[2] == "list-security" then
              return {
                code = 0,
                stdout = "Tune\nCalibration\nMaster Calibration\nResource\n",
                stderr = "",
              }
            end
            return { code = 0, stdout = payload, stderr = "" }
          end,
        }
      end

      local ok = pcall(function()
        project.security_matrix(config.resolve())
      end)
      vim.system = saved_system
      project.resolve_cmd = saved_resolve
      project.project_file = saved_project_file
      vim.notify = saved_notify
      assert.is_true(ok)

      -- The active buffer should be the read-only scratch matrix.
      local buf = vim.api.nvim_get_current_buf()
      assert.are.equal(
        "nofile",
        vim.bo[buf].buftype,
        "matrix buffer is a scratch buffer"
      )
      assert.is_false(vim.bo[buf].modifiable, "matrix buffer is read-only")

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = table.concat(lines, "\n")

      -- Header columns mirror the vscode levels.
      assert.is_truthy(text:find("Component", 1, true), "has a Component header")
      assert.is_truthy(text:find("Tune", 1, true), "has the Tune level")
      assert.is_truthy(
        text:find("Master Calibration", 1, true),
        "has Master Calibration"
      )
      assert.is_truthy(text:find("Resource", 1, true), "has the Resource level")

      -- Secured components are listed.
      assert.is_truthy(
        text:find("Root.Engine.Speed", 1, true),
        "lists Root.Engine.Speed"
      )
      assert.is_truthy(text:find("Root.Engine.Gain", 1, true), "lists Root.Engine.Gain")
      assert.is_truthy(
        text:find("Root.Chassis.Damping", 1, true),
        "lists Root.Chassis.Damping"
      )

      -- Grouped by the 2nd path segment (Root.<Subsystem>.…).
      assert.is_truthy(text:find("Engine", 1, true), "has an Engine group heading")
      assert.is_truthy(text:find("Chassis", 1, true), "has a Chassis group heading")

      -- The unsecured component is NOT in the matrix.
      assert.is_nil(
        text:find("Root.Engine.Temp", 1, true),
        "omits unsecured components"
      )
    end
  )

  it("notifies (does not error) when no secured components exist", function()
    local saved_system = vim.system
    local saved_resolve = project.resolve_cmd
    local saved_project_file = project.project_file
    local saved_notify = vim.notify
    local notified
    project.resolve_cmd = function()
      return "/fake/m1-project"
    end
    project.project_file = function()
      return "/tmp/Some/Project.m1prj"
    end
    vim.notify = function(msg)
      notified = msg
    end
    vim.system = function()
      return {
        wait = function()
          return {
            code = 0,
            stdout = vim.json.encode({
              { path = "Root.Engine.Temp", security = vim.NIL },
            }),
            stderr = "",
          }
        end,
      }
    end

    local ok = pcall(function()
      project.security_matrix(config.resolve())
    end)
    vim.system = saved_system
    project.resolve_cmd = saved_resolve
    project.project_file = saved_project_file
    vim.notify = saved_notify
    assert.is_true(ok)
    assert.is_truthy(notified, "an empty matrix is reported via vim.notify")
  end)

  -- #91/#68 pattern: the list-components :wait() must pass a finite timeout and
  -- be pcall-guarded so a hung subprocess degrades gracefully, never freezes.
  it("degrades to a notification when the subprocess hangs/errors", function()
    local saved_system = vim.system
    local saved_resolve = project.resolve_cmd
    local saved_project_file = project.project_file
    local saved_notify = vim.notify
    project.resolve_cmd = function()
      return "/fake/m1-project"
    end
    project.project_file = function()
      return "/tmp/Some/Project.m1prj"
    end
    vim.notify = function() end
    vim.system = function()
      return {
        wait = function(_, timeout)
          assert.is_number(timeout, "list-components :wait must pass a timeout")
          error("simulated subprocess hang")
        end,
      }
    end

    local ok = pcall(function()
      project.security_matrix(config.resolve())
    end)
    vim.system = saved_system
    project.resolve_cmd = saved_resolve
    project.project_file = saved_project_file
    vim.notify = saved_notify
    assert.is_true(ok, "a hung list-components must not propagate an error")
  end)

  -- End-to-end (#102): with the real m1-project on $PATH, the matrix is built
  -- from the binary's actual `list-components --json` payload — pinning the
  -- argv + the `security` field name against drift between this and m1-project.
  it("builds the matrix from the real binary's list-components --json", function()
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
      '  <Component Classname="BuiltIn.Channel" Name="Root.Engine.Speed"><Props Type="f32" Security="Tune"/></Component>',
      '  <Component Classname="BuiltIn.Channel" Name="Root.Engine.Temp"><Props Type="f32"/></Component>',
      "</Project>",
    }, prj)
    vim.cmd.edit(dir .. "/Main.m1scr")

    local ok = pcall(function()
      project.security_matrix(config.resolve())
    end)
    assert.is_true(ok)

    local buf = vim.api.nvim_get_current_buf()
    assert.are.equal("nofile", vim.bo[buf].buftype)
    assert.is_false(vim.bo[buf].modifiable)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(
      text:find("Root.Engine.Speed", 1, true),
      "secured channel listed:\n" .. text
    )
    assert.is_nil(
      text:find("Root.Engine.Temp", 1, true),
      "unsecured channel omitted:\n" .. text
    )
    assert.is_truthy(text:find("Tune", 1, true), "Tune level present:\n" .. text)
  end)
end)

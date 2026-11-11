describe("project mutation completion", function()
  local project, original, callbacks, started, results, messages
  before_each(function()
    original = {
      module = package.loaded["nvim-m1.project"],
      system = vim.system,
      notify = vim.notify,
      input = vim.ui.input,
    }
    package.loaded["nvim-m1.project"] = nil
    project = require("nvim-m1.project")
    project.resolve_cmd = function()
      return "m1-project"
    end
    project.project_file = function()
      return "/fixture/Project.m1prj"
    end
    project.notify_reload = function() end
    callbacks, started, results, messages = {}, {}, {}, {}
    vim.system = function(cmd, _, cb)
      table.insert(started, cmd[2])
      table.insert(callbacks, cb)
      return {}
    end
    vim.notify = function(msg)
      table.insert(messages, msg)
    end
  end)

  after_each(function()
    vim.system, vim.notify, vim.ui.input =
      original.system, original.notify, original.input
    package.loaded["nvim-m1.project"] = original.module
  end)

  local function submit(id, after)
    project.set_call_rate_for({}, "Root.Main", "100", {
      on_done = function(ok, err)
        table.insert(results, { id = id, ok = ok, err = err })
        if after then
          after()
        end
      end,
    })
  end

  local function complete()
    table.remove(callbacks, 1)({ code = 0, stdout = "", stderr = "" })
    assert.is_true(vim.wait(1000, function()
      return #callbacks > 0 or project.is_idle()
    end))
  end

  for _, failure in ipairs({ "spawn", "reload", "toast", "done" }) do
    it(
      "drains after " .. failure .. " failure without retrying a successful write",
      function()
        if failure == "spawn" then
          local system = vim.system
          vim.system = function(...)
            vim.system = system
            error("fixture spawn failure")
          end
        elseif failure == "reload" then
          project.notify_reload = function()
            error("fixture reload failure")
          end
        elseif failure == "toast" then
          vim.notify = function()
            error("fixture toast failure")
          end
        end
        submit(1, failure == "done" and function()
          error("fixture done failure")
        end or nil)
        submit(2)
        if failure ~= "spawn" then
          complete()
        end
        assert.is_true(vim.wait(1000, function()
          return #callbacks == 1
        end))
        complete()
        assert.is_true(project.is_idle())
        assert.equals(2, #results)
        assert.equals(1, results[1].id)
        assert.equals(failure ~= "spawn", results[1].ok)
        assert.equals(2, results[2].id)
        assert.is_true(results[2].ok)
        assert.is_nil(results[2].err)
        if failure == "spawn" then
          assert.matches("fixture spawn failure", results[1].err)
        elseif failure == "reload" then
          assert.matches("reload", table.concat(messages, "\n"))
        end
      end
    )
  end

  it("drains after a rename success callback raises", function()
    vim.ui.input = function(_, cb)
      cb("Renamed")
    end
    vim.notify = function()
      error("fixture rename callback failure")
    end
    project.rename_component({}, "Root.Main")
    submit(2)
    complete()
    complete()
    assert.same({ "rename-component", "set-call-rate" }, started)
    assert.is_true(project.is_idle())
    assert.is_true(results[1].ok)
  end)

  it("keeps FIFO order when a completion submits another mutation", function()
    submit(1, function()
      submit(3)
    end)
    submit(2)
    complete()
    complete()
    complete()
    assert.same({ 1, 2, 3 }, { results[1].id, results[2].id, results[3].id })
    assert.is_true(project.is_idle())
  end)

  it("handles a failed process once and continues the queue", function()
    submit(1)
    submit(2)
    local cb = table.remove(callbacks, 1)
    cb({ code = 1, stderr = "fixture CLI failure" })
    cb({ code = 1, stderr = "fixture CLI failure" })
    assert.is_true(vim.wait(1000, function()
      return #callbacks == 1
    end))
    complete()
    assert.is_true(project.is_idle())
    assert.equals(2, #results)
    assert.is_false(results[1].ok)
    assert.equals("fixture CLI failure", results[1].err)
    assert.is_true(results[2].ok)
  end)
end)

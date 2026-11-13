describe("installer shared filesystem safety", function()
  local install, other, dir, original, release, paths
  before_each(function()
    local source = vim.api.nvim_get_runtime_file("lua/nvim-m1/install.lua", false)[1]
    install, other = dofile(source), dofile(source)
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    for _, module in ipairs({ install, other }) do
      module.bin_dir = function()
        return dir
      end
      module.needs_resign = function()
        return false
      end
    end
    original = { system = vim.system, notify = vim.notify }
    release, paths = {}, {}
    vim.notify = function() end
    vim.system = function(cmd, _, cb)
      local path
      for i, arg in ipairs(cmd) do
        if arg == "-o" then
          path = cmd[i + 1]
        end
      end
      assert(path)
      paths[#paths + 1] = path
      vim.fn.writefile({ "fixture bytes" }, path)
      cb({ code = 0, stdout = "", stderr = "" })
      return {}
    end
    for _, module in ipairs({ install, other }) do
      module.attest_verify_async = function(path, _, cb)
        release[#release + 1] = function()
          cb(true)
        end
      end
    end
  end)

  after_each(function()
    vim.system, vim.notify = original.system, original.notify
    vim.fn.delete(dir, "rf")
  end)

  it(
    "refuses a second installer until the first completes and preserves both entries",
    function()
      local first, second
      install.install_async({ "m1-lint" }, function(ok)
        first = ok
      end)
      assert.is_true(vim.wait(1000, function()
        return #release == 1
      end))
      other.install_async({ "m1-fmt" }, function(ok)
        second = ok
      end)
      assert.is_false(second)
      assert.equals(1, #paths)
      release[1]()
      assert.is_true(first)
      release = {}
      other.install_async({ "m1-fmt" }, function(ok)
        second = ok
      end)
      assert.is_true(vim.wait(1000, function()
        return #release == 1
      end))
      release[1]()
      assert.is_true(second)
      assert.same({
        ["m1-lint"] = install.versions["m1-lint"],
        ["m1-fmt"] = other.versions["m1-fmt"],
      }, install.installed_versions())
    end
  )

  it("does not write through a fixed download or manifest symlink", function()
    if vim.fn.has("win32") == 1 then
      pending("requires unprivileged symlinks")
      return
    end
    local victim = dir .. "/victim"
    vim.fn.writefile({ "keep" }, victim)
    assert(vim.uv.fs_symlink(victim, install.tool_path("m1-lint") .. ".part"))
    assert(vim.uv.fs_symlink(victim, install.manifest_path()))
    local done
    install.install_async({ "m1-lint" }, function(ok)
      done = ok
    end)
    assert.is_true(vim.wait(1000, function()
      return #release == 1
    end))
    release[1]()
    assert.is_true(done)
    assert.same({ "keep" }, vim.fn.readfile(victim))
    assert.is_not.equal(install.tool_path("m1-lint") .. ".part", paths[1])
    assert.equals("file", vim.uv.fs_lstat(install.manifest_path()).type)
  end)

  it("releases its lock and in-process guard when spawning fails", function()
    vim.system = function()
      error("fixture spawn failure")
    end
    local done
    assert.has_no.errors(function()
      install.install_async({ "m1-lint" }, function(ok)
        done = ok
      end)
    end)
    assert.is_false(done)
    assert.is_false(install._in_flight)
    assert.is_nil(vim.uv.fs_stat(dir .. "/.install-lock"))
  end)

  it("reports a manifest write failure instead of reporting success", function()
    vim.fn.mkdir(install.manifest_path(), "p")
    local done
    install.install_async({ "m1-lint" }, function(ok)
      done = ok
    end)
    assert.is_true(vim.wait(1000, function()
      return #release == 1
    end))
    release[1]()
    assert.is_false(done)
    assert.is_false(install._in_flight)
    assert.is_nil(vim.uv.fs_stat(dir .. "/.install-lock"))
  end)
  it("does not remove a lock owned by another installer", function()
    vim.fn.mkdir(dir .. "/.install-lock", "p")
    vim.fn.writefile({ "another owner" }, dir .. "/.install-lock/owner")
    local done
    install.fetch_async("m1-lint", function(ok)
      done = ok
    end)
    assert.is_false(done)
    assert.same({ "another owner" }, vim.fn.readfile(dir .. "/.install-lock/owner"))
    assert.equals(0, #paths)
  end)

  it("treats malformed manifest shapes as unreadable", function()
    for _, data in ipairs({ "[]", '["v1"]', '{"m1-lint":{}}' }) do
      vim.fn.writefile({ data }, install.manifest_path())
      assert.same({}, install.installed_versions())
    end
  end)
  for _, failed_write in ipairs({ 1, 2 }) do
    it(
      "keeps version metadata safe when manifest write " .. failed_write .. " fails",
      function()
        local tool = "m1-lint"
        vim.fn.writefile({ "old bytes" }, install.tool_path(tool))
        vim.uv.fs_chmod(install.tool_path(tool), 493)
        vim.fn.writefile(
          { vim.json.encode({ [tool] = "old pin", ["m1-fmt"] = "keep" }) },
          install.manifest_path()
        )
        install.versions[tool] = "new pin"
        other.versions[tool] = "old pin"
        local write, calls = vim.uv.fs_write, 0
        vim.uv.fs_write = function(...)
          calls = calls + 1
          if calls == failed_write then
            return nil, "ENOSPC: fixture"
          end
          return write(...)
        end
        local done
        local ok, err = pcall(function()
          install.install_async({ tool }, function(result)
            done = result
          end)
          assert.is_true(vim.wait(1000, function()
            return #release == 1
          end))
          release[1]()
        end)
        vim.uv.fs_write = write
        assert.is_true(ok, err)
        assert.is_false(done)
        local versions = install.installed_versions()
        assert.equals("keep", versions["m1-fmt"])
        if failed_write == 1 then
          assert.same({ "old bytes" }, vim.fn.readfile(install.tool_path(tool)))
          assert.equals("old pin", versions[tool])
        else
          assert.same({ "fixture bytes" }, vim.fn.readfile(install.tool_path(tool)))
          assert.is_nil(versions[tool])
          assert.is_true(vim.tbl_contains(other.stale_tools(), tool))
        end
        assert.is_false(install._in_flight)
        assert.is_nil(vim.uv.fs_stat(dir .. "/.install-lock"))
      end
    )
  end

  it("cancels pending promotion after its exit handler releases the lock", function()
    vim.fn.writefile({ "old bytes" }, install.tool_path("m1-lint"))
    local done
    install.install_async({ "m1-lint" }, function(ok)
      done = ok
    end)
    assert.is_true(vim.wait(1000, function()
      return #release == 1
    end))
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    release[1]()
    assert.is_false(done)
    assert.same({ "old bytes" }, vim.fn.readfile(install.tool_path("m1-lint")))
    assert.is_nil(vim.uv.fs_stat(install.manifest_path()))
    assert.is_false(install._in_flight)
    assert.same({}, vim.fn.glob(dir .. "/.download-*", false, true))
  end)

  it("finishes verification even when a warning notifier raises", function()
    local source = vim.api.nvim_get_runtime_file("lua/nvim-m1/install.lua", false)[1]
    install.attest_verify_async = dofile(source).attest_verify_async
    local exepath, system = vim.fn.exepath, vim.system
    vim.fn.exepath = function(name)
      return "/fixture/" .. name
    end
    vim.system = function(cmd, opts, cb)
      if cmd[2] == "attestation" then
        vim.schedule(function()
          cb({ code = 1, stderr = "no attestations found" })
        end)
        return {}
      end
      return system(cmd, opts, cb)
    end
    vim.notify = function(_, level)
      if level == vim.log.levels.WARN then
        error("fixture notification failure")
      end
    end
    local callbacks, done = 0, nil
    install.install_async({ "m1-lint" }, function(ok)
      callbacks = callbacks + 1
      done = ok
    end)
    local completed = vim.wait(1000, function()
      return done ~= nil
    end)
    vim.fn.exepath = exepath
    assert.is_true(completed)
    assert.is_true(done)
    assert.equals(1, callbacks)
    assert.is_false(install._in_flight)
    assert.is_nil(vim.uv.fs_stat(dir .. "/.install-lock"))
    assert.same({}, vim.fn.glob(dir .. "/.download-*", false, true))
  end)
end)

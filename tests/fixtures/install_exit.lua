-- A later exit hook pumps events while another process owns the released lock.
local root, shared = vim.env.M1_INSTALL_TEST_ROOT, vim.env.M1_INSTALL_TEST_DIR
vim.opt.runtimepath:prepend(root)
local install = require("nvim-m1.install")
install.bin_dir = function()
  return shared .. "/bin"
end
install.needs_resign = function()
  return false
end
install.versions["m1-lint"] = "new pin"
local system = vim.system
vim.system = function(cmd, opts, cb)
  cmd[#cmd] = vim.uri_from_fname(shared .. "/a.payload")
  return system(cmd, opts, cb)
end
local done
install.attest_verify_async = function(_, _, complete)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      local child = system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-l",
        root .. "/tests/fixtures/install_process.lua",
        root,
        shared,
        "b",
        "m1-fmt",
        "hold",
      }, { text = true })
      local ok, err = pcall(function()
        assert(vim.wait(4000, function()
          return vim.fn.filereadable(shared .. "/b.verified") == 1
        end))
        complete(true)
        assert(done == false, "released operation must be cancelled")
        assert(vim.fn.readfile(install.tool_path("m1-lint"))[1] == "old bytes")
        vim.fn.writefile({}, shared .. "/release")
        local result = child:wait(4000)
        assert(result.code == 0, result.stderr)
        local manifest = install.installed_versions()
        assert(manifest["m1-lint"] == "old pin" and manifest["m1-fmt"] == "fixture-b")
        assert(not vim.uv.fs_stat(install.bin_dir() .. "/.install-lock"))
        assert(#vim.fn.glob(install.bin_dir() .. "/.download-*", false, true) == 0)
      end)
      if not child:is_closing() then
        child:kill(15)
      end
      child:wait(1000)
      vim.fn.writefile({ ok and "passed" or tostring(err) }, shared .. "/exit.result")
    end,
  })
  vim.schedule(function()
    vim.cmd("qa!")
  end)
end
install.install_async({ "m1-lint" }, function(ok)
  done = ok
end)

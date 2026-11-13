describe("installer across Neovim processes", function()
  for _, second_tool in ipairs({ "m1-lint", "m1-fmt" }) do
    it("serializes promotion and manifest merging for " .. second_tool, function()
      if vim.fn.executable("curl") ~= 1 then
        pending("requires curl")
        return
      end
      local root = vim.fn.fnamemodify(
        vim.api.nvim_get_runtime_file("lua/nvim-m1/install.lua", false)[1],
        ":h:h:h"
      )
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/bin", "p")
      local children = {}
      local function start(name, tool, held)
        vim.fn.writefile(
          { name .. " verified bytes" },
          dir .. "/" .. name .. ".payload"
        )
        local process = vim.system({
          vim.v.progpath,
          "--headless",
          "-u",
          "NONE",
          "-i",
          "NONE",
          "-l",
          root .. "/tests/fixtures/install_process.lua",
          root,
          dir,
          name,
          tool,
          held or "go",
        }, { text = true })
        children[#children + 1] = process
        return process
      end
      local function lines(name)
        return vim.fn.readfile(dir .. "/" .. name)
      end
      local ok, err = pcall(function()
        vim.fn.writefile({ "keep this" }, dir .. "/victim")
        if vim.fn.has("win32") ~= 1 then
          assert(vim.uv.fs_symlink(dir .. "/victim", dir .. "/bin/m1-lint.part"))
          assert(vim.uv.fs_symlink(dir .. "/victim", dir .. "/bin/.installed.json"))
        end
        local a = start("a", "m1-lint", "hold")
        assert.is_true(vim.wait(5000, function()
          return vim.fn.filereadable(dir .. "/a.verified") == 1
        end))
        local b = start("b", second_tool)
        local blocked = b:wait(5000)
        assert.equals(0, blocked.code, blocked.stderr)
        assert.same({ "false" }, lines("b.result"))
        assert.equals(0, vim.fn.filereadable(dir .. "/b.verified"))
        vim.fn.writefile({}, dir .. "/release")
        local first = a:wait(5000)
        assert.equals(0, first.code, first.stderr)
        assert.same({ "true" }, lines("a.result"))
        local suffix = require("nvim-m1.install").platform()
        suffix = suffix == "x86_64-pc-windows-msvc" and ".exe" or ""
        assert.equals(lines("a.verified")[2], lines("bin/m1-lint" .. suffix)[1])
        assert.same({ "keep this" }, lines("victim"))
        local retry = start("b", second_tool):wait(5000)
        assert.equals(0, retry.code, retry.stderr)
        assert.same({ "true" }, lines("b.result"))
        assert.equals(lines("b.verified")[2], lines("bin/" .. second_tool .. suffix)[1])
        local manifest =
          vim.json.decode(table.concat(lines("bin/.installed.json"), "\n"))
        local expected = { ["m1-lint"] = "fixture-a" }
        expected[second_tool] = "fixture-b"
        assert.same(expected, manifest)
        assert.is_nil(vim.uv.fs_stat(dir .. "/bin/.install-lock"))
        assert.same({}, vim.fn.glob(dir .. "/bin/.download-*", false, true))
        assert.same({}, vim.fn.glob(dir .. "/bin/.manifest-*", false, true))
      end)
      for _, child in ipairs(children) do
        if child:is_closing() == false then
          child:kill(15)
        end
        child:wait(1000)
      end
      vim.fn.delete(dir, "rf")
      assert.is_true(ok, err)
    end)
  end
  it(
    "revokes pending writes during a real exit while another process installs",
    function()
      if vim.fn.executable("curl") ~= 1 then
        pending("requires curl")
        return
      end
      local root = vim.fn.fnamemodify(
        vim.api.nvim_get_runtime_file("lua/nvim-m1/install.lua", false)[1],
        ":h:h:h"
      )
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/bin", "p")
      local _, suffix = require("nvim-m1.install").platform()
      vim.fn.writefile({ "old bytes" }, dir .. "/bin/m1-lint" .. suffix)
      vim.fn.writefile({ '{"m1-lint":"old pin"}' }, dir .. "/bin/.installed.json")
      vim.fn.writefile({ "new bytes" }, dir .. "/a.payload")
      vim.fn.writefile({ "other bytes" }, dir .. "/b.payload")
      local child = vim.system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-c",
        "lua dofile(vim.env.M1_INSTALL_TEST_ROOT .. '/tests/fixtures/install_exit.lua')",
      }, {
        text = true,
        env = { M1_INSTALL_TEST_ROOT = root, M1_INSTALL_TEST_DIR = dir },
      })
      local result = child:wait(12000)
      local outcome = vim.fn.filereadable(dir .. "/exit.result") == 1
          and vim.fn.readfile(dir .. "/exit.result")
        or {}
      vim.fn.delete(dir, "rf")
      assert.equals(0, result.code, result.stderr)
      assert.same({ "passed" }, outcome)
    end
  )
end)

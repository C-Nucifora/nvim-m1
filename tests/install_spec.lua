--- Unit tests for nvim-m1.install (resolution + platform mapping; no network).
local install = require("nvim-m1.install")

describe("nvim-m1.install", function()
  it("pins a version and repo for every default tool", function()
    for _, tool in ipairs(install.tools) do
      assert.is_string(install.versions[tool], tool .. " must have a pinned version")
      assert.is_string(install.repos[tool], tool .. " must have a source repo")
    end
  end)

  it("maps the running platform to a release-asset triple", function()
    local triple, suffix, err = install.platform()
    if vim.uv.os_uname().sysname == "Linux" then
      assert.equals("x86_64-unknown-linux-gnu", triple)
      assert.equals("", suffix)
      assert.is_nil(err)
    else
      -- On other platforms either a triple or a clear error, never both nil/ok.
      assert.is_true(triple ~= nil or err ~= nil)
    end
  end)

  it("tool_path lives under the data dir's nvim-m1/bin", function()
    local p = install.tool_path("m1-lsp")
    assert.is_truthy(p:find("nvim%-m1/bin/m1%-lsp"))
  end)

  it(
    "needs_resign() is true on macOS (codesign the download) and false elsewhere",
    function()
      assert.equals(vim.uv.os_uname().sysname == "Darwin", install.needs_resign())
    end
  )

  it("resolve() prefers an explicit override over $PATH and the bundle", function()
    assert.equals("/custom/m1-lsp", install.resolve("m1-lsp", "/custom/m1-lsp"))
  end)

  it("resolve() returns nil when a tool is nowhere to be found", function()
    -- A tool name that is neither on $PATH nor bundled.
    assert.is_nil(install.resolve("m1-nonexistent-tool-xyz"))
  end)

  describe("attest_verify (build-provenance gate, #21)", function()
    -- Drive M.attest_verify through its branches by stubbing the `gh` lookup,
    -- the shell-out, and notify — no network, no real gh invocation.
    local saved_exepath, saved_system, saved_notify
    local notes

    --- Stub gh-present + a `gh attestation verify` result. `vim.v.shell_error`
    --- is read-only, so the stub runs a real trivial process (`exit <code>`) to
    --- set it the way vim.fn.system genuinely would, then returns the canned
    --- gh output text.
    ---@param present boolean  whether `gh` resolves on $PATH
    ---@param exit integer     exit code the faked `gh` returns
    ---@param output string    canned combined stdout/stderr
    local function stub(present, exit, output)
      vim.fn.exepath = function(name)
        if name == "gh" then
          return present and "/usr/bin/gh" or ""
        end
        return saved_exepath(name)
      end
      vim.fn.system = function()
        saved_system({ "sh", "-c", "exit " .. tostring(exit) })
        return output
      end
    end

    before_each(function()
      notes = {}
      saved_exepath = vim.fn.exepath
      saved_system = vim.fn.system
      saved_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
      end
    end)

    after_each(function()
      vim.fn.exepath = saved_exepath
      vim.fn.system = saved_system
      vim.notify = saved_notify
    end)

    it("passes when gh reports the artifact verified (exit 0)", function()
      stub(true, 0, "Verification succeeded!")
      local ok, err = install.attest_verify("/tmp/m1-lsp", "C-Nucifora/m1-lsp")
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("ABORTS on a genuine verification failure (present, authed gh)", function()
      stub(true, 1, "Error: verification failed: signature does not match")
      local ok, err = install.attest_verify("/tmp/m1-lsp", "C-Nucifora/m1-lsp")
      assert.is_false(ok)
      assert.is_string(err)
      assert.is_truthy(err:find("FAILED", 1, true))
    end)

    it("warns + proceeds when no attestation exists (release predates it)", function()
      stub(true, 1, "Error: HTTP 404: Not Found (.../attestations/sha256:abc)")
      local ok, err = install.attest_verify("/tmp/m1-lsp", "C-Nucifora/m1-lsp")
      assert.is_true(ok)
      assert.is_nil(err)
      assert.equals(vim.log.levels.WARN, notes[1].level)
    end)

    it("warns + proceeds when gh is unauthenticated", function()
      stub(true, 4, "To get started with GitHub CLI, please run:  gh auth login")
      local ok, err = install.attest_verify("/tmp/m1-lsp", "C-Nucifora/m1-lsp")
      assert.is_true(ok)
      assert.is_nil(err)
      assert.equals(vim.log.levels.WARN, notes[1].level)
    end)

    it("warns + proceeds when gh is not installed at all", function()
      stub(false, 0, "")
      local ok, err = install.attest_verify("/tmp/m1-lsp", "C-Nucifora/m1-lsp")
      assert.is_true(ok)
      assert.is_nil(err)
      assert.equals(vim.log.levels.WARN, notes[1].level)
    end)
  end)

  describe("install manifest + staleness (#26)", function()
    -- bin_dir() lives under XDG_DATA_HOME, which scripts/test.sh points at a
    -- throwaway temp dir — so writing/creating files here is hermetic.
    local saved_fetch, saved_notify

    local function fake_binary(tool)
      vim.fn.mkdir(install.bin_dir(), "p")
      local p = install.tool_path(tool)
      local f = assert(io.open(p, "w"))
      f:write("#!/bin/sh\n")
      f:close()
      vim.fn.system({ "chmod", "+x", p })
      return p
    end

    local function write_manifest(tbl)
      vim.fn.mkdir(install.bin_dir(), "p")
      local f = assert(io.open(install.manifest_path(), "w"))
      f:write(vim.json.encode(tbl))
      f:close()
    end

    before_each(function()
      saved_fetch = install.fetch
      saved_notify = vim.notify
      vim.notify = function() end
      vim.fn.delete(install.bin_dir(), "rf")
    end)
    after_each(function()
      install.fetch = saved_fetch
      vim.notify = saved_notify
      vim.fn.delete(install.bin_dir(), "rf")
    end)

    it("install() records the versions it installed in a manifest", function()
      install.fetch = function()
        return true
      end -- no network
      install.install({ "m1-lint", "m1-project" })
      local v = install.installed_versions()
      assert.equals(install.versions["m1-lint"], v["m1-lint"])
      assert.equals(install.versions["m1-project"], v["m1-project"])
    end)

    it("install() does not record a tool whose download failed", function()
      install.fetch = function(tool)
        return tool ~= "m1-lint", "boom"
      end
      install.install({ "m1-lint", "m1-project" })
      local v = install.installed_versions()
      assert.is_nil(v["m1-lint"])
      assert.equals(install.versions["m1-project"], v["m1-project"])
    end)

    it("installed_versions() is empty when nothing has been installed", function()
      assert.same({}, install.installed_versions())
    end)

    it("stale_tools() flags a bundled binary recorded below the pin", function()
      fake_binary("m1-lint")
      write_manifest({ ["m1-lint"] = "v0.0.1" })
      assert.is_true(vim.tbl_contains(install.stale_tools(), "m1-lint"))
    end)

    it("stale_tools() flags a bundled binary with no manifest entry", function()
      fake_binary("m1-lint")
      assert.is_true(vim.tbl_contains(install.stale_tools(), "m1-lint"))
    end)

    it("stale_tools() does NOT flag a binary recorded at the pinned version", function()
      fake_binary("m1-lint")
      write_manifest({ ["m1-lint"] = install.versions["m1-lint"] })
      assert.is_false(vim.tbl_contains(install.stale_tools(), "m1-lint"))
    end)

    it("stale_tools() ignores tools that are not bundled on disk", function()
      assert.same({}, install.stale_tools())
    end)
  end)
end)

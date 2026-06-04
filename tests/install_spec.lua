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

  it("bin_dir is under root_dir (cargo --root's bin / download target)", function()
    assert.equals(install.root_dir() .. "/bin", install.bin_dir())
  end)

  it("git_url builds a clonable URL for every default tool", function()
    for _, tool in ipairs(install.tools) do
      local url = install.git_url(tool)
      assert.equals("https://github.com/" .. install.repos[tool] .. ".git", url)
    end
    assert.is_nil(install.git_url("m1-nonexistent-tool-xyz"))
  end)

  it("from_source() is true on macOS (build) and false elsewhere (download)", function()
    assert.equals(vim.uv.os_uname().sysname == "Darwin", install.from_source())
  end)

  it("resolve() prefers an explicit override over $PATH and the bundle", function()
    assert.equals("/custom/m1-lsp", install.resolve("m1-lsp", "/custom/m1-lsp"))
  end)

  it("resolve() returns nil when a tool is nowhere to be found", function()
    -- A tool name that is neither on $PATH nor bundled.
    assert.is_nil(install.resolve("m1-nonexistent-tool-xyz"))
  end)
end)

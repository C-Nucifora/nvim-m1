--- Unit tests for nvim-m1.health's version-drift classification (#70).
local health = require("nvim-m1.health")

describe("nvim-m1.health.version_status (#70)", function()
  it("ok when the installed version matches the pin", function()
    local level, msg = health.version_status("m1-lsp", "v0.36.0", "v0.36.0", true)
    assert.equals("ok", level)
    assert.equals("m1-lsp v0.36.0", msg)
  end)

  it("warns with both versions + :M1Update when the bundle trails the pin", function()
    local level, msg = health.version_status("m1-lsp", "v0.36.0", "v0.35.0", true)
    assert.equals("warn", level)
    assert.is_truthy(msg:find("v0.35.0 installed", 1, true))
    assert.is_truthy(msg:find("v0.36.0 pinned", 1, true))
    assert.is_truthy(msg:find(":M1Update", 1, true))
  end)

  it("warns when the binary is bundled but carries no manifest version", function()
    local level, msg = health.version_status("m1-fmt", "v0.11.0", nil, true)
    assert.equals("warn", level)
    assert.is_truthy(msg:find("unversioned", 1, true))
    assert.is_truthy(msg:find("v0.11.0 pinned", 1, true))
  end)

  it("info (not warn) when the tool is not bundled — user-managed / $PATH", function()
    -- No manifest entry and not on disk: nvim-m1 doesn't track its version, so
    -- this must not false-alarm green->red; it just notes the pin target.
    local level, msg = health.version_status("m1-project", "v0.4.0", nil, false)
    assert.equals("info", level)
    assert.is_truthy(msg:find("not bundled", 1, true))
    assert.is_truthy(msg:find("v0.4.0", 1, true))
  end)

  it("uses the same equality the self-heal's stale_tools() does", function()
    -- A drift the comparison must catch matches what stale_tools flags.
    local install = require("nvim-m1.install")
    for _, tool in ipairs(install.tools) do
      local level = health.version_status(tool, install.versions[tool], "v0.0.1", true)
      assert.equals("warn", level, tool .. " drift must warn")
      local okl = health.version_status(
        tool,
        install.versions[tool],
        install.versions[tool],
        true
      )
      assert.equals("ok", okl, tool .. " match must be ok")
    end
  end)
end)

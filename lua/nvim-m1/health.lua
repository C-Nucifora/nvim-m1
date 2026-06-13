--- nvim-m1: `:checkhealth nvim-m1`.
local M = {}

local h = vim.health or require("health")
local start = h.start or h.report_start
local ok = h.ok or h.report_ok
local warn = h.warn or h.report_warn
local err = h.error or h.report_error
local info = h.info or h.report_info

--- Classify a bundled tool's installed version against the pinned version (#70).
--- Pure (no vim.health calls) so it is unit-testable; check() renders the verdict.
--- `have` is the install-manifest entry (nil if none), `bundled` whether the
--- binary is on disk. Same equality the self-heal's stale_tools() uses.
---@param tool string
---@param want string   pinned version (vX.Y.Z)
---@param have string?  installed version from the manifest, or nil
---@param bundled boolean  whether the bundled binary exists on disk
---@return "ok"|"warn"|"info" level, string msg
function M.version_status(tool, want, have, bundled)
  if have == want then
    return "ok", tool .. " " .. want
  elseif have then
    return "warn",
      ("%s %s installed, %s pinned — run :M1Update"):format(tool, have, want)
  elseif bundled then
    return "warn",
      ("%s installed but unversioned, %s pinned — run :M1Update"):format(tool, want)
  else
    return "info", tool .. " not bundled by nvim-m1 (pinned: " .. want .. ")"
  end
end

function M.check()
  local nvim_m1 = require("nvim-m1")
  local cfg = nvim_m1.config or require("nvim-m1.config").defaults

  start("nvim-m1: Neovim")
  if vim.fn.has("nvim-0.10") == 1 then
    ok("Neovim " .. tostring(vim.version()))
  else
    err("Neovim >= 0.10 required")
  end

  start("nvim-m1: toolchain binaries")
  local server = require("nvim-m1.lsp").resolve_cmd(cfg)
  if server then
    ok("m1-lsp: " .. server)
  else
    warn("m1-lsp not found", {
      "Run :M1Install to download the bundled toolchain, or set opts.server_path.",
    })
  end

  local install = require("nvim-m1.install")
  local fmt = install.resolve("m1-fmt")
  if fmt then
    ok("m1-fmt: " .. fmt .. " (formatting)")
  else
    warn("m1-fmt not found — formatting falls back to the LSP", {
      "Run :M1Install to download the bundled toolchain.",
    })
  end
  local lintbin = install.resolve("m1-lint")
  if lintbin then
    ok("m1-lint: " .. lintbin .. " (standalone lint)")
  else
    warn("m1-lint not found — standalone lint uses the LSP's diagnostics", {
      "Run :M1Install to download the bundled toolchain.",
    })
  end
  local proj = require("nvim-m1.project").resolve_cmd(cfg)
  if proj then
    ok("m1-project: " .. proj .. " (:M1Create*/Set*/Rename/Delete/Validate)")
  else
    warn("m1-project not found — project-editing commands unavailable", {
      "Run :M1Install to download the bundled toolchain, or set opts.project_path.",
    })
  end

  start("nvim-m1: bundled toolchain")
  info("install dir: " .. install.bin_dir())
  local triple, _, perr = install.platform()
  if triple then
    ok(
      "platform: " .. triple .. " (pinned m1-lsp " .. install.versions["m1-lsp"] .. ")"
    )
  else
    warn(perr or "unsupported platform for prebuilt binaries")
  end
  -- Compare the on-disk bundled binaries against the pinned versions (#70). The
  -- self-heal already diffs these on the first M1 open, but it can't run when
  -- offline, a download failed, or the binaries are user-managed — leaving
  -- :checkhealth as the only place a maintainer sees that the running toolchain
  -- trails the pin (the stale-binary situation behind stale-hover bug reports).
  -- Same comparison stale_tools() uses: the manifest records each bundled
  -- install at the pinned `vX.Y.Z` string, so an equality check is exact.
  local installed = install.installed_versions()
  local report = { ok = ok, warn = warn, info = info }
  for _, tool in ipairs(install.tools) do
    local bundled = vim.fn.executable(install.tool_path(tool)) == 1
    local level, msg =
      M.version_status(tool, install.versions[tool], installed[tool], bundled)
    report[level](msg)
  end

  -- macOS: the downloaded binary is re-signed ad-hoc on install (the released
  -- asset's signature is killed by AMFI on Apple Silicon); that needs codesign.
  if install.needs_resign() then
    if vim.fn.exepath("codesign") ~= "" then
      ok("codesign present (re-signs the downloaded macOS binaries on install)")
    else
      warn("codesign not found — the downloaded macOS binaries will be killed", {
        "codesign ships with the Xcode Command Line Tools:",
        "  xcode-select --install",
        "then run :M1Install.",
      })
    end
  end

  start("nvim-m1: tree-sitter")
  local treesitter = require("nvim-m1.treesitter")
  local no_cc = treesitter.find_cc() == ""
  if treesitter.parser_installed() then
    ok("`m1` parser installed")
  elseif no_cc then
    err("`m1` parser not built and no C compiler found", {
      "nvim-m1 compiles the parser from tree-sitter-m1's sources on setup;",
      "install a C compiler (cc/gcc/clang) on $PATH, then restart Neovim.",
    })
  else
    warn("`m1` parser not built", {
      "Ensure C-Nucifora/tree-sitter-m1 is installed (it is a dependency);",
      "nvim-m1 compiles the parser from its sources automatically on setup.",
    })
  end

  start("nvim-m1: optional integrations")
  for _, mod in ipairs({
    { "conform", "format-on-save backend (else falls back to LSP formatting)" },
    { "lint", "standalone-lint backend (else falls back to a built-in runner)" },
    { "blink.cmp", "richer completion capabilities" },
    { "telescope", "telescope-m1.nvim pickers" },
  }) do
    if pcall(require, mod[1]) then
      ok(mod[1] .. ": " .. mod[2])
    else
      info(mod[1] .. " not installed — " .. mod[2])
    end
  end
end

return M

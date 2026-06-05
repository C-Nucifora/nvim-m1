--- nvim-m1: bundled M1 toolchain installer.
---
--- So `nvim-m1` is a one-package install (the Neovim analogue of m1-vscode's
--- bundled server), this downloads the pinned, prebuilt M1 tool binaries for the
--- running platform into `stdpath("data")/nvim-m1/bin` and the tool resolvers
--- fall back to them. Run automatically via the lazy.nvim `build` hook (see the
--- README) or on demand with `:M1Install` / `:M1Update`.
---
--- On macOS the downloaded binary is re-signed ad-hoc after download: the
--- released asset's signature does not validate on Apple Silicon, so AMFI kills
--- it at exec (SIGKILL, "Code Signature Invalid") and the LSP never attaches; a
--- fresh local `codesign --force --sign -` makes it run. `codesign` ships with
--- the Xcode Command Line Tools — the same package as the C compiler nvim-m1
--- already requires — so this adds no new prerequisite. (nvim-m1#15)
---
--- m1-lsp is the essential one — it serves diagnostics (lint + types), hover,
--- completion, formatting and rename (it embeds m1-fmt/m1-lint/m1-typecheck).
--- m1-project powers the `:M1*` project-editing commands; m1-fmt/m1-lint are
--- fetched too so the conform.nvim / nvim-lint paths work without a manual install.
local M = {}

--- Pinned tool versions this nvim-m1 release ships against. Bump these (and cut
--- an nvim-m1 release) to upgrade the bundled toolchain — the Neovim analogue of
--- m1-vscode's `package.json` `serverVersion` pin.
M.versions = {
  ["m1-lsp"] = "v0.23.0",
  ["m1-fmt"] = "v0.4.3",
  ["m1-lint"] = "v0.7.0",
  ["m1-project"] = "v0.1.1",
}

--- The GitHub repo each tool's release binaries come from.
M.repos = {
  ["m1-lsp"] = "C-Nucifora/m1-lsp",
  ["m1-fmt"] = "C-Nucifora/m1-fmt",
  ["m1-lint"] = "C-Nucifora/m1-lint",
  ["m1-project"] = "nedlane/m1-project",
}

--- Tools installed by default. m1-typecheck is embedded in m1-lsp (its
--- diagnostics arrive through the server), so it is not fetched standalone.
M.tools = { "m1-lsp", "m1-fmt", "m1-lint", "m1-project" }

--- Directory the bundled binaries are installed into (kept off the repo; lives
--- under the Neovim data dir).
---@return string
function M.bin_dir()
  return vim.fs.normalize(vim.fn.stdpath("data") .. "/nvim-m1/bin")
end

--- The release-asset platform triple + executable suffix for the running OS/arch,
--- matching the names the tool `release.yml`s publish.
---@return string? triple, string suffix, string? err
function M.platform()
  local u = vim.uv.os_uname()
  local sys, machine = u.sysname, u.machine
  if sys == "Linux" and (machine == "x86_64" or machine == "amd64") then
    return "x86_64-unknown-linux-gnu", ""
  elseif sys == "Darwin" and (machine == "arm64" or machine == "aarch64") then
    return "aarch64-apple-darwin", ""
  elseif
    sys:match("Windows")
    or sys:match("MINGW")
    or sys:match("MSYS")
    or sys:match("CYGWIN")
  then
    return "x86_64-pc-windows-msvc", ".exe"
  end
  return nil,
    "",
    ("no prebuilt M1 binaries for %s/%s — build from source and set the *_path opts"):format(
      sys,
      machine
    )
end

--- Where a bundled tool binary lives (whether or not it is installed yet).
---@param tool string
---@return string
function M.tool_path(tool)
  local _, suffix = M.platform()
  return M.bin_dir() .. "/" .. tool .. (suffix or "")
end

--- Resolve a tool command: an explicit override, then `$PATH`, then the bundled
--- binary. Returns nil if none is executable.
---@param tool string
---@param explicit? string
---@return string?
function M.resolve(tool, explicit)
  if explicit and explicit ~= "" then
    return explicit
  end
  if vim.fn.executable(tool) == 1 then
    return tool
  end
  local bundled = M.tool_path(tool)
  if vim.fn.executable(bundled) == 1 then
    return bundled
  end
  return nil
end

--- Whether a downloaded binary must be re-signed to run (macOS). The released
--- `aarch64-apple-darwin` asset's ad-hoc signature does not validate on user
--- machines, so AMFI kills it at exec (SIGKILL, "Code Signature Invalid"); a
--- fresh local ad-hoc re-sign fixes it. (nvim-m1#15)
---@return boolean
function M.needs_resign()
  return vim.uv.os_uname().sysname == "Darwin"
end

--- Re-sign `path` ad-hoc on macOS so the freshly-downloaded binary runs. A no-op
--- (returns ok) off macOS. `codesign` ships with the Xcode Command Line Tools —
--- the same package that provides the C compiler nvim-m1 already needs.
---@param path string
---@return boolean ok, string? err
local function resign(path)
  if not M.needs_resign() then
    return true
  end
  local codesign = vim.fn.exepath("codesign")
  if codesign == "" then
    return false,
      "codesign not found — install the Xcode Command Line Tools "
        .. "(xcode-select --install); the downloaded macOS binary is otherwise "
        .. "killed by the code-signing check"
  end
  vim.fn.system({ codesign, "--force", "--sign", "-", path })
  if vim.v.shell_error ~= 0 then
    return false, "failed to re-sign " .. path .. " with codesign"
  end
  return true
end

--- Download one tool's pinned release binary into `bin_dir()` (re-signing it
--- ad-hoc on macOS so it will run).
---@param tool string
---@return boolean ok, string? err
local function fetch(tool)
  local triple, suffix, err = M.platform()
  if not triple then
    return false, err
  end
  local version, repo = M.versions[tool], M.repos[tool]
  if not (version and repo) then
    return false, "unknown tool: " .. tostring(tool)
  end

  local curl = vim.fn.exepath("curl")
  if curl == "" then
    return false, "curl not found on $PATH (needed to download the M1 toolchain)"
  end

  vim.fn.mkdir(M.bin_dir(), "p")
  local asset = ("%s-%s%s"):format(tool, triple, suffix)
  local url = ("https://github.com/%s/releases/download/%s/%s"):format(
    repo,
    version,
    asset
  )
  local dest = M.bin_dir() .. "/" .. tool .. suffix

  local res = vim.fn.system({ curl, "-fSL", "--retry", "2", "-o", dest, url })
  if vim.v.shell_error ~= 0 then
    return false,
      ("failed to download %s %s\n  %s\n  %s"):format(tool, version, url, res)
  end
  if suffix == "" then
    vim.fn.system({ "chmod", "+x", dest })
  end
  local rok, rerr = resign(dest)
  if not rok then
    return false, rerr
  end
  return true
end

--- Install (download) the bundled M1 toolchain. Safe to re-run; overwrites with
--- the pinned versions.
---@param tools? string[]  Subset to install (default: all of `M.tools`).
---@return boolean ok
function M.install(tools)
  tools = tools or M.tools
  local triple, _, err = M.platform()
  if not triple then
    vim.notify("nvim-m1: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  local all_ok = true
  for _, tool in ipairs(tools) do
    vim.notify(("nvim-m1: installing %s %s…"):format(tool, M.versions[tool]))
    local ok, ferr = fetch(tool)
    if not ok then
      all_ok = false
      vim.notify("nvim-m1: " .. tostring(ferr), vim.log.levels.ERROR)
    end
  end
  if all_ok then
    vim.notify("nvim-m1: toolchain installed into " .. M.bin_dir())
  end
  return all_ok
end

return M

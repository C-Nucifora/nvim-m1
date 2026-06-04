--- nvim-m1: bundled M1 toolchain installer.
---
--- So `nvim-m1` is a one-package install (the Neovim analogue of m1-vscode's
--- bundled server), this puts the pinned M1 tool binaries for the running
--- platform into `stdpath("data")/nvim-m1/bin` and the tool resolvers fall back
--- to them. Run automatically via the lazy.nvim `build` hook (see the README) or
--- on demand with `:M1Install` / `:M1Update`.
---
--- How they get there is platform-dependent:
---
---   * macOS builds from source with `cargo install`. The prebuilt release
---     assets are only linker-signed ad-hoc, and on Apple Silicon that signature
---     does not validate, so AMFI kills the process at exec time (SIGKILL, Code
---     Signature Invalid) and the LSP never attaches. A binary `cargo` compiles
---     locally is signed validly for the machine, so it just runs.
---   * Linux and Windows download the pinned, prebuilt release binary — no
---     code-signing to satisfy there, so a download is faster and needs no Rust
---     toolchain.
---
--- m1-lsp is the essential one — it serves diagnostics (lint + types), hover,
--- completion, formatting and rename (it embeds m1-fmt/m1-lint/m1-typecheck).
--- m1-project powers the `:M1*` project-editing commands; m1-fmt/m1-lint are
--- fetched too so the conform.nvim / nvim-lint paths work without a manual install.
local M = {}

--- Pinned tool versions this nvim-m1 release ships against. Bump these (and cut
--- an nvim-m1 release) to upgrade the bundled toolchain — the Neovim analogue of
--- m1-vscode's `package.json` `serverVersion` pin. Each is the git tag / release.
M.versions = {
  ["m1-lsp"] = "v0.21.0",
  ["m1-fmt"] = "v0.4.1",
  ["m1-lint"] = "v0.5.1",
  ["m1-project"] = "v0.1.0",
}

--- The GitHub repo each tool's source / release binaries come from (`owner/name`).
M.repos = {
  ["m1-lsp"] = "C-Nucifora/m1-lsp",
  ["m1-fmt"] = "C-Nucifora/m1-fmt",
  ["m1-lint"] = "C-Nucifora/m1-lint",
  ["m1-project"] = "nedlane/m1-project",
}

--- Tools installed by default. m1-typecheck is embedded in m1-lsp (its
--- diagnostics arrive through the server), so it is not installed standalone.
M.tools = { "m1-lsp", "m1-fmt", "m1-lint", "m1-project" }

--- Whether this platform builds the toolchain from source (macOS) rather than
--- downloading a prebuilt release asset. macOS does because the ad-hoc-signed
--- release binaries are SIGKILLed on Apple Silicon; a local build is signed
--- validly for the machine.
---@return boolean
function M.from_source()
  return vim.uv.os_uname().sysname == "Darwin"
end

--- Root `cargo install` writes into (`<root>/bin/<tool>` plus its bookkeeping);
--- also the parent of `bin_dir()`. Kept off the repo; lives under the data dir.
---@return string
function M.root_dir()
  return vim.fs.normalize(vim.fn.stdpath("data") .. "/nvim-m1")
end

--- Directory the bundled binaries land in (download target / `cargo install`'s
--- `--root`'s `bin/`).
---@return string
function M.bin_dir()
  return M.root_dir() .. "/bin"
end

--- The git URL `cargo install --git` clones a tool's source from (macOS build).
---@param tool string
---@return string?
function M.git_url(tool)
  local repo = M.repos[tool]
  return repo and ("https://github.com/" .. repo .. ".git") or nil
end

--- The release-asset platform triple + executable suffix for the running OS/arch,
--- matching the names the tool `release.yml`s publish. Used for the download
--- path; the suffix is also what `tool_path` needs to find a built binary.
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

--- Download one tool's pinned release binary into `bin_dir()` (Linux/Windows).
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
  return true
end

--- Build one tool's pinned source into `bin_dir()` with `cargo install` (macOS).
--- Local compilation yields a binary signed validly for this machine (unlike the
--- ad-hoc-signed release assets), and `--locked` builds the pinned `Cargo.lock`.
---@param tool string
---@return boolean ok, string? err
local function build(tool)
  local version, url = M.versions[tool], M.git_url(tool)
  if not (version and url) then
    return false, "unknown tool: " .. tostring(tool)
  end

  local cargo = vim.fn.exepath("cargo")
  if cargo == "" then
    return false,
      "cargo not found on $PATH — install the Rust toolchain (https://rustup.rs) "
        .. "to build the M1 toolchain from source"
  end

  vim.fn.mkdir(M.root_dir(), "p")
  local res = vim.fn.system({
    cargo,
    "install",
    "--git",
    url,
    "--tag",
    version,
    "--bin",
    tool,
    "--root",
    M.root_dir(),
    "--locked",
    "--force",
  })
  if vim.v.shell_error ~= 0 then
    return false,
      ("failed to build %s %s from source\n  %s\n  %s"):format(tool, version, url, res)
  end
  return true
end

--- Install the bundled M1 toolchain — build from source on macOS, download a
--- prebuilt release binary elsewhere. Safe to re-run; overwrites with the pinned
--- versions.
---@param tools? string[]  Subset to install (default: all of `M.tools`).
---@return boolean ok
function M.install(tools)
  tools = tools or M.tools
  local from_source = M.from_source()

  -- Fail fast with a clear, platform-appropriate prerequisite message.
  if from_source then
    if vim.fn.exepath("cargo") == "" then
      vim.notify(
        "nvim-m1: cargo not found on $PATH — install the Rust toolchain "
          .. "(https://rustup.rs) to build the M1 toolchain from source",
        vim.log.levels.ERROR
      )
      return false
    end
  else
    local triple, _, err = M.platform()
    if not triple then
      vim.notify("nvim-m1: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
  end

  local verb = from_source and "building" or "downloading"
  local all_ok = true
  for _, tool in ipairs(tools) do
    local msg = ("nvim-m1: %s %s %s…"):format(verb, tool, M.versions[tool])
    if from_source then
      msg = msg .. " (this can take a minute)"
    end
    vim.notify(msg)
    local ok, ierr = (from_source and build or fetch)(tool)
    if not ok then
      all_ok = false
      vim.notify("nvim-m1: " .. tostring(ierr), vim.log.levels.ERROR)
    end
  end
  if all_ok then
    vim.notify(
      ("nvim-m1: toolchain %s into %s"):format(
        from_source and "built" or "installed",
        M.bin_dir()
      )
    )
  end
  return all_ok
end

return M

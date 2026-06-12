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
---
--- Every downloaded binary is verified against GitHub-native build provenance
--- (`gh attestation verify`) before it is made executable / run, so a tampered
--- or substituted release asset is rejected (HTTPS only protects the transport;
--- the residual risk is upstream account/release compromise). See
--- `M.attest_verify`. (nvim-m1#21)
local M = {}

--- Pinned tool versions this nvim-m1 release ships against. Bump these (and cut
--- an nvim-m1 release) to upgrade the bundled toolchain — the Neovim analogue of
--- m1-vscode's `package.json` `serverVersion` pin.
M.versions = {
  ["m1-lsp"] = "v0.37.0",
  ["m1-fmt"] = "v0.12.0",
  ["m1-lint"] = "v0.18.0",
  ["m1-project"] = "v0.6.0",
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

--- Verify a freshly-downloaded binary's integrity via GitHub-native build
--- provenance (`gh attestation verify`) BEFORE it is made executable / run.
---
--- The producer release workflows attach `actions/attest-build-provenance`
--- attestations; this checks the on-disk artifact against the signed claim that
--- `<repo>`'s Actions workflow built it, catching a tampered/substituted asset
--- (the supply-chain risk: upstream account/release compromise or GitHub-side
--- asset swap — HTTPS only protects the transport). (nvim-m1#21)
---
--- Verification is REQUIRED when it can run: a genuine mismatch aborts the
--- install of that binary. It degrades to a WARN-and-proceed (returns ok) only
--- when verification is impossible without hard-breaking users mid-rollout:
---   * `gh` is not installed, or
---   * `gh` is not authenticated (no token), or
---   * the release predates attestation (no attestation found for this digest).
--- These are the "can't verify" cases, distinct from "verified and WRONG".
---@param path string  Path to the downloaded artifact.
---@param repo string  `owner/name` the asset was downloaded from.
---@return boolean ok, string? err
local judge_attestation -- forward declaration (defined below attest_verify)

--- WARN that gh is absent so provenance cannot be checked (shared notify).
---@param repo string
local function notify_no_gh(repo)
  vim.notify(
    ("nvim-m1: gh CLI not found — skipping build-provenance verification of %s. "):format(
      repo
    )
      .. "Install GitHub CLI (https://cli.github.com) to verify downloaded binaries.",
    vim.log.levels.WARN
  )
end

function M.attest_verify(path, repo)
  local gh = vim.fn.exepath("gh")
  if gh == "" then
    notify_no_gh(repo)
    return true
  end

  -- List form (no shell): `path` and `repo` are passed as argv elements, never
  -- interpolated into a shell string, so no quoting/injection is possible even
  -- if a value contained shell metacharacters.
  local out = vim.fn.system({ gh, "attestation", "verify", path, "--repo", repo })
  return judge_attestation(vim.v.shell_error, out, path, repo)
end

--- Async [`M.attest_verify`]: the `gh attestation verify` network round-trip
--- runs off the UI thread; `cb(ok, err?)` is invoked on the main loop with the
--- same verdict the sync form returns (#65).
---@param path string
---@param repo string
---@param cb fun(ok: boolean, err?: string)
function M.attest_verify_async(path, repo, cb)
  local gh = vim.fn.exepath("gh")
  if gh == "" then
    notify_no_gh(repo)
    return cb(true)
  end
  vim.system(
    { gh, "attestation", "verify", path, "--repo", repo },
    { text = true },
    function(res)
      vim.schedule(function()
        cb(
          judge_attestation(
            res.code,
            (res.stdout or "") .. (res.stderr or ""),
            path,
            repo
          )
        )
      end)
    end
  )
end

--- Interpret a finished `gh attestation verify` run (shared by the sync and
--- async paths). Exit 0 verifies; otherwise distinguish "can't verify"
--- (warn + proceed) from "verified WRONG" (abort).
---@param code integer  gh's exit code
---@param out string    gh's combined output
---@return boolean ok, string? err
function judge_attestation(code, out, path, repo)
  if code == 0 then
    return true
  end

  -- Distinguish "can't verify" (warn + proceed) from "verified WRONG" (abort).
  -- `gh` reuses a non-zero exit for both no-attestation-found and a real
  -- mismatch, so key off the message: a 404 / "no attestations found" means the
  -- release predates the attestation rollout; an auth prompt means no token.
  local lower = (out or ""):lower()
  local no_attestation = lower:find("no attestations found", 1, true)
    or lower:find("http 404", 1, true)
  local needs_auth = lower:find("gh auth login", 1, true)
    or lower:find("gh_token", 1, true)

  if no_attestation then
    vim.notify(
      ("nvim-m1: no build-provenance attestation found for %s (%s) — the pinned "):format(
        repo,
        path
      )
        .. "release predates attestation. Proceeding unverified; pin a newer "
        .. "toolchain version to enable verification.",
      vim.log.levels.WARN
    )
    return true
  end

  if needs_auth then
    vim.notify(
      ("nvim-m1: gh is not authenticated — skipping build-provenance verification of %s. "):format(
        repo
      ) .. "Run `gh auth login` (or set GH_TOKEN) to verify downloaded binaries.",
      vim.log.levels.WARN
    )
    return true
  end

  -- Anything else from a present, authenticated gh against an attested release
  -- is a genuine verification FAILURE: refuse to install this binary.
  return false,
    ("build-provenance verification FAILED for %s (%s) — refusing to install a "):format(
      repo,
      path
    )
      .. "binary whose attestation does not validate. Output:\n  "
      .. tostring(out)
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

--- Download one tool's pinned release binary into `bin_dir()` asynchronously
--- (re-signing it ad-hoc on macOS so it will run). The curl download and the
--- `gh attestation verify` round-trip both run off the UI thread; `cb(ok, err?)`
--- is invoked on the main loop (#65). Exposed on `M` so tests can stub the
--- actual download.
---@param tool string
---@param cb fun(ok: boolean, err?: string)
function M.fetch_async(tool, cb)
  local triple, suffix, err = M.platform()
  if not triple then
    return cb(false, err)
  end
  local version, repo = M.versions[tool], M.repos[tool]
  if not (version and repo) then
    return cb(false, "unknown tool: " .. tostring(tool))
  end

  local curl = vim.fn.exepath("curl")
  if curl == "" then
    return cb(false, "curl not found on $PATH (needed to download the M1 toolchain)")
  end

  vim.fn.mkdir(M.bin_dir(), "p")
  local asset = ("%s-%s%s"):format(tool, triple, suffix)
  local url = ("https://github.com/%s/releases/download/%s/%s"):format(
    repo,
    version,
    asset
  )
  local dest = M.bin_dir() .. "/" .. tool .. suffix

  vim.system(
    { curl, "-fSL", "--retry", "2", "-o", dest, url },
    { text = true },
    function(res)
      if res.code ~= 0 then
        return vim.schedule(function()
          cb(
            false,
            ("failed to download %s %s\n  %s\n  %s"):format(
              tool,
              version,
              url,
              res.stderr or ""
            )
          )
        end)
      end
      vim.schedule(function()
        -- Verify build provenance BEFORE making the artifact executable or
        -- running it, so a tampered/substituted asset is rejected at rest (it
        -- never gets +x). (#21)
        M.attest_verify_async(dest, repo, function(vok, verr)
          if not vok then
            os.remove(dest)
            return cb(false, verr)
          end
          if suffix == "" then
            vim.uv.fs_chmod(dest, 493) -- 0755: the verified artifact may now run
          end
          local rok, rerr = resign(dest)
          if not rok then
            return cb(false, rerr)
          end
          cb(true)
        end)
      end)
    end
  )
end

--- Path of the install manifest: a JSON `{ tool = version }` record of what
--- `install()` last put on disk. It lets `stale_tools()` notice when the bundled
--- binaries trail the pinned versions (e.g. after a `Lazy sync` whose build hook
--- ran against an older pin) without shelling out to each binary. (#26)
---@return string
function M.manifest_path()
  return M.bin_dir() .. "/.installed.json"
end

--- The versions recorded in the install manifest (empty table if none / unreadable).
---@return table<string, string>
function M.installed_versions()
  local f = io.open(M.manifest_path(), "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

--- Persist the install manifest.
---@param versions table<string, string>
local function write_manifest(versions)
  vim.fn.mkdir(M.bin_dir(), "p")
  local f = io.open(M.manifest_path(), "w")
  if not f then
    return
  end
  f:write(vim.json.encode(versions))
  f:close()
end

--- Default tools whose on-disk bundled binary does not match the pinned version
--- (or that carry no manifest entry). Tools resolved from `$PATH`/an override, or
--- simply not bundled on disk, are not "stale" — only the bundle is considered.
--- (#26)
---@return string[]
function M.stale_tools()
  local installed = M.installed_versions()
  local stale = {}
  for _, tool in ipairs(M.tools) do
    if
      vim.fn.executable(M.tool_path(tool)) == 1
      and installed[tool] ~= M.versions[tool]
    then
      table.insert(stale, tool)
    end
  end
  return stale
end

--- Install (download) the bundled M1 toolchain without blocking the editor:
--- the tools download sequentially off the UI thread, the manifest records
--- what landed, and `on_done(ok)` fires on the main loop when the last tool
--- finishes. This is the path the first-open self-heal and :M1Install use —
--- the old synchronous download froze the UI for the whole curl + attestation
--- round-trip of every stale tool (#65). Safe to re-run; overwrites with the
--- pinned versions.
---@param tools? string[]  Subset to install (default: all of `M.tools`).
---@param on_done? fun(ok: boolean)
function M.install_async(tools, on_done)
  tools = tools or M.tools
  local triple, _, err = M.platform()
  if not triple then
    vim.notify("nvim-m1: " .. tostring(err), vim.log.levels.ERROR)
    if on_done then
      on_done(false)
    end
    return
  end

  local manifest = M.installed_versions()
  local all_ok = true
  local i = 0
  local function step()
    i = i + 1
    local tool = tools[i]
    if not tool then
      write_manifest(manifest)
      if all_ok then
        vim.notify("nvim-m1: toolchain installed into " .. M.bin_dir())
      end
      if on_done then
        on_done(all_ok)
      end
      return
    end
    vim.notify(("nvim-m1: installing %s %s…"):format(tool, M.versions[tool]))
    M.fetch_async(tool, function(ok, ferr)
      if ok then
        manifest[tool] = M.versions[tool] -- record only what landed on disk
      else
        all_ok = false
        vim.notify("nvim-m1: " .. tostring(ferr), vim.log.levels.ERROR)
      end
      step()
    end)
  end
  step()
end

--- Blocking wrapper over [`M.install_async`] for contexts that must not return
--- until the toolchain is on disk: the lazy.nvim `build` hook and headless
--- scripting. `vim.wait` pumps the event loop, so the async chain progresses
--- while we wait. Interactive code paths (self-heal, :M1Install) use
--- install_async directly instead.
---@param tools? string[]  Subset to install (default: all of `M.tools`).
---@return boolean ok
function M.install(tools)
  local result
  M.install_async(tools, function(ok)
    result = ok
  end)
  vim.wait(10 * 60 * 1000, function()
    return result ~= nil
  end, 50)
  return result == true
end

return M

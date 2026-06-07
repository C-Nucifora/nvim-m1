--- nvim-m1: standalone linting via m1-lint.
---
--- m1-lint emits structured JSON (`--format json`, schema version 2). This
--- module turns that into `vim.diagnostic` items and runs the linter on save.
--- If nvim-lint is installed it is used as the backend; otherwise a built-in
--- `vim.system` runner provides the same behaviour with no extra dependency.
local M = {}

local NS = vim.api.nvim_create_namespace("nvim-m1-lint")
local GROUP = "NvimM1Lint"

--- Map an m1-lint severity string to a vim.diagnostic severity.
---@param sev string
---@return integer
local function severity(sev)
  local map = {
    error = vim.diagnostic.severity.ERROR,
    warning = vim.diagnostic.severity.WARN,
    warn = vim.diagnostic.severity.WARN,
    info = vim.diagnostic.severity.INFO,
    hint = vim.diagnostic.severity.HINT,
  }
  return map[(sev or ""):lower()] or vim.diagnostic.severity.WARN
end

--- Convert one m1-lint diagnostic record to a vim.diagnostic item.
--- m1-lint positions are 0-indexed (line/column), matching vim.diagnostic.
---@param d table
---@return table
local function to_item(d)
  local r = d.range or {}
  local s = r.start or {}
  local e = r["end"] or s
  return {
    lnum = s.line or 0,
    col = s.column or 0,
    end_lnum = e.line or s.line or 0,
    end_col = e.column or s.column or 0,
    severity = severity(d.severity),
    message = d.message or "",
    code = d.code,
    source = "m1-lint",
  }
end

--- Parse m1-lint JSON output into a flat list of vim.diagnostic items.
---
--- Pure function (no editor state) so it can be unit-tested directly. When the
--- report covers several files, `path` selects which file's diagnostics to
--- return; nil takes the first file.
---@param output string  Raw stdout from `m1-lint --format json`.
---@param path? string   Absolute path of the buffer being linted.
---@return table[] items
function M.parse(output, path)
  if not output or output == "" then
    return {}
  end
  local ok, data = pcall(vim.json.decode, output)
  if not ok or type(data) ~= "table" or type(data.files) ~= "table" then
    return {}
  end

  local file
  if path then
    for _, f in ipairs(data.files) do
      if
        f.path == path
        or (
          f.path
          and vim.fn.fnamemodify(f.path, ":p") == vim.fn.fnamemodify(path, ":p")
        )
      then
        file = f
        break
      end
    end
  end
  file = file or data.files[1]
  if not file then
    return {}
  end

  local items = {}
  for _, d in ipairs(file.syntax_errors or {}) do
    table.insert(items, to_item(d))
  end
  for _, d in ipairs(file.diagnostics or {}) do
    table.insert(items, to_item(d))
  end
  return items
end

--- The nvim-lint linter definition for m1-lint (bundled binary when not on $PATH).
function M.linter()
  return {
    cmd = require("nvim-m1.install").resolve("m1-lint") or "m1-lint",
    stdin = false,
    args = { "--format", "json" },
    append_fname = true,
    stream = "stdout",
    ignore_exitcode = true, -- exit 1 means "found lint", not "crashed"
    parser = function(output, bufnr)
      local path = bufnr and vim.api.nvim_buf_get_name(bufnr) or nil
      return M.parse(output, path)
    end,
  }
end

--- Built-in fallback runner (used when nvim-lint is absent): run m1-lint on the
--- buffer's file and publish diagnostics into our namespace.
---@param bufnr integer
function M.run_builtin(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local cmd = require("nvim-m1.install").resolve("m1-lint")
  if path == "" or not cmd then
    return
  end
  vim.system(
    { cmd, "--format", "json", path },
    { text = true },
    vim.schedule_wrap(function(res)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local items =
        M.parse((res.stdout or "") ~= "" and res.stdout or res.stderr or "", path)
      vim.diagnostic.set(NS, bufnr, items)
    end)
  )
end

--- Whether m1-lsp is attached to `bufnr`. The server embeds m1-lint and already
--- publishes those diagnostics, so the standalone linter is only a fallback for
--- when the LSP is unavailable; running both double-publishes every warning.
--- (#25)
---@param bufnr integer
---@return boolean
function M.lsp_attached(bufnr)
  local name = require("nvim-m1.lsp").client_name
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if c.name == name then
      return true
    end
  end
  return false
end

--- Whether m1-lsp will serve lint diagnostics for `cfg` — either it is already
--- attached to `bufnr`, or it is enabled and resolvable so it is about to
--- attach. Evaluated at autocmd-fire time (not snapshotted at setup) so that
--- installing m1-lsp later — e.g. via `:M1Install` — flips the decision without
--- a re-setup, and conversely the standalone hook engages when the LSP is
--- genuinely absent. (#25, deferred-decision fix)
---@param bufnr integer
---@param cfg NvimM1Config
---@return boolean
function M.lsp_will_lint(bufnr, cfg)
  if M.lsp_attached(bufnr) then
    return true
  end
  return cfg.lsp == true and require("nvim-m1.lsp").resolve_cmd(cfg) ~= nil
end

--- Lint a buffer with whichever backend is available.
---@param bufnr? integer
function M.lint(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Defer to m1-lsp when it is attached: it serves the same lint diagnostics, so
  -- running the standalone linter too would publish every warning twice. (#25)
  if M.lsp_attached(bufnr) then
    return
  end
  local ok, nvim_lint = pcall(require, "lint")
  if ok then
    nvim_lint.try_lint(
      "m1_lint",
      { cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h") }
    )
  else
    M.run_builtin(bufnr)
  end
end

--- Register the linter and wire lint-on-save / lint-on-insert-leave.
---@param cfg NvimM1Config
function M.setup(cfg)
  local ok, nvim_lint = pcall(require, "lint")
  if ok then
    nvim_lint.linters = nvim_lint.linters or {}
    nvim_lint.linters.m1_lint =
      vim.tbl_deep_extend("force", M.linter(), nvim_lint.linters.m1_lint or {})
    nvim_lint.linters_by_ft = nvim_lint.linters_by_ft or {}
    if not nvim_lint.linters_by_ft.m1scr then
      nvim_lint.linters_by_ft.m1scr = { "m1_lint" }
    end
  end

  -- Always (re)create the group so disabling clears a previously-wired hook.
  -- Manual linting (:M1Lint) works regardless of the save hook.
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })

  if not cfg.lint_on_save then
    return
  end

  local events = { "BufWritePost", "BufReadPost" }
  if cfg.lint_on_insert_leave then
    table.insert(events, "InsertLeave")
  end

  -- Wire the standalone save/read hook whenever lint-on-save is enabled, but
  -- decide whether to actually run it at FIRE time, not here. m1-lsp already
  -- serves these diagnostics live, so running the standalone linter too would
  -- double-publish — but a setup-time snapshot of "will the LSP lint?" goes
  -- stale: if the user installs m1-lsp/m1-lint later (e.g. `:M1Install`) the
  -- snapshot never updates, so the hook either never registers or never steps
  -- aside. Deferring keeps the BufReadPost-before-async-attach guarantee (the
  -- fire-time check resolves the server even before it attaches) while staying
  -- correct as the toolchain appears/disappears. (#25)
  vim.api.nvim_create_autocmd(events, {
    group = group,
    pattern = "*.m1scr",
    desc = "nvim-m1: lint on save (defers to m1-lsp when it will lint)",
    callback = function(args)
      -- `cfg` is the latest setup()'s config: the augroup is cleared and the
      -- hook re-registered on every setup(), so this closure always sees it.
      if M.lsp_will_lint(args.buf, cfg) then
        return
      end
      M.lint(args.buf)
    end,
  })
end

return M

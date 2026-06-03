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

--- Lint a buffer with whichever backend is available.
---@param bufnr? integer
function M.lint(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
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

  vim.api.nvim_create_autocmd(events, {
    group = group,
    pattern = "*.m1scr",
    desc = "nvim-m1: lint on save",
    callback = function(args)
      M.lint(args.buf)
    end,
  })
end

return M

--- nvim-m1: tree-sitter wiring for the `m1` grammar.
---
--- The grammar, queries (highlights/folds/indents/injections/locals) and the
--- `m1scr` runtime live in tree-sitter-m1, which nvim-m1 depends on.
---
--- Historically this module leaned on nvim-treesitter's `:TSInstall` +
--- `install_info` registration to fetch and compile the parser. The
--- nvim-treesitter `main` rewrite (now its default branch) dropped that runtime
--- registration path, so on a fresh "nvim-m1 + lazy" install the `m1` parser was
--- never built — `:TSInstall m1` printed "skipping unsupported language: m1" and
--- highlighting silently never started.
---
--- This module now provisions tree-sitter using only Neovim core, so it works
--- regardless of which nvim-treesitter branch (or none) is installed:
---   * compiles tree-sitter-m1's `parser.c` (+ `scanner.c`) into a site
---     `parser/m1.so` when missing or its source fingerprint changes, and
---   * registers the queries directly from the grammar's `queries/*.scm` via
---     `vim.treesitter.query.set`, so they apply without depending on the
---     `queries/m1/` runtime layout.
--- nvim-treesitter is still registered opportunistically so `:TSInstall m1`
--- keeps working on the legacy master branch, but it is no longer required.
local M = {}

local QUERY_KINDS =
  { "highlights", "folds", "indents", "injections", "locals", "textobjects" }

--- Locate the tree-sitter-m1 plugin directory on the runtimepath. It ships
--- `src/parser.c`, `src/scanner.c` and `queries/*.scm`.
---@return string? dir
local function grammar_dir()
  for _, p in ipairs(vim.api.nvim_get_runtime_file("src/parser.c", true)) do
    if p:match("tree%-sitter%-m1") then
      return vim.fn.fnamemodify(p, ":h:h") -- strip "/src/parser.c"
    end
  end
  -- Fallback: a runtime dir that carries m1 queries next to a parser source.
  for _, p in ipairs(vim.api.nvim_get_runtime_file("queries/highlights.scm", true)) do
    local dir = vim.fn.fnamemodify(p, ":h:h")
    if dir:match("m1") and vim.fn.filereadable(dir .. "/src/parser.c") == 1 then
      return dir
    end
  end
  return nil
end

--- Whether a compiled `m1` parser is loadable by Neovim.
---
--- `vim.treesitter.language.add` returns `true` on success and `nil` (it does
--- NOT raise, and does NOT return `false`) when the parser is missing, so the
--- result must come from its return value being exactly `true` — not from
--- pcall's success flag. The old `return pcall(...)` form reported the pcall
--- status and so was always true, masking a missing parser.
---@return boolean
function M.parser_installed()
  local ok, loaded = pcall(vim.treesitter.language.add, "m1")
  return ok and loaded == true
end

--- Locate a C compiler on $PATH for building the m1 parser, preferring `cc`,
--- then `gcc`, then `clang`. Returns "" when none is found. Shared so the
--- compile path and `:checkhealth` agree on what counts as "a C compiler".
---@return string  path to the compiler, or "" if none
function M.find_cc()
  for _, name in ipairs({ "cc", "gcc", "clang" }) do
    local p = vim.fn.exepath(name)
    if p ~= "" then
      return p
    end
  end
  return ""
end

--- Hash compiler inputs, including optional scanner and bundled headers. Plugin
--- updates can change these without changing the generated parser's ABI/version.
---@param dir string
---@return string? fingerprint
local function source_fingerprint(dir)
  local src = dir .. "/src"
  local files = { src .. "/parser.c" }
  if vim.fn.filereadable(src .. "/scanner.c") == 1 then
    files[#files + 1] = src .. "/scanner.c"
  end
  vim.list_extend(files, vim.fn.globpath(src, "**/*.h", false, true))
  table.sort(files)
  local inputs = {}
  for _, path in ipairs(files) do
    local file = io.open(path, "rb")
    if not file then
      return nil
    end
    local contents = file:read("*a")
    file:close()
    inputs[#inputs + 1] = path:sub(#src + 2) .. ":" .. vim.fn.sha256(contents)
  end
  return vim.fn.sha256(table.concat(inputs, "\n"))
end

local function parser_paths()
  local out = vim.fn.stdpath("data") .. "/site/parser/m1.so"
  return out, out .. ".sha256"
end

local function recorded_fingerprint(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local fingerprint = file:read("*l")
  file:close()
  return fingerprint
end

--- Compile tree-sitter-m1's parser into a site `parser/m1.so` and load it.
---@param dir string  tree-sitter-m1 plugin dir
---@param fingerprint string
---@return boolean ok, string? err
local function compile_parser(dir, fingerprint)
  local cc = M.find_cc()
  if cc == "" then
    return false, "no C compiler (cc/gcc/clang) on $PATH to build the m1 parser"
  end

  local out, stamp = parser_paths()
  vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")

  -- Never truncate a library that Neovim may already have mapped. A sibling
  -- temporary file also preserves the working parser when compilation fails.
  local temporary = out .. "." .. vim.fn.fnamemodify(vim.fn.tempname(), ":t")
  local src = dir .. "/src"
  local cmd =
    { cc, "-o", temporary, "-shared", "-Os", "-fPIC", "-I", src, src .. "/parser.c" }
  if vim.fn.filereadable(src .. "/scanner.c") == 1 then
    table.insert(cmd, src .. "/scanner.c")
  end

  local res = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    vim.fn.delete(temporary)
    return false, "compiling the m1 parser failed: " .. res
  end
  -- language.add() returns true immediately for a language already loaded in
  -- this session, even if the replacement has missing symbols or an invalid ABI.
  -- Validate in a configless child before replacing the working binary.
  local validate = string.format(
    "local ok, loaded = pcall(vim.treesitter.language.add, 'm1', { path = %q }); "
      .. "if not ok or loaded ~= true then "
      .. "io.stderr:write(tostring(loaded or 'parser could not be loaded')); "
      .. "vim.cmd('cquit 1') end; vim.cmd('qa!')",
    temporary
  )
  local validation = vim.fn.system({
    vim.v.progpath,
    "--clean",
    "--headless",
    "--noplugin",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-c",
    "lua " .. validate,
  })
  if vim.v.shell_error ~= 0 then
    vim.fn.delete(temporary)
    return false, "validating the rebuilt m1 parser failed: " .. validation
  end
  local renamed, rename_err = (vim.uv or vim.loop).fs_rename(temporary, out)
  if not renamed then
    vim.fn.delete(temporary)
    return false, "installing the rebuilt m1 parser failed: " .. tostring(rename_err)
  end

  -- Load the freshly-built parser explicitly (the negative result of an earlier
  -- language.add in this session may otherwise be cached).
  local ok, loaded = pcall(vim.treesitter.language.add, "m1", { path = out })
  if ok and loaded == true then
    -- Record success only after compilation and loading. Missing/old stamps
    -- deliberately trigger one rebuild when migrating an existing install.
    local wrote, write_result = pcall(vim.fn.writefile, { fingerprint }, stamp)
    if not wrote or write_result ~= 0 then
      return false,
        "recording the m1 parser fingerprint failed: " .. tostring(write_result)
    end
    return true
  end
  return false, "built the m1 parser but it failed to load: " .. tostring(loaded)
end

--- Register the queries from the grammar's `queries/*.scm` so highlighting,
--- folding and indenting work without relying on the `queries/m1/` runtime
--- layout (tree-sitter-m1 ships them flat) or on nvim-treesitter.
---@param dir string
local function register_queries(dir)
  for _, kind in ipairs(QUERY_KINDS) do
    local fh = io.open(dir .. "/queries/" .. kind .. ".scm", "r")
    if fh then
      local text = fh:read("*a")
      fh:close()
      pcall(vim.treesitter.query.set, "m1", kind, text)
    end
  end
end

--- Best-effort: register `m1` with nvim-treesitter's legacy installer so
--- `:TSInstall m1` keeps working on the master branch. Harmless no-op on the
--- main-branch rewrite, which ignores runtime `install_info`.
---@param dir? string
local function register_with_nvim_treesitter(dir)
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok then
    return
  end
  local configs = type(parsers.get_parser_configs) == "function"
      and parsers.get_parser_configs()
    or parsers
  if type(configs) == "table" and not configs.m1 then
    configs.m1 = {
      install_info = {
        url = dir or "https://github.com/C-Nucifora/tree-sitter-m1",
        files = { "src/parser.c", "src/scanner.c" },
        branch = "main",
      },
      filetype = "m1scr",
    }
  end
end

--- Provision the `m1` tree-sitter parser + queries. Idempotent and safe to call
--- before/without a C compiler (it degrades to "no highlighting" rather than
--- erroring out of setup(); `:checkhealth nvim-m1` explains why).
---@param cfg NvimM1Config
---@return boolean ok  true if the parser is loadable afterwards
function M.register(cfg)
  -- Map the language to the filetype regardless of everything else, so a parser
  -- already on the runtimepath lights up m1scr buffers.
  pcall(vim.treesitter.language.register, "m1", "m1scr")

  local dir = grammar_dir()
  register_with_nvim_treesitter(dir)
  local fingerprint = dir and source_fingerprint(dir) or nil
  local out, stamp = parser_paths()
  local stale = fingerprint
    and (vim.fn.filereadable(out) ~= 1 or recorded_fingerprint(stamp) ~= fingerprint)

  -- Check freshness before parser_installed() loads the old library. Neovim
  -- keeps a loaded language for the session; an update during a live session
  -- replaces the on-disk parser safely and takes effect on the next launch.
  if cfg.auto_install_parser and fingerprint then
    local loaded = false
    if not stale then
      -- Prefer the parser whose fingerprint we checked over an older legacy
      -- installer output that happens to appear earlier on the runtimepath.
      local ok, result = pcall(vim.treesitter.language.add, "m1", { path = out })
      loaded = ok and result == true
    end
    if stale or not loaded then
      local built, err = compile_parser(dir, fingerprint)
      if not built then
        vim.schedule(function()
          vim.notify(
            "nvim-m1: "
              .. (err or "could not build the m1 parser")
              .. " (see :checkhealth nvim-m1)",
            vim.log.levels.WARN
          )
        end)
      end
    end
  end

  if dir then
    register_queries(dir)
  end
  -- Without sources or auto-install, retain any externally managed parser.
  -- A failed rebuild can also keep the previous working parser available.
  return M.parser_installed()
end

--- Start tree-sitter highlighting on a buffer (no-op if the parser is missing).
---@param bufnr integer
function M.start(bufnr)
  pcall(vim.treesitter.start, bufnr, "m1")
end

return M

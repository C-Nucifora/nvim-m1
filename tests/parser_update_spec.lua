--- Integration coverage for updating a parser that already exists on disk.
local ts = require("nvim-m1.treesitter")
local cfg = require("nvim-m1.config").defaults
local uv = vim.uv or vim.loop
local original_grammar
for _, path in ipairs(vim.api.nvim_get_runtime_file("src/parser.c", true)) do
  if path:match("tree%-sitter%-m1") then
    original_grammar = vim.fn.fnamemodify(path, ":h:h")
    break
  end
end
if not original_grammar or ts.find_cc() == "" then
  describe("nvim-m1 parser updates (integration)", function()
    pending("requires tree-sitter-m1 sources and a C compiler")
  end)
  return
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local contents = file:read("*a")
  file:close()
  return contents
end

local function append(path, text)
  local file = assert(io.open(path, "a"))
  file:write(text)
  file:close()
end

describe("nvim-m1 parser updates (integration)", function()
  local fixture, saved_rtp, saved_system, saved_notify, builds
  local out = vim.fn.stdpath("data") .. "/site/parser/m1.so"
  local stamp = out .. ".sha256"

  before_each(function()
    saved_rtp = vim.o.runtimepath
    saved_system, saved_notify = vim.fn.system, vim.notify
    fixture = vim.fn.tempname() .. "/tree-sitter-m1"
    -- Copy compiler inputs; never modify the actual grammar checkout.
    for _, path in ipairs(vim.fn.globpath(original_grammar, "src/**/*", false, true)) do
      if vim.fn.filereadable(path) == 1 then
        local dest = fixture .. path:sub(#original_grammar + 1)
        vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")
        assert(uv.fs_copyfile(path, dest))
      end
    end
    append(
      fixture .. "/src/parser.c",
      "\n/* isolated update fixture " .. fixture .. " */\n"
    )
    vim.opt.runtimepath:prepend(fixture)
    builds = 0
    vim.fn.system = function(cmd, ...)
      if type(cmd) == "table" and cmd[1] == ts.find_cc() then
        builds = builds + 1
      end
      return saved_system(cmd, ...)
    end
    vim.notify = function() end
    assert.is_true(ts.register(cfg))
    assert.equals(1, builds, "the isolated source revision must compile")
    builds = 0
  end)

  after_each(function()
    vim.fn.system, vim.notify = saved_system, saved_notify
    vim.o.runtimepath = saved_rtp
    if fixture then
      vim.fn.delete(vim.fn.fnamemodify(fixture, ":h"), "rf")
    end
  end)

  it("rebuilds changed scanner and header inputs, then stays idempotent", function()
    local previous = read(stamp)
    assert.is_true(ts.register(cfg))
    assert.equals(0, builds, "unchanged sources must not recompile")

    append(fixture .. "/src/scanner.c", "\n/* scanner update */\n")
    assert.is_true(ts.register(cfg))
    assert.equals(1, builds)
    assert.is_not.equals(previous, read(stamp))
    previous = read(stamp)

    append(fixture .. "/src/tree_sitter/parser.h", "\n/* header update */\n")
    assert.is_true(ts.register(cfg))
    assert.equals(2, builds)
    assert.is_not.equals(previous, read(stamp))
    assert.is_true(ts.register(cfg))
    assert.equals(2, builds, "successful update must not compile again")
  end)

  it("refreshes a pre-existing parser without a fingerprint", function()
    assert.equals(0, vim.fn.delete(stamp))
    assert.is_true(ts.register(cfg))
    assert.equals(1, builds)
    assert.equals(1, vim.fn.filereadable(stamp))
  end)

  it(
    "keeps the working binary and fingerprint when new sources do not compile",
    function()
      local old_binary, old_stamp = read(out), read(stamp)
      append(fixture .. "/src/parser.c", "\nthis is not valid C;\n")
      assert.is_true(ts.register(cfg), "failed update must retain the working parser")
      assert.equals(1, builds)
      assert.is_true(
        old_binary == read(out),
        "failed compilation must preserve the working binary"
      )
      assert.equals(old_stamp, read(stamp), "failed update must not record success")
    end
  )

  it(
    "keeps the working parser when compiled sources export the wrong symbol",
    function()
      local old_binary, old_stamp = read(out), read(stamp)
      local parser_source = fixture .. "/src/parser.c"
      local source, renamed = read(parser_source):gsub(
        "tree_sitter_m1%(void%)",
        "tree_sitter_missing_m1(void)"
      )
      assert.equals(1, renamed, "the fixture must change the parser's exported symbol")
      local file = assert(io.open(parser_source, "w"))
      file:write(source)
      file:close()

      local compile_succeeded = false
      local system = vim.fn.system
      vim.fn.system = function(cmd, ...)
        local result = system(cmd, ...)
        if type(cmd) == "table" and cmd[1] == ts.find_cc() then
          compile_succeeded = vim.v.shell_error == 0
        end
        return result
      end
      assert.is_true(
        ts.register(cfg),
        "failed validation must retain the loaded parser"
      )
      assert.is_true(compile_succeeded, "this regression must pass the real C compiler")
      assert.equals(1, builds)
      assert.is_true(
        old_binary == read(out),
        "invalid replacement must not replace the working binary"
      )
      assert.equals(
        old_stamp,
        read(stamp),
        "invalid replacement must not record success"
      )
    end
  )

  it("respects auto_install_parser=false when sources change", function()
    local old_stamp = read(stamp)
    append(fixture .. "/src/parser.c", "\n/* user-managed update */\n")
    assert.is_true(
      ts.register(require("nvim-m1.config").resolve({ auto_install_parser = false }))
    )
    assert.equals(0, builds)
    assert.equals(old_stamp, read(stamp))
  end)

  it(
    "keeps an installed parser without compiling when sources are unavailable",
    function()
      vim.o.runtimepath = saved_rtp
      -- Remove every runtime directory with the grammar's compiler sources.
      for _, path in ipairs(vim.api.nvim_get_runtime_file("src/parser.c", true)) do
        if path:match("tree%-sitter%-m1") then
          vim.opt.runtimepath:remove(vim.fn.fnamemodify(path, ":h:h"))
        end
      end
      assert.is_true(ts.register(cfg))
      assert.is_true(ts.register(cfg))
      assert.equals(0, builds, "absent sources must not cause rebuild attempts")
    end
  )
end)

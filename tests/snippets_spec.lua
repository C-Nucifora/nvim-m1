local snippets = require("nvim-m1.snippets")

describe("nvim-m1.snippets", function()
  it("ships a VS Code-format snippet file that exists and decodes", function()
    local path = snippets.path()
    assert.is_string(path)
    assert.equals(1, vim.fn.filereadable(path), path .. " should be readable")
    local data = snippets.load()
    assert.is_table(data)
    assert.is_true(next(data) ~= nil, "the snippet table should not be empty")
  end)

  it("only ships constructs the m1-lsp completion does NOT emit", function()
    -- m1-lsp emits InsertTextFormat::SNIPPET for the construct *heads*
    -- (if / when / expand / local / static — see m1-lsp construct_snippet),
    -- so bundling those again would duplicate the server. The bundled file is
    -- deliberately the complement: only the idioms with no Neovim path.
    local data = snippets.load()
    local prefixes = {}
    for _, snip in pairs(data) do
      assert.is_string(snip.prefix, "every snippet needs a string prefix")
      assert.is_table(snip.body, "every snippet needs a body array")
      prefixes[snip.prefix] = true
    end

    -- The five idioms with no LSP/Neovim path (the gap this fills).
    for _, want in ipairs({ "is", "ifelse", "nanguard", "m1finite", "m1allow" }) do
      assert.is_true(prefixes[want], "expected a `" .. want .. "` snippet")
    end

    -- Must NOT re-ship the construct heads the LSP already completes, or the
    -- user gets the same skeleton twice.
    for _, banned in ipairs({ "when", "expand", "local", "staticlocal" }) do
      assert.is_nil(
        prefixes[banned],
        "`" .. banned .. "` is emitted by m1-lsp; do not bundle it"
      )
    end
  end)

  it("uses the documented @m1: annotation spellings in its bodies", function()
    local data = snippets.load()
    local function body_of(prefix)
      for _, snip in pairs(data) do
        if snip.prefix == prefix then
          return table.concat(snip.body, "\n")
        end
      end
      return nil
    end

    -- The annotation framework keywords must match the toolchain exactly.
    assert.is_truthy(body_of("m1finite"):find("@m1:requires%-finite"))
    assert.is_truthy(body_of("m1allow"):find("@m1:allow%("))
    -- The NaN guard uses the ECU-legal idiom the invalid-value tracer matches.
    assert.is_truthy(body_of("nanguard"):find("Calculate%.IsNAN%("))
  end)

  it("looks a snippet up by prefix or display name", function()
    assert.is_table(snippets.get("nanguard")) -- by prefix
    assert.is_table(snippets.get("NaN guard")) -- by display name
    assert.is_nil(snippets.get("nope-not-a-snippet"))
  end)

  it("expands a bundled snippet through native vim.snippet (no engine)", function()
    if not (vim.snippet and vim.snippet.expand) then
      pending("Neovim without vim.snippet")
      return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    assert.is_true(snippets.expand("m1finite"))
    -- The static `// @m1:requires-finite` text should land in the buffer.
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("@m1:requires%-finite"))
    vim.snippet.stop()
    assert.is_false(snippets.expand("nope"), "unknown snippet expands to nothing")
  end)
end)

-- The M1 language uses `//` line comments and `/* */` block comments (per the
-- tree-sitter-m1 grammar). Neovim's built-in commenting (`gc`/`gcc`) and any
-- `<leader>/` mapping read the buffer-local `commentstring`, so an m1scr buffer
-- must carry it for commenting to work. This lives in `ftplugin/m1scr.lua`,
-- mirroring how m1-vscode declares comments in `language-configuration.json`.

describe("nvim-m1 m1scr ftplugin", function()
  local counter = 0
  local function open_m1scr_buffer()
    -- The runner starts with `--noplugin`, so enable filetype plugins (which
    -- source `ftplugin/m1scr.lua`) as a real user config does.
    vim.cmd("filetype plugin on")
    counter = counter + 1
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, ("Vehicle.Foo%d.Update.m1scr"):format(counter))
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "m1scr"
    return buf
  end

  it("sets commentstring to the M1 line-comment form", function()
    local buf = open_m1scr_buffer()
    assert.equals("// %s", vim.bo[buf].commentstring)
  end)

  it("declares the block-comment form in 'comments'", function()
    local buf = open_m1scr_buffer()
    assert.is_truthy(vim.bo[buf].comments:find("/%*", 1, false), vim.bo[buf].comments)
  end)
end)

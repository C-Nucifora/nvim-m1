-- Filetype options for M1 script (`.m1scr`).
--
-- The M1 language uses `//` line comments and `/* */` block comments (per the
-- tree-sitter-m1 grammar). Set `commentstring`/`comments` so Neovim's built-in
-- commenting (`gc`/`gcc`) and any `<leader>/`-style mapping toggle comments
-- correctly. This is the Neovim counterpart of the comment block in m1-vscode's
-- `language-configuration.json`.

vim.bo.commentstring = "// %s"
vim.bo.comments = "s1:/*,mb:*,ex:*/,://"

-- Register the M1 filetypes as early as possible so that `ft = "m1scr"` lazy
-- triggers fire and files opened at startup get the right filetype.
--   .m1scr -> the M1 script language
--   .m1prj -> the (XML) project file, a distinct filetype so m1-lsp can attach
--             to it for rename-from-declaration without grabbing every XML file.
vim.filetype.add({ extension = { m1scr = "m1scr", m1prj = "m1prj" } })

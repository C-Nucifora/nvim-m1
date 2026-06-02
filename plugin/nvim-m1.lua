-- nvim-m1 plugin shim. Loaded once on startup.
--
-- Registers the m1scr/m1prj filetypes (so the filetypes exist even before
-- require("nvim-m1").setup() runs) and exposes :checkhealth nvim-m1. All real
-- wiring happens in setup().
if vim.g.loaded_nvim_m1 then
  return
end
vim.g.loaded_nvim_m1 = true

require("nvim-m1").register_filetypes()

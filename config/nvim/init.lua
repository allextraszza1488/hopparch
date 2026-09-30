-- hopparch nvim: base options only. The real config gets designed later.
vim.g.mapleader = " "

vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.termguicolors = true

-- Tab = 4 spaces
vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.softtabstop = 4

-- undo history survives closing the file, 10000 steps per file
vim.opt.undofile = true
vim.opt.undolevels = 10000

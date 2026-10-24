-- hopparch nvim. No plugins: what nvim 0.12 has built in, plus language
-- servers and grammars when they are installed (the full profile installs
-- them; without them this is the plain editor). <leader> = Space.
vim.g.mapleader = " "

vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.termguicolors = true
-- colors/0xyc.lua ships next to this file; say so instead of failing silently
if not pcall(vim.cmd.colorscheme, "0xyc") then
  vim.notify("nvim: the 0xyc colorscheme is missing, run ./setup.sh", vim.log.levels.WARN)
end

-- Tab = 4 spaces (Lua: 2, below)
vim.opt.expandtab = true
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.softtabstop = 4
vim.api.nvim_create_autocmd("FileType", {
  pattern = "lua",
  callback = function() vim.opt_local.shiftwidth = 2; vim.opt_local.softtabstop = 2; vim.opt_local.tabstop = 2 end,
})

-- tabs, trailing spaces and odd spaces are visible
vim.opt.list = true
vim.opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }

-- undo history survives closing the file, 10000 steps per file
vim.opt.undofile = true
vim.opt.undolevels = 10000
-- a copy of the file before each save, and swap files (crash recovery); no
-- autosave. Backups live in nvim's state dir, not next to your files.
local backups = vim.fn.stdpath("state") .. "/backup//"
vim.fn.mkdir(backups, "p")
vim.opt.backup = true
vim.opt.backupdir = backups
vim.opt.swapfile = true

-- Syntax trees. nvim brings its own grammars for C, Lua, Markdown, query, vim
-- and vimdoc. Arch's tree-sitter-* packages instead install a plain shared
-- library in /usr/lib, which is not on nvim's runtimepath, so nvim never finds
-- them: point it at the file. nvim also calls shell scripts "sh" while the
-- grammar is called "bash", so the filetype has to be mapped to it as well.
-- C++, Arduino and JSON have no grammar in the Arch repos; they keep nvim's
-- own regex highlighting, which for a .ino file is the C++ one.
for lang, filetypes in pairs({ bash = { "sh", "bash" }, python = { "python" } }) do
  local so = "/usr/lib/libtree-sitter-" .. lang .. ".so"
  if vim.uv.fs_stat(so) and pcall(vim.treesitter.language.add, lang, { path = so }) then
    vim.treesitter.language.register(lang, filetypes)
  end
end
-- a grammar for this filetype or nothing: the regex highlighting stays
vim.api.nvim_create_autocmd("FileType", {
  callback = function(ev) pcall(vim.treesitter.start, ev.buf) end,
})

-- the terminal (Space r / Space g) gives keys back to nvim with Esc
vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], { desc = "Terminal: back to normal mode" })

-- brackets and quotes close themselves; typing the closing one steps over it
local closers = { ["("] = ")", ["["] = "]", ["{"] = "}", ['"'] = '"', ["'"] = "'" }
for open, close in pairs(closers) do
  vim.keymap.set("i", open, function()
    local line, col = vim.api.nvim_get_current_line(), vim.fn.col(".")
    if open == close and line:sub(col, col) == close then return "<Right>" end
    -- a quote right after a letter is an apostrophe (don't, it's)
    if open == "'" and line:sub(col - 1, col - 1):match("%w") then return "'" end
    return open .. close .. "<Left>"
  end, { expr = true })
  if open ~= close then
    vim.keymap.set("i", close, function()
      local line, col = vim.api.nvim_get_current_line(), vim.fn.col(".")
      return line:sub(col, col) == close and "<Right>" or close
    end, { expr = true })
  end
end

-- file tree on the left (netrw), Space e shows/hides it
vim.g.netrw_banner = 0
vim.g.netrw_liststyle = 3
vim.g.netrw_winsize = 25
vim.keymap.set("n", "<leader>e", "<cmd>Lexplore<cr>", { desc = "File tree" })

-- run / debug by file type in a split at the bottom (lua/hopparch/run.lua)
local run = require("hopparch.run")
vim.keymap.set("n", "<leader>r", run.run, { desc = "Run file (C, C++, Lua, Python, sh; Arduino: build + upload)" })
vim.keymap.set("n", "<leader>g", run.debug, { desc = "Debug (C/C++: gdb; Arduino: serial monitor)" })


-- Language servers: each one only when its program is installed.
local lua_library = { vim.env.VIMRUNTIME }
-- Hyprland's own Lua stubs, so hl.* in ~/.config/hypr is understood. Hyprland
-- 0.56 installs them here (CMakeLists.txt: DATAROOTDIR/hypr/stubs).
if vim.uv.fs_stat("/usr/share/hypr/stubs") then table.insert(lua_library, "/usr/share/hypr/stubs") end

vim.lsp.config("clangd", {
  cmd = { "clangd" },
  filetypes = { "c", "cpp" },
  root_markers = { "compile_commands.json", "Makefile", ".git" },
})
vim.lsp.config("lua_ls", {
  cmd = { "lua-language-server" },
  filetypes = { "lua" },
  root_markers = { ".luarc.json", ".git" },
  settings = { Lua = {
    runtime = { version = "LuaJIT" },
    workspace = { library = lua_library, checkThirdParty = false },
    -- Hyprland's hl table, in case the stubs above are not installed
    diagnostics = { globals = { "hl" } },
    telemetry = { enable = false },
  } },
})
for _, name in ipairs({ "clangd", "lua_ls" }) do
  if vim.fn.executable(vim.lsp.config[name].cmd[1]) == 1 then vim.lsp.enable(name) end
end

-- The Arduino server wants the board on its command line, and the board comes
-- from the sketch being opened, so it is started per file rather than declared
-- once. It also needs arduino-cli's own config file (`arduino-cli config init`).
local arduino_cli_config = vim.fn.expand("~/.arduino15/arduino-cli.yaml")
vim.api.nvim_create_autocmd("FileType", {
  pattern = "arduino",
  callback = function(ev)
    if vim.fn.executable("arduino-language-server") == 0 then return end
    if not vim.uv.fs_stat(arduino_cli_config) then return end
    vim.lsp.start({
      name = "arduino_ls",
      cmd = { "arduino-language-server", "-clangd", "clangd", "-cli", "arduino-cli",
              "-cli-config", arduino_cli_config, "-fqbn", run.fqbn(ev.buf) },
      root_dir = vim.fs.root(ev.buf, { "sketch.yaml", ".git" })
                 or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ":h"),
    }, { bufnr = ev.buf })
  end,
})

-- with a server attached: completion pops up while typing (Tab/Shift+Tab move,
-- Enter takes it), gd = definition; K, grn, gra, grr are nvim's own
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    if client and client:supports_method("textDocument/completion") then
      vim.lsp.completion.enable(true, client.id, ev.buf, { autotrigger = true })
    end
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = ev.buf, desc = "Go to definition" })
  end,
})
vim.opt.completeopt = { "menuone", "noselect", "popup" }
vim.keymap.set("i", "<Tab>", function() return vim.fn.pumvisible() == 1 and "<C-n>" or "<Tab>" end,
  { expr = true, desc = "Completion: next" })
vim.keymap.set("i", "<S-Tab>", function() return vim.fn.pumvisible() == 1 and "<C-p>" or "<S-Tab>" end,
  { expr = true, desc = "Completion: previous" })
vim.keymap.set("i", "<CR>", function() return vim.fn.pumvisible() == 1 and "<C-y>" or "<CR>" end,
  { expr = true, desc = "Completion: take it" })

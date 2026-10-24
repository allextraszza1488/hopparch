-- Space r / Space g: run or debug the current file, in a terminal split at
-- the bottom. Esc in there gives the keys back; close it like any window.
local M = {}

-- builds go to nvim's cache, not next to your sources
local out_dir = vim.fn.stdpath("cache") .. "/run"

local function dir_of(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  return name ~= "" and vim.fn.fnamemodify(name, ":h") or vim.fn.getcwd()
end

-- one `key: value` out of a sketch.yaml, ignoring commented-out lines
local function sketch_value(key, dir)
  local f = io.open(dir .. "/sketch.yaml")
  if not f then return nil end
  local value
  for line in f:lines() do
    if not line:match("^%s*#") then
      value = value or line:match("^%s*" .. key .. ":%s*([^%s#]+)")
    end
  end
  f:close()
  return value
end

local function plugged_board()
  if vim.fn.executable("arduino-cli") == 0 then return nil end
  local res = vim.system({ "arduino-cli", "board", "list", "--format", "json" }, { text = true }):wait(10000)
  local ok, data = pcall(vim.json.decode, res.stdout or "")
  if not ok or type(data) ~= "table" then return nil end
  for _, entry in ipairs(data.detected_ports or data) do
    local boards = entry.matching_boards
    if boards and boards[1] then return boards[1].fqbn, entry.port and entry.port.address end
  end
end

-- Arduino board: sketch.yaml's default_fqbn/default_port if the sketch has
-- one, else the first board arduino-cli sees plugged in.
-- Also used by the Arduino language server (init.lua), which needs an fqbn
-- on its command line before the sketch is even parsed.
function M.fqbn(buf)
  return sketch_value("default_fqbn", dir_of(buf)) or "arduino:avr:uno"
end

local function board(dir)
  local fqbn, port = sketch_value("default_fqbn", dir), sketch_value("default_port", dir)
  if not (fqbn and port) then
    local f, p = plugged_board()
    fqbn, port = fqbn or f, port or p
  end
  return fqbn, port
end

-- the shell command for this file, or nil + why not
function M.command(kind, ft, file)
  -- Only C/C++ (gdb) and Arduino (serial monitor) have a Space g. Without
  -- this, Space g on a Lua or Python file would quietly just run it.
  if kind == "debug" and not (ft == "c" or ft == "cpp" or ft == "arduino") then
    return nil, "Space g: nothing to debug for file type '" .. ft .. "' (C/C++ gdb, Arduino serial monitor)"
  end
  local q = vim.fn.shellescape
  local bin = out_dir .. "/" .. vim.fn.fnamemodify(file, ":t:r")
  local dir = vim.fn.fnamemodify(file, ":h")
  local has_make = vim.uv.fs_stat(dir .. "/Makefile") ~= nil
  if ft == "c" or ft == "cpp" then
    local cc = ft == "c" and "gcc" or "g++"
    -- a Makefile next to the file wins over building the one file
    local build = has_make and ("make -C " .. q(dir))
                   or (cc .. " -Wall -g -o " .. q(bin) .. " " .. q(file))
    if kind == "debug" then
      if has_make then return nil, "Space g on a Makefile project: run gdb on its program yourself" end
      if vim.fn.executable("gdb") == 0 then return nil, "gdb is not installed (it comes with the full profile)" end
      return build, bin
    end
    return build .. (has_make and "" or (" && " .. q(bin)))
  elseif ft == "lua" then
    -- luajit always exists (nvim needs it); plain lua only if it was installed
    return (vim.fn.executable("lua") == 1 and "lua " or "luajit ") .. q(file)
  elseif ft == "python" then
    return "python3 " .. q(file)
  elseif ft == "sh" or ft == "bash" then
    return "bash " .. q(file)
  elseif ft == "arduino" then
    local fqbn, port = board(dir)
    if not fqbn or not port then return nil, "no Arduino board found: plug it in, or add sketch.yaml (default_fqbn, default_port)" end
    if kind == "debug" then
      return "arduino-cli monitor -p " .. q(port) .. " -b " .. q(fqbn)
    end
    return "arduino-cli compile --upload -b " .. q(fqbn) .. " -p " .. q(port) .. " " .. q(dir)
  end
  return nil, "Space " .. (kind == "debug" and "g" or "r") .. ": nothing set up for file type '" .. ft .. "'"
end

-- about a third of the window, so it fits a small laptop screen and a big one
local function terminal(cmd)
  vim.cmd("botright " .. math.max(8, math.floor(vim.o.lines / 3)) .. "split")
  vim.cmd.terminal(cmd)
  vim.cmd.startinsert()
end

function M.run()
  vim.cmd("silent! write")
  vim.fn.mkdir(out_dir, "p")
  local cmd, why = M.command("run", vim.bo.filetype, vim.fn.expand("%:p"))
  if not cmd then return vim.notify(why, vim.log.levels.WARN) end
  terminal(cmd)
end

function M.debug()
  vim.cmd("silent! write")
  vim.fn.mkdir(out_dir, "p")
  local ft = vim.bo.filetype
  local cmd, extra = M.command("debug", ft, vim.fn.expand("%:p"))
  if not cmd then return vim.notify(extra, vim.log.levels.WARN) end
  if ft == "c" or ft == "cpp" then
    -- build with debug info, then nvim's own gdb front end (:Termdebug)
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then return vim.notify(out, vim.log.levels.ERROR) end
    vim.cmd("packadd termdebug")
    vim.cmd("Termdebug " .. vim.fn.fnameescape(extra))
  else
    terminal(cmd)
  end
end

return M

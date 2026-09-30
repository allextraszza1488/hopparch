-- hopparch -- Hyprland config (Lua, Hyprland >= 0.55). Reload: SUPER+SHIFT+R
-- Step 1: basics only. Every bind here is from the approved table in DESIGN.md.

local mod      = "SUPER"
-- -1 = one kitty process for all windows: ~15 MB per extra window instead of ~160
local terminal = "kitty -1"
local launcher = "fuzzel"
local browser  = "firefox"
local files    = "thunar"
local scripts  = os.getenv("HOME") .. "/.config/scripts"


hl.on("hyprland.start", function()
  hl.exec_cmd("waybar")
end)


-- any monitor: highest refresh rate, automatic scale
hl.monitor({ output = "", mode = "highrr", position = "auto", scale = "auto" })


-- plain look: nothing that costs GPU time
hl.config({
  general = {
    gaps_in = 4,
    gaps_out = 8,
    border_size = 2,
    layout = "dwindle",
    col = {
      -- 0xyc: cream = focused, dark grey = the rest
      active_border   = "rgba(e8e4dcff)",
      inactive_border = "rgba(3a3a38ff)",
    },
  },
  decoration = {
    rounding = 0,
    blur   = { enabled = false },
    shadow = { enabled = false },
  },
  animations = { enabled = false },
  input = {
    kb_layout = "us",
    -- numpad types numbers at login; NumLock off turns it into the mouse
    numlock_by_default = true,
    -- focus follows clicks and keys only, never the mouse passing by
    follow_mouse = 0,
  },
  misc = {
    disable_hyprland_logo = true,
    force_default_wallpaper = 0,
    background_color = "rgba(000000ff)",
  },
})


-- apps
hl.bind(mod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mod .. " + D",      hl.dsp.exec_cmd(launcher))
hl.bind(mod .. " + B",      hl.dsp.exec_cmd(browser))
hl.bind(mod .. " + F",      hl.dsp.exec_cmd(files))
hl.bind("CTRL + ALT + Delete", hl.dsp.exec_cmd(terminal .. " --class btop -e btop"))
hl.bind(mod .. " + Q",      hl.dsp.window.close())
hl.bind(mod .. " + SHIFT + R", hl.dsp.exec_cmd("hyprctl reload"))
-- power menu from the keyboard (the bar's power icon opens the same one)
hl.bind(mod .. " + SHIFT + E", hl.dsp.exec_cmd(scripts .. "/power-menu.sh"))

-- apps asking to maximize themselves (firefox does) are ignored; otherwise
-- every window opened after them inherits "maximized" and covers the rest
hl.window_rule({
  name  = "no-self-maximize",
  match = { class = ".*" },
  suppress_event = "maximize",
})

-- btop floats above everything, on every workspace
hl.window_rule({
  name  = "btop",
  match = { class = "^(btop)$" },
  float = true,
  pin   = true,
  size  = { "monitor_w*0.6", "monitor_h*0.7" },
})


-- windows: hjkl = focus, +SHIFT = move, +CTRL = resize (hold)
local step = 40
for _, d in ipairs({
  { "H", "left",  -step, 0 },
  { "J", "down",  0,  step },
  { "K", "up",    0, -step },
  { "L", "right", step,  0 },
}) do
  local key, dir, rx, ry = d[1], d[2], d[3], d[4]
  hl.bind(mod .. " + " .. key,           hl.dsp.focus({ direction = dir }))
  hl.bind(mod .. " + SHIFT + " .. key,   hl.dsp.window.move({ direction = dir }))
  hl.bind(mod .. " + CTRL + " .. key,
          hl.dsp.window.resize({ x = rx, y = ry, relative = true }),
          { repeating = true })
end

-- mouse: SUPER + left drag moves, SUPER + right drag resizes
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })


-- workspaces 1-9: go there, +SHIFT sends the window there
for i = 1, 9 do
  hl.bind(mod .. " + " .. i,         hl.dsp.focus({ workspace = i }))
  hl.bind(mod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end


-- mouse from the keyboard. ydotool talks to ydotoold, a system service set up
-- by setup.sh. Both sets below are always on; they don't clash with anything.
hl.env("YDOTOOL_SOCKET", "/run/ydotoold/socket")
local mstep = 20  -- pixels per step; holding a key keeps moving
local held  = { repeating = true }
local function yd(args) return hl.dsp.exec_cmd("ydotool " .. args) end
local function move(dx, dy) return yd(("mousemove -x %d -y %d"):format(dx, dy)) end

-- numpad with NumLock OFF (numpad keys then have their own names, separate
-- from the real arrows):
--   7 scroll up    8 middle click   9 scroll down
--   4 left click   5 up             6 right click
--   1 left         2 down           3 right
hl.bind("KP_Begin", move(0, -mstep), held)
hl.bind("KP_Down",  move(0,  mstep), held)
hl.bind("KP_End",   move(-mstep, 0), held)
hl.bind("KP_Next",  move( mstep, 0), held)
hl.bind("KP_Home",  yd("mousemove --wheel -x 0 -y 1"),  held)
hl.bind("KP_Prior", yd("mousemove --wheel -x 0 -y -1"), held)
-- left button goes down on press and up on release, so holding 4 drags
hl.bind("KP_Left",  yd("click 0x40"))
hl.bind("KP_Left",  yd("click 0x80"), { release = true })
hl.bind("KP_Right", yd("click 0xC1"))
hl.bind("KP_Up",    yd("click 0xC2"))

-- any keyboard, numpad or not: SUPER+arrows move, SUPER+. left, SUPER+/ right
for _, d in ipairs({ { "left", -mstep, 0 }, { "right", mstep, 0 },
                     { "up", 0, -mstep },   { "down", 0, mstep } }) do
  hl.bind(mod .. " + " .. d[1], move(d[2], d[3]), held)
end
hl.bind(mod .. " + period", yd("click 0x40"))
hl.bind(mod .. " + period", yd("click 0x80"), { release = true })
hl.bind(mod .. " + slash",  yd("click 0xC1"))

-- hopparch -- Hyprland config (Lua, Hyprland >= 0.55). Reload: SUPER+SHIFT+R
-- Every bind here is from the approved table in DESIGN.md.

local mod      = "SUPER"
-- -1 = one kitty process for all windows: ~15 MB per extra window instead of ~160
local terminal = "kitty -1"
local launcher = "fuzzel"
local browser  = "firefox"
local files    = "thunar"
local scripts  = os.getenv("HOME") .. "/.config/scripts"


hl.on("hyprland.start", function()
  -- the top bar; its top-left icon shows/hides the mouse bar (waybar/mouse.jsonc)
  hl.exec_cmd("waybar")
  -- notifications (screenshot saved, app messages)
  hl.exec_cmd("mako")
  -- lock before any sleep; laptops sleep after 10 min idle (hypridle.conf)
  hl.exec_cmd("hypridle")
  -- clipboard history for SUPER+CTRL+V: record every copy, text and images
  hl.exec_cmd("wl-paste --type text --watch cliphist store")
  hl.exec_cmd("wl-paste --type image --watch cliphist store")
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
    -- held keys repeat after 0.3 s, 50x per second (defaults: 0.6 s, 25x);
    -- this is also what makes the SUPER+arrows mouse fast with small steps
    repeat_delay = 300,
    repeat_rate = 50,
    -- focus follows clicks and keys only, never the mouse passing by
    follow_mouse = 0,
  },
  -- no "Hyprland updated" news window, no donation reminder
  ecosystem = {
    no_update_news = true,
    no_donation_nag = true,
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
-- btop's own kitty, sized in text cells (btop needs at least 80x24), so it
-- fits on any screen at any scale
hl.bind("CTRL + ALT + Delete", hl.dsp.exec_cmd(
  "kitty --class btop -o remember_window_size=no" ..
  " -o initial_window_width=82c -o initial_window_height=26c -e btop"))
hl.bind(mod .. " + Q",      hl.dsp.window.close())
hl.bind(mod .. " + M",      hl.dsp.window.fullscreen({ mode = "fullscreen" }))
hl.bind(mod .. " + SHIFT + R", hl.dsp.exec_cmd("hyprctl reload"))
-- power menu from the keyboard (the bar's power icon opens the same one)
hl.bind(mod .. " + SHIFT + E", hl.dsp.exec_cmd(scripts .. "/power-menu.sh"))
-- lock the screen (hyprlock.conf: black, one line of text, password)
hl.bind(mod .. " + SHIFT + Escape", hl.dsp.exec_cmd("pidof hyprlock || hyprlock"))

-- screenshots: path of the saved file is copied (screenshot.sh)
hl.bind(mod .. " + SHIFT + S",        hl.dsp.exec_cmd(scripts .. "/screenshot.sh region"))
hl.bind(mod .. " + SHIFT + CTRL + S", hl.dsp.exec_cmd(scripts .. "/screenshot.sh full"))
-- clipboard history
hl.bind(mod .. " + CTRL + V", hl.dsp.exec_cmd(scripts .. "/clipboard.sh"))

-- volume keys: 5% steps up to 100%; with SUPER held up to 150% (software
-- boost, can distort). locked = also work on the lock screen
local vol = "wpctl set-volume "
local sink = " @DEFAULT_AUDIO_SINK@ "
local media = { locked = true, repeating = true }
hl.bind("XF86AudioRaiseVolume",            hl.dsp.exec_cmd(vol .. "-l 1.0" .. sink .. "5%+"), media)
hl.bind(mod .. " + XF86AudioRaiseVolume",  hl.dsp.exec_cmd(vol .. "-l 1.5" .. sink .. "5%+"), media)
hl.bind("XF86AudioLowerVolume",            hl.dsp.exec_cmd(vol .. sink .. "5%-"), media)
hl.bind(mod .. " + XF86AudioLowerVolume",  hl.dsp.exec_cmd(vol .. sink .. "5%-"), media)
hl.bind("XF86AudioMute",    hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),   { locked = true })
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"), { locked = true })

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

-- mouse: SUPER + left drag moves, SUPER + right drag resizes. Real mice only:
-- the keyboard mouse (SUPER+, / SUPER+.) clicks with SUPER still held, and
-- must click, not grab the window
local real_mice = { inclusive = false, list = { "ydotoold-virtual-device-1", "ydotoold-virtual-device" } }
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true, device = real_mice })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true, device = real_mice })


-- workspaces 1-9: go there, +SHIFT sends the window there
for i = 1, 9 do
  hl.bind(mod .. " + " .. i,         hl.dsp.focus({ workspace = i }))
  hl.bind(mod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end

-- every open window in a list, the last used first: pick one to go there
-- (the mouse bar's window button opens the same list)
hl.bind(mod .. " + Tab", hl.dsp.exec_cmd(scripts .. "/windows.sh"), { description = "Windows list" })

-- scratchpad: a hidden workspace shown over the current one. SUPER+SHIFT+P
-- shows/hides it; whenever it is empty, showing it opens a terminal in it.
-- SUPER+CTRL+P puts the focused window there (SUPER+SHIFT+1-9 takes it back).
-- The terminal is found by its class: with kitty -1 the window belongs to the
-- kitty already running, so Hyprland can't tell it was started for here.
hl.workspace_rule({ workspace = "special:scratch", on_created_empty = terminal .. " --class scratchpad" })
hl.window_rule({
  name      = "scratchpad",
  match     = { class = "^(scratchpad)$" },
  workspace = "special:scratch silent",
})
hl.bind(mod .. " + SHIFT + P", hl.dsp.workspace.toggle_special("scratch"), { description = "Scratchpad show/hide" })
hl.bind(mod .. " + CTRL + P", hl.dsp.window.move({ workspace = "special:scratch", follow = false }),
        { description = "Send window to the scratchpad" })


-- mouse from the keyboard: SUPER+arrows move (hold to keep moving),
-- SUPER+, left click, SUPER+. right click. ydotool talks to ydotoold, a
-- system service set up by setup.sh.
hl.env("YDOTOOL_SOCKET", "/run/ydotoold/socket")
local mstep = 4  -- pixels per step: a tap is precise, holding = 200 px/s
local function yd(args) return hl.dsp.exec_cmd("ydotool " .. args) end
for _, d in ipairs({ { "left", -mstep, 0 }, { "right", mstep, 0 },
                     { "up", 0, -mstep },   { "down", 0, mstep } }) do
  hl.bind(mod .. " + " .. d[1], yd(("mousemove -x %d -y %d"):format(d[2], d[3])), { repeating = true })
end
hl.bind(mod .. " + comma",  yd("click 0xC0"))
hl.bind(mod .. " + period", yd("click 0xC1"))

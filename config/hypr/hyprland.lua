-- hopparch -- Hyprland config (Lua, Hyprland >= 0.55). Reload: SUPER+SHIFT+R
-- Step 1: basics only. Every bind here is from the approved table in DESIGN.md.

local mod      = "SUPER"
local terminal = "kitty"
local launcher = "fuzzel"


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
    -- focus follows clicks and keys only, never the mouse passing by
    follow_mouse = 0,
  },
  misc = {
    disable_hyprland_logo = true,
    force_default_wallpaper = 0,
    background_color = "rgba(000000ff)",
    -- a new window ends fullscreen instead of taking it over as "maximized"
    on_focus_under_fullscreen = 2,
  },
})


-- apps
hl.bind(mod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mod .. " + D",      hl.dsp.exec_cmd(launcher))
hl.bind(mod .. " + Q",      hl.dsp.window.close())
hl.bind(mod .. " + M",      hl.dsp.window.fullscreen({ mode = "fullscreen" }))
hl.bind(mod .. " + SHIFT + R", hl.dsp.exec_cmd("hyprctl reload"))
-- temporary way out until the power menu exists
hl.bind(mod .. " + SHIFT + E", hl.dsp.exit())


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

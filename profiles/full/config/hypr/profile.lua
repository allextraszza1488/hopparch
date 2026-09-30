-- hopparch full profile: the minimal look plus a little polish, same 0xyc
-- colours. Loaded at the end of hyprland.lua; the minimal profile has no such file.

hl.config({
  general = {
    -- cream fading to grey on the focused window
    col = { active_border = { colors = { "rgba(e8e4dcff)", "rgba(8a877fff)" }, angle = 45 } },
  },
  decoration = {
    rounding = 6,
    blur   = { enabled = true, size = 6, passes = 2 },
    shadow = { enabled = true, range = 12, render_power = 3, color = "rgba(00000099)" },
  },
  animations = { enabled = true },
})

-- short and calm: windows pop in, workspaces slide
hl.curve("easeOutQuint", { type = "bezier", points = { {0.23, 1}, {0.32, 1} } })
hl.animation({ leaf = "windows",    enabled = true, speed = 4, bezier = "easeOutQuint", style = "popin 90%" })
hl.animation({ leaf = "border",     enabled = true, speed = 5, bezier = "easeOutQuint" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 3, bezier = "easeOutQuint", style = "slide" })

-- Steam games start fullscreen
hl.window_rule({
  name  = "steam-games-fullscreen",
  match = { class = "^steam_app_[0-9]+$" },
  fullscreen = true,
})

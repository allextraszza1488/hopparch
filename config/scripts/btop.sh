#!/bin/bash
# System monitor, almost the whole screen, floating above other windows.
# Smaller text than a normal terminal so the CPU, memory, network and
# process list all fit. Opening it again focuses the one already there.
set -u
if hyprctl clients -j 2>/dev/null | grep -q '"class": "btop"'; then
  hyprctl dispatch 'hl.dsp.focus({ window = "class:^(btop)$" })' >/dev/null 2>&1 || true
  exit 0
fi
font=9
# Cell size at font 12 was measured at about 10.2 x 22.3 logical pixels.
read -r cols rows < <(FONT=$font python3 -c '
import json, os, subprocess
font = float(os.environ["FONT"])
cw, ch = 10.2 * font / 12, 22.3 * font / 12
try:
    mons = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"], text=True))
    m = next((x for x in mons if x.get("focused")), mons[0])
    scale = float(m.get("scale") or 1) or 1
    w = float(m["width"]) / scale
    h = float(m["height"]) / scale
    reserved = m.get("reserved") or [0, 0, 0, 0]
    w -= float(reserved[0]) + float(reserved[2])
    h -= float(reserved[1]) + float(reserved[3])
except Exception:
    w, h = 1280, 720
cols = max(80, int(w * 0.96 / cw))
rows = max(28, int(h * 0.94 / ch))
print(cols, rows)
')
exec kitty --class btop \
  -o remember_window_size=no \
  -o font_size="$font" \
  -o initial_window_width="${cols}c" \
  -o initial_window_height="${rows}c" \
  -e btop

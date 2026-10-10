#!/bin/bash
# Ctrl+Super+. Pick a kaomoji. It is copied, and typed where the cursor is.
# Noto Sans is proportional, so the stacked marks sit on the letters.
# A monospace font draws those marks in their own cells, which looks broken.
set -u
choice=$(
  fuzzel --dmenu --cache=/dev/null \
    --font 'Noto Sans:size=18' --prompt 'kaomoji> ' --width 36 --lines 15 <<'EOF' || true
(◕‿◕)
(^▽^)
(♥ω♥)
(˘ ³˘)♥
(˶ᵔ ᵕ ᵔ˶)♡
(⁄ ⁄•⁄ω⁄•⁄ ⁄)
(◞‸◟)
¯\_(´-`)_/¯
(T_T)
(╯°□°)╯┻━┻
(⊙_⊙)
ಠ_ಠ
(ง •̀_•́)ง
ᕦ( ͡° ͜ʖ ͡°)ᕤ
(☞ ͡° ͜ʖ ͡°)☞
EOF
)
[[ -n ${choice:-} ]] || exit 0
printf '%s' "$choice" | wl-copy
# The picker is still the focused window if we type immediately.
sleep 0.1
if command -v wtype >/dev/null; then
  wtype -d 0 -- "$choice" || true
elif [[ -S ${YDOTOOL_SOCKET:-/run/ydotoold/socket} ]]; then
  printf '%s' "$choice" | ydotool type --escape 0 --file - || true
fi

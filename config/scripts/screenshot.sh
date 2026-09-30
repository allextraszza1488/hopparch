#!/bin/bash
# Screenshots: SUPER+SHIFT+S = pick a region, SUPER+SHIFT+CTRL+S = whole screen.
# Saved in ~/Pictures/Screenshots. Copies the file's path, then the picture:
# the picture is what you paste, the path is one step back in the clipboard
# history (SUPER+CTRL+V).
#   screenshot.sh region|full
dir=~/Pictures/Screenshots
mkdir -p "$dir"
file=$dir/$(date +%F_%H-%M-%S).png

case $1 in
  region) geom=$(slurp) || exit 0   # Escape while picking = cancel
          grim -g "$geom" "$file" ;;
  *)      grim "$file" ;;
esac || exit 1

printf '%s' "$file" | wl-copy
# give the clipboard history a moment to record the path before replacing it
sleep 0.3
wl-copy --type image/png <"$file"
notify-send -t 3000 "Screenshot saved" "picture copied (path: SUPER+CTRL+V)"

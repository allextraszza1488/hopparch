#!/bin/bash
# Screenshots: SUPER+SHIFT+S = pick a region, SUPER+SHIFT+CTRL+S = whole screen.
# Saved in ~/Pictures/Screenshots; the file's path is copied, ready to paste.
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
notify-send -t 3000 "Screenshot saved" "path copied: $file"

#!/bin/bash
# The mouse bar's workspace buttons, on the focused monitor:
#   prev  the previous open workspace (from the first: the last)
#   next  the next open workspace; from the last: a new empty one
set -euo pipefail

go() { hyprctl dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null; }

case ${1:-} in
  prev) go m-1 ;;
  next)
    # last open one with windows: make a new one (an empty last one stays put)
    act=$(hyprctl -j activeworkspace)
    last=$(hyprctl -j workspaces | jq --argjson a "$act" \
      '[.[] | select(.monitor == $a.monitor and .id > 0) | .id] | max')
    if [[ $(jq .id <<<"$act") == "$last" ]]; then
      [[ $(jq .windows <<<"$act") == 0 ]] || go emptynm
    else
      go m+1
    fi ;;
  *) echo "usage: workspace.sh prev|next" >&2; exit 2 ;;
esac

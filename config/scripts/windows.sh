#!/bin/bash
# Windows list (SUPER+Tab, and the mouse bar's window button): every open
# window, the last used first, so SUPER+Tab then Enter goes back to the
# previous window. Each line: workspace, app, title. Pick one to go there.
set -euo pipefail

# "address<TAB>workspace  app  title" per window, most recently focused first,
# the one you're in last (tabs/newlines in titles become spaces: one line each)
active=$(hyprctl activewindow -j | jq -r '.address // ""')
list=$(hyprctl clients -j | jq -r --arg active "$active" '
  map(select(.mapped and (.hidden | not)))
  | sort_by(.address == $active, .focusHistoryID)
  | .[]
  | "\(.address)\t\(.workspace.name | sub("^special:"; ""))   \(.class)   \(.title | gsub("[\t\n\r]"; " "))"')
[[ -n $list ]] || exit 0
n=$(wc -l <<<"$list")

# shows column 2, prints column 1 (the address); Escape = nothing chosen
addr=$(fuzzel --dmenu --only-match --with-nth=2 --accept-nth=1 --width 60 \
         --lines "$(( n < 15 ? n : 15 ))" --prompt 'window> ' <<<"$list") || exit 0
# only ever a window address goes into the command below
[[ $addr =~ ^0x[0-9a-f]+$ ]] || exit 0
hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null

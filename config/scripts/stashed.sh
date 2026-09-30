#!/bin/bash
# "Stashed apps" (an entry in SUPER+D): a second launcher with only the apps
# hidden from the main one, listed in ~/.config/hopparch/stashed.list.

ids=() lines=""
while read -r id; do
  f=/usr/share/applications/$id.desktop
  [[ -f $f ]] || continue
  name=$(grep -m1 '^Name=' "$f" | cut -d= -f2-)
  icon=$(grep -m1 '^Icon=' "$f" | cut -d= -f2-)
  ids+=("$id")
  # "\0icon\x1f<name>" = show this icon next to the line
  lines+="$name"$'\0'"icon"$'\x1f'"$icon"$'\n'
done < <(grep -v -e '^#' -e '^\s*$' ~/.config/hopparch/stashed.list)

# --index: fuzzel prints the chosen line's number, not its text
i=$(printf '%s' "$lines" | fuzzel --dmenu --index --prompt 'stashed> ') || exit 0
# gio starts the original .desktop file, even though our override hides it
gio launch "/usr/share/applications/${ids[$i]}.desktop"

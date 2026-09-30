#!/bin/bash
# Clipboard history (SUPER+CTRL+V): pick an earlier copy to copy it again,
# text or picture. Pictures show as "PICTURE 1280x800" instead of cliphist's
# "[[ binary data ... ]]". The history is recorded by the cliphist watchers
# Hyprland starts at login (kept in ~/.cache/cliphist; `cliphist wipe` clears it).

# cliphist lists "id<TAB>preview"; relabel pictures, show the preview, get the id back
id=$(cliphist list \
  | sed -E 's/\[\[ binary data .* (png|jpe?g|bmp|webp|gif) ([0-9]+x[0-9]+) \]\]/PICTURE \2/' \
  | fuzzel --dmenu --with-nth=2 --accept-nth=1 --prompt 'clipboard> ') || exit 0
[[ $id =~ ^[0-9]+$ ]] || exit 0
# wl-copy works out by itself whether it's text or a picture
cliphist decode "$id" | wl-copy

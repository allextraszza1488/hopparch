#!/bin/bash
# Clipboard history (SUPER+CTRL+V): pick an earlier copy to copy it again.
# The history is recorded by the cliphist watchers Hyprland starts at login
# (kept in ~/.cache/cliphist; `cliphist wipe` clears it).
pick=$(cliphist list | fuzzel --dmenu --prompt 'clipboard> ') || exit 0
cliphist decode <<<"$pick" | wl-copy

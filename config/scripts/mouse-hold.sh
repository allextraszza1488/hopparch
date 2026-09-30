#!/bin/bash
# Grab / let go of a mouse button from the numpad: first press holds the
# button down, the next press releases it. (Holding a key while pressing
# another doesn't work in Hyprland, so dragging is a toggle.)
#   mouse-hold.sh left|right
case $1 in
  left)  down=0x40 up=0x80 ;;
  right) down=0x41 up=0x81 ;;
  *) exit 1 ;;
esac

flag=$XDG_RUNTIME_DIR/hopparch-mouse-held-$1
if [[ -e $flag ]]; then
  ydotool click "$up" && rm -f "$flag"
else
  ydotool click "$down" && touch "$flag"
fi

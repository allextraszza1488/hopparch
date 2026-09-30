#!/bin/bash
# Power menu: the bar's power icon and SUPER+SHIFT+E.
# Lock and Sleep keep everything open (Sleep locks first, via hypridle).
# Logout/Restart/Shutdown ask first.

# fuzzel exits non-zero on Escape; || true turns that into "nothing chosen"
pick() { fuzzel --dmenu --prompt "$1" || true; }
sure() { [[ $(printf 'No\nYes' | pick "$1? ") == Yes ]]; }

case $(printf 'Lock\nSleep\nLogout\nRestart\nShutdown' | pick 'power> ') in
  Lock)     pidof hyprlock || hyprlock ;;
  Sleep)    systemctl suspend ;;
  Logout)   sure Logout   && hyprctl dispatch 'hl.dsp.exit()' ;;
  Restart)  sure Restart  && systemctl reboot ;;
  Shutdown) sure Shutdown && systemctl poweroff ;;
esac

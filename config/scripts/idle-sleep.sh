#!/bin/bash
# hypridle runs this after 10 minutes without input: laptops go to sleep
# (locked first, see hypridle.conf); desktops do nothing.
compgen -G '/sys/class/power_supply/BAT*' >/dev/null && systemctl suspend
exit 0

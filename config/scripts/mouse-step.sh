#!/bin/bash
# One step of the keyboard/numpad mouse. Hyprland runs this on the press and
# on every key repeat while a direction is held, so holding speeds up:
# START px/s at first, growing over RAMP seconds to 1/6 of the screen width per second.
#   mouse-step.sh <dx> <dy>     dx, dy = -1, 0 or 1
# works from anywhere, not only from Hyprland (which also sets it)
export YDOTOOL_SOCKET=${YDOTOOL_SOCKET:-/run/ydotoold/socket}

START=60   # px/s on the first press: a tap moves ~2 px
RAMP=10    # seconds of holding until full speed
RATE=25    # key repeats per second (Hyprland's input.repeat_rate, default 25)

state=$XDG_RUNTIME_DIR/hopparch-mouse-step
now=${EPOCHREALTIME/./}   # microseconds
read -r start last cap 2>/dev/null <"$state"

# nothing for longer than the first repeat delay (0.6 s) = a new press: start slow
if [[ -z $last ]] || ((now - last > 700000)); then
  start=$now
  width=$(hyprctl monitors | awk '/^\t[0-9]+x[0-9]+@/ { split($1, a, "x"); print a[1]; exit }')
  cap=$(( ${width:-1920} / 6 ))
fi

ramp=$((RAMP * 1000000))
held=$((now - start))
((held > ramp)) && held=$ramp
speed=$((START + (cap - START) * held / ramp))
step=$((speed / RATE))
((step < 1)) && step=1

echo "$start $now $cap" >"$state"
ydotool mousemove -x $(($1 * step)) -y $(($2 * step))

#!/bin/bash
# Screen brightness for the backlight that is actually wired to the panel.
# nvidia_wmi_ec_backlight on an AMD-driven ASUS panel reports actual
# brightness 0 and never changes the screen. Prefer amdgpu / intel.
#   brightness.sh get | device | up | down | set 50%
set -euo pipefail

device() {
  local d name
  for d in /sys/class/backlight/amdgpu_bl* /sys/class/backlight/intel_backlight /sys/class/backlight/acpi_video*; do
    [[ -e $d ]] || continue
    echo "${d##*/}"
    return 0
  done
  for d in /sys/class/backlight/*; do
    [[ -e $d ]] || continue
    name=${d##*/}
    [[ $name == nvidia_wmi_ec_backlight ]] && continue
    echo "$name"
    return 0
  done
  if [[ -d /sys/class/backlight/nvidia_wmi_ec_backlight ]]; then
    echo nvidia_wmi_ec_backlight
    return 0
  fi
  return 1
}

dev=$(device) || exit 1
case ${1:-get} in
  device) echo "$dev" ;;
  get) brightnessctl -d "$dev" -m | cut -d, -f4 ;;
  up) brightnessctl -q -d "$dev" set '5%+' ;;
  down) brightnessctl -q -d "$dev" -n1 set '5%-' ;;
  set) brightnessctl -q -d "$dev" set "$2" ;;
  *) echo "usage: brightness.sh get|device|up|down|set PERCENT" >&2; exit 2 ;;
esac

#!/bin/bash
# Screen brightness for the backlight wired to the panel.
# Prefer amdgpu / intel when those exist. On an ASUS hybrid laptop the
# panel is drawn by amdgpu and the brightness still lives on
# nvidia_wmi_ec_backlight, so that device is used when it is the only one.
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

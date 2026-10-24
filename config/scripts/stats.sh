#!/bin/bash
# Numbers for the top bar's stats (waybar calls this every few seconds).
#   stats.sh cpu-temp   e.g. "54°"       (nothing if no CPU sensor is found)
#   stats.sh gpu        e.g. "GPU 30% 61°", "GPU off" (a sleeping laptop GPU)
# Prints nothing when it has nothing to show, and waybar hides the module.
# STATS_SYSROOT is only for tests: a fake /sys tree.
sys=${STATS_SYSROOT:-}/sys

cpu_temp() {
  local h name
  for h in "$sys"/class/hwmon/hwmon*; do
    name=$(cat "$h/name" 2>/dev/null) || continue
    # Intel, AMD (k10temp reports Tctl as temp1), AMD zenpower, ARM
    case $name in coretemp|k10temp|zenpower|cpu_thermal)
      [[ -r $h/temp1_input ]] && { echo "$(( $(<"$h/temp1_input") / 1000 ))°"; return; } ;;
    esac
  done
}

# An awake NVIDIA GPU first (it is the one doing the work on a desktop, or a
# hybrid laptop's game), then an AMD GPU, else "GPU off" if only a sleeping
# NVIDIA one exists, else nothing (Intel has no usage counter without root).
gpu() {
  local dev status hw t asleep=""
  for dev in "$sys"/bus/pci/devices/*; do
    [[ $(cat "$dev/class" 2>/dev/null) == 0x03* && $(cat "$dev/vendor" 2>/dev/null) == 0x10de ]] || continue
    # a laptop's NVIDIA GPU sleeps to save battery, and nvidia-smi would wake it
    status=$(cat "$dev/power/runtime_status" 2>/dev/null || echo active)
    if [[ $status != active ]]; then asleep=1; continue; fi
    command -v nvidia-smi >/dev/null || continue
    nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null |
      awk -F', *' 'NR == 1 { printf "GPU %d%% %d°\n", $1, $2 }' | grep . && return
  done
  for dev in "$sys"/bus/pci/devices/*; do
    [[ $(cat "$dev/vendor" 2>/dev/null) == 0x1002 && -r $dev/gpu_busy_percent ]] || continue
    t=""
    for hw in "$dev"/hwmon/hwmon*; do [[ -r $hw/temp1_input ]] && t=" $(( $(<"$hw/temp1_input") / 1000 ))°"; done
    echo "GPU $(<"$dev/gpu_busy_percent")%$t"; return
  done
  [[ -n $asleep ]] && echo "GPU off"
  return 0
}

# Wi-Fi icon for the bar. Nothing if this machine has no wireless device,
# so a desktop with only a cable does not get an empty icon. The name of
# the network is the tooltip. The password is never read.
wifi() {
  local iface q pct icon tip ssid
  iface=""
  for iface in "$sys"/class/net/*/wireless; do
    [[ -e $iface ]] || continue
    iface=$(basename "$(dirname "$iface")")
    break
  done
  [[ -n $iface && $iface != *'*'* ]] || return 0
  q=$(awk -v i="$iface:" '$1 == i { printf "%d", $3; exit }' "$sys/../proc/net/wireless" 2>/dev/null || true)
  # link quality in /proc is 0..70
  if [[ -z ${q:-} || $q -le 0 ]]; then
    icon="󰤭"
    tip="Wi-Fi disconnected"
  else
    pct=$(( q * 100 / 70 ))
    (( pct > 100 )) && pct=100
    if (( pct >= 75 )); then icon="󰤨"
    elif (( pct >= 50 )); then icon="󰤥"
    elif (( pct >= 25 )); then icon="󰤢"
    else icon="󰤟"
    fi
    ssid=""
    if command -v iw >/dev/null; then
      ssid=$(iw dev "$iface" link 2>/dev/null | awk -F': ' '/SSID/ { print $2; exit }')
    fi
    tip="${ssid:-Wi-Fi}  ${pct}%"
  fi
  jq -nc --arg text "$icon" --arg tooltip "$tip" '{text:$text,tooltip:$tooltip}'
}

case ${1:-} in
  cpu-temp) cpu_temp ;;
  gpu) gpu ;;
  wifi) wifi ;;
  *) echo "usage: stats.sh cpu-temp|gpu|wifi" >&2; exit 2 ;;
esac

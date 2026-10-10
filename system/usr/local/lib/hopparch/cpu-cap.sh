#!/bin/bash
# amd-pstate active mode keeps the max-clock cap from boot. If a power
# profile later allows boost, the advertised max rises and the cap does not,
# so the CPU stays at its base clock. Reloading the driver copies the clock
# the CPU already reports. This is not an overclock.
# Nothing happens when the cap is already at that clock (a desktop, or a
# boot that started in the right profile).
# A reload resets the energy preference, so the preference is written again
# to match the power profile that is on now.
set -u
status=/sys/devices/system/cpu/amd_pstate/status
capf=/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
infof=/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
[[ -w $status && -r $capf && -r $infof ]] || exit 0
cap=$(cat "$capf" 2>/dev/null || echo 0)
info=$(cat "$infof" 2>/dev/null || echo 0)
[[ $cap != 0 && $info != 0 && $cap -lt $info ]] || exit 0

profile=$(powerprofilesctl get 2>/dev/null || echo balanced)
echo passive >"$status" || exit 0
echo active >"$status" || echo active >"$status" || true

case $profile in
  performance) gov=performance; epp=performance ;;
  power-saver) gov=powersave; epp=power ;;
  *) gov=powersave; epp=balance_performance ;;
esac
shopt -s nullglob
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  [[ -w $cpu/cpufreq/scaling_governor ]] && echo "$gov" >"$cpu/cpufreq/scaling_governor" || true
  [[ -w $cpu/cpufreq/energy_performance_preference ]] && echo "$epp" >"$cpu/cpufreq/energy_performance_preference" || true
done
exit 0

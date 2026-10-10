#!/bin/bash
# Settings without a settings app: the Wi-Fi, Bluetooth, Brightness, Power
# mode, Battery and Specs entries in SUPER+D, and the mouse bar's settings
# button (no argument = a menu of all of them). Every screen is a fuzzel list.
#   settings.sh [wifi|bluetooth|brightness|power|battery|specs]
set -euo pipefail
# *( ) patterns (bt_pair strips colour codes with one)
shopt -s extglob

# a list to pick from; prints the chosen line, nothing on Escape
# --cache=/dev/null: a settings list must not also show old launcher searches
pick() { local prompt=$1; shift; fuzzel --dmenu --cache=/dev/null --prompt "$prompt> " "$@" || true; }
# a list that is only read (Escape or Enter closes it)
show() { fuzzel --dmenu --cache=/dev/null --prompt "$1> " --width 50 --lines "$(wc -l <<<"$2")" <<<"$2" >/dev/null || true; }
note() { notify-send -t 4000 "$@"; }


wifi() {
  if [[ $(nmcli radio wifi) != enabled ]]; then
    [[ $(printf 'Turn Wi-Fi on' | pick wifi) ]] && nmcli radio wifi on && note "Wi-Fi on"
    return 0
  fi
  # one line per network, strongest first; SSID last because it may contain ":"
  local lines choice ssid security
  lines=$(nmcli -t --escape no -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan auto |
    awk -F: '$4 != "" && !seen[$4]++ {
      ssid = $0; sub(/^[^:]*:[^:]*:[^:]*:/, "", ssid)
      printf "%s %3s%%  %-4s  %s\n", ($1 == "*" ? ">" : " "), $2, ($3 == "" ? "open" : "lock"), ssid }')
  choice=$(printf '%s\n%s\n' "$lines" "  Turn Wi-Fi off" | pick wifi --width 50) || return 0
  [[ -n $choice ]] || return 0
  if [[ $choice == "  Turn Wi-Fi off" ]]; then nmcli radio wifi off; note "Wi-Fi off"; return 0; fi
  ssid=${choice:14}
  security=${choice:8:4}
  # the connected one: offer to disconnect
  if [[ $choice == ">"* ]]; then
    [[ $(printf 'Disconnect' | pick "$ssid") ]] && nmcli connection down id "$ssid" >/dev/null && note "Disconnected from $ssid"
    return 0
  fi
  # known network, or open: just connect. A new locked one asks for a password.
  # A failed retry must not delete a profile that was already saved.
  # device wifi connect cannot create a WPA3 profile. 802.1X needs a username.
  local existed=0 pw f sec km
  nmcli -t -f NAME connection show | grep -qxF -- "$ssid" && existed=1
  if [[ $security == open || $existed == 1 ]]; then
    nmcli device wifi connect "$ssid" >/dev/null 2>&1 && note "Connected to $ssid" && return 0
  fi
  [[ $security == open ]] && { note "Could not connect to $ssid"; return 0; }
  sec=$(nmcli -t --escape no -f SECURITY,SSID device wifi list --rescan no |
    awk -F: -v s="$ssid" '{
      name = $0
      sub(/^[^:]*:/, "", name)
      if (name == s) { print $1; exit }
    }')
  if [[ $sec == *802.1X* ]]; then
    note "$ssid needs a username" "this menu only has a password"
    return 0
  fi
  km=wpa-psk
  # WPA2/WPA3 mixed still joins as wpa-psk. WPA3-only does not.
  [[ $sec == *WPA3* && $sec != *WPA2* && $sec != *WPA1* ]] && km=sae
  pw=$(fuzzel --dmenu --cache=/dev/null --password --prompt "password for $ssid> " --lines 0 </dev/null) || return 0
  [[ -n $pw ]] || return 0
  if [[ $existed == 0 ]]; then
    nmcli connection add type wifi con-name "$ssid" ssid "$ssid" wifi-sec.key-mgmt "$km" >/dev/null
  fi
  f=$(mktemp)
  chmod 600 "$f"
  trap 'rm -f "$f"' RETURN
  # nmcli reads this file. The password is not a command argument.
  printf '802-11-wireless-security.psk:%s\n' "$pw" >"$f"
  unset pw
  if nmcli connection up id "$ssid" passwd-file "$f" >/dev/null 2>&1; then
    python3 - "$ssid" "$f" <<'PY' || true
import warnings, sys, gi
warnings.filterwarnings("ignore", category=DeprecationWarning)
gi.require_version("NM", "1.0")
from gi.repository import NM
ssid, path = sys.argv[1], sys.argv[2]
pw = open(path).read().split(":", 1)[1].rstrip("\n")
c = NM.Client.new(None)
conn = next(x for x in c.get_connections() if x.get_id() == ssid)
conn.get_setting_wireless_security().set_property("psk", pw)
conn.commit_changes(True, None)
PY
    note "Connected to $ssid"
  else
    [[ $existed == 0 ]] && nmcli connection delete id "$ssid" >/dev/null 2>&1 || true
    note "Could not connect to $ssid" "wrong password?"
  fi
}


# Bluetooth pairing needs an agent that answers the device (a code to type on
# a keyboard, a number to confirm). bluetoothctl only runs one when
# interactive, so pairing talks to one interactive bluetoothctl.
bt_pair() {
  local mac=$1 name=$2 line code
  coproc BT { bluetoothctl 2>&1; }
  printf 'agent KeyboardDisplay\ndefault-agent\npair %s\n' "$mac" >&"${BT[1]}"
  while IFS= read -r -t 60 line <&"${BT[0]}"; do
    # drop the colour codes bluetoothctl puts in its output
    line=${line//$'\e'\[*([0-9;])m/}
    case $line in
      *"Pairing successful"*) printf 'trust %s\nconnect %s\n' "$mac" "$mac" >&"${BT[1]}" ;;
      *"Connection successful"*) note "Bluetooth: $name connected"; break ;;
      *"Failed to pair"*|*"Failed to connect"*) note "Bluetooth: $name failed" "${line##*: }"; break ;;
      # keyboards: type the code shown on the keyboard itself
      *"Passkey: "*) note -t 30000 "Bluetooth: type on $name" "${line##*Passkey: }, then Enter" ;;
      # both screens show a number: same number = the right device
      *"Request confirmation"*)
        IFS= read -r -t 5 -d ')' code <&"${BT[0]}" || true
        code=$(grep -o '[0-9]\{6\}' <<<"$code")
        if [[ $(printf 'No\nYes' | pick "$name shows $code?" --lines 2) == Yes ]]; then echo yes; else echo no; fi >&"${BT[1]}" ;;
      *"Request PIN code"*|*"Request passkey"*)
        code=$(fuzzel --dmenu --cache=/dev/null --prompt "PIN for $name> " --lines 0 </dev/null) || true
        echo "$code" >&"${BT[1]}" ;;
      # you asked to pair this device, so it may
      *"Request authorization"*|*"Authorize service"*) echo yes >&"${BT[1]}" ;;
    esac
  done
  echo quit >&"${BT[1]}"
  wait "$BT_PID" 2>/dev/null || true
}

bluetooth() {
  if ! bluetoothctl show | grep -q 'Powered: yes'; then
    [[ $(printf 'Turn Bluetooth on' | pick bluetooth) ]] || return 0
    bluetoothctl power on >/dev/null || { note "Bluetooth: no adapter (or it is blocked)"; return 0; }
  fi
  local choice mac name dev lines=""
  choice=$(printf 'Connect a paired device\nPair a new device\nTurn Bluetooth off' | pick bluetooth --lines 3)
  case $choice in
    "Turn Bluetooth off") bluetoothctl power off >/dev/null; note "Bluetooth off"; return 0 ;;
    "Pair a new device")
      note "Bluetooth: looking for devices (10 s)" "put the device in pairing mode"
      bluetoothctl --timeout 10 scan on >/dev/null 2>&1 || true
      lines=$(bluetoothctl devices | grep -vFf <(bluetoothctl devices Paired | cut -d' ' -f2) || true) ;;
    "Connect a paired device") lines=$(bluetoothctl devices Paired) ;;
    *) return 0 ;;
  esac
  [[ -n $lines ]] || { note "Bluetooth: no devices found"; return 0; }
  # "Device AA:BB:.. Name" -> "Name  AA:BB:.."
  dev=$(awk '{ mac = $2; $1 = $2 = ""; sub(/^ +/, ""); print $0 "  " mac }' <<<"$lines" | pick device --width 50) || return 0
  [[ -n $dev ]] || return 0
  mac=${dev##* } name=${dev%  *}
  if [[ $choice == "Pair a new device" ]]; then
    bt_pair "$mac" "$name"
  elif bluetoothctl info "$mac" | grep -q 'Connected: yes'; then
    bluetoothctl disconnect "$mac" >/dev/null && note "Bluetooth: $name disconnected"
  else
    if bluetoothctl connect "$mac" >/dev/null; then note "Bluetooth: $name connected"; else note "Bluetooth: $name failed to connect"; fi
  fi
}


brightness() {
  local script=$HOME/.config/scripts/brightness.sh dev now choice actual
  dev=$("$script" device 2>/dev/null) || { note "No screen brightness control here" "(desktop monitors: use their buttons)"; return 0; }
  # The EC device stays at 0 no matter what is written. A real panel can be at 0.
  actual=$(cat "/sys/class/backlight/$dev/actual_brightness" 2>/dev/null || true)
  if [[ $dev == nvidia_wmi_ec_backlight && $actual == 0 ]]; then
    show brightness "This control is not wired. The driver stores a number and the panel ignores it."
    return 0
  fi
  now=$("$script" get 2>/dev/null) || true
  choice=$(printf '100%%\n75%%\n50%%\n25%%\n10%%' | pick "brightness ${now:-?}" --lines 5 --width 24)
  [[ $choice =~ ^[0-9]+%$ ]] && "$script" set "$choice"
  return 0
}

power() {
  local now choice
  now=$(powerprofilesctl get 2>/dev/null) || { note "Power modes: power-profiles-daemon isn't running"; return 0; }
  # power-saver = economy: slower, cooler, longer on battery
  choice=$(powerprofilesctl list | sed -n 's/^[* ] *\([a-z-]*\):$/\1/p' | pick "power mode $now" --lines 3 --width 30)
  [[ -n $choice ]] && powerprofilesctl set "$choice" && note "Power mode: $choice"
  # the CPU cap can stay at the old clock after the firmware allows boost.
  # the helper reloads the driver only in that case, and does nothing otherwise.
  sudo -n /usr/local/lib/hopparch/cpu-cap.sh >/dev/null 2>&1 || true
  return 0
}

battery() {
  local b out=""
  for b in /sys/class/power_supply/BAT*; do
    [[ -e $b ]] || { note "No battery"; return 0; }
    local cap st full design
    cap=$(cat "$b/capacity") st=$(cat "$b/status")
    full=$(cat "$b/energy_full" 2>/dev/null || cat "$b/charge_full" 2>/dev/null || echo 0)
    design=$(cat "$b/energy_full_design" 2>/dev/null || cat "$b/charge_full_design" 2>/dev/null || echo 0)
    out+="${b##*/}  $cap%  $st"$'\n'
    ((design > 0)) && out+="  health  $((full * 100 / design))% of new"$'\n'
  done
  show battery "${out%$'\n'}"
}

# the hardware and system, and nothing that identifies the machine or the
# network (no hostname, user, IP, MAC, serial numbers)
specs() {
  show specs "$(fastfetch --pipe --logo none --structure \
    OS:Kernel:Uptime:Packages:Shell:WM:CPU:GPU:Memory:Swap:Disk:Display:Battery:Host)"
}


case ${1:-} in
  wifi|bluetooth|brightness|power|battery|specs) "$1" ;;
  "")
    case $(printf 'Wi-Fi\nBluetooth\nBrightness\nPower mode\nBattery\nSpecs' | pick settings --lines 6) in
      Wi-Fi) wifi ;; Bluetooth) bluetooth ;; Brightness) brightness ;;
      "Power mode") power ;; Battery) battery ;; Specs) specs ;;
    esac ;;
  *) echo "usage: settings.sh [wifi|bluetooth|brightness|power|battery|specs]" >&2; exit 2 ;;
esac

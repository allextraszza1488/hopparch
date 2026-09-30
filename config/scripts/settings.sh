#!/bin/bash
# Settings without a settings app: the Wi-Fi, Bluetooth, Brightness, Power
# mode, Battery and Specs entries in SUPER+D, and the mouse bar's settings
# button (no argument = a menu of all of them). Every screen is a fuzzel list.
#   settings.sh [wifi|bluetooth|brightness|power|battery|specs]
set -euo pipefail
# *( ) patterns (bt_pair strips colour codes with one)
shopt -s extglob

# a list to pick from; prints the chosen line, nothing on Escape
pick() { local prompt=$1; shift; fuzzel --dmenu --prompt "$prompt> " "$@" || true; }
# a list that is only read (Escape or Enter closes it)
show() { fuzzel --dmenu --prompt "$1> " --width 50 --lines "$(wc -l <<<"$2")" <<<"$2" >/dev/null || true; }
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
  # known network, or open: just connect. New locked one: ask the password.
  if [[ $security == open ]] || nmcli -t -f NAME connection show | grep -qxF -- "$ssid"; then
    nmcli device wifi connect "$ssid" >/dev/null 2>&1 && note "Connected to $ssid" && return 0
  fi
  local pw
  pw=$(fuzzel --dmenu --password --prompt "password for $ssid> " --lines 0 </dev/null) || return 0
  [[ -n $pw ]] || return 0
  if nmcli device wifi connect "$ssid" password "$pw" >/dev/null 2>&1; then
    note "Connected to $ssid"
  else
    # don't keep a profile with a wrong password
    nmcli connection delete id "$ssid" >/dev/null 2>&1 || true
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
        code=$(fuzzel --dmenu --prompt "PIN for $name> " --lines 0 </dev/null) || true
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
  local now choice
  now=$(brightnessctl -m 2>/dev/null | cut -d, -f4) || true
  [[ -n $now ]] || { note "No screen brightness control here" "(desktop monitors: use their buttons)"; return 0; }
  choice=$(printf '100%%\n75%%\n50%%\n25%%\n10%%' | pick "brightness $now" --lines 5 --width 20)
  [[ $choice =~ ^[0-9]+%$ ]] && brightnessctl -q set "$choice"
  return 0
}

power() {
  local now choice
  now=$(powerprofilesctl get 2>/dev/null) || { note "Power modes: power-profiles-daemon isn't running"; return 0; }
  # power-saver = economy: slower, cooler, longer on battery
  choice=$(powerprofilesctl list | sed -n 's/^[* ] *\([a-z-]*\):$/\1/p' | pick "power mode $now" --lines 3 --width 30)
  [[ -n $choice ]] && powerprofilesctl set "$choice" && note "Power mode: $choice"
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

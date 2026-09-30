#!/bin/bash
# hopparch installer -- run as root from the Arch ISO, after:
#   1. Wi-Fi:       iwctl station wlan0 connect "<network>"
#   2. partitions:  cfdisk /dev/<disk>   (an EFI partition + one root partition)
# Stages: scan -> profile -> partitions -> archinstall (preset) -> our setup.
# Only stage 1 (scan) + the profile question exist so far.
set -euo pipefail

# archinstall versions this script was tested against; others get a warning
TESTED_ARCHINSTALL="4.4"

# ---------------------------------------------------------------- helpers
say()  { printf '\e[1m==> %s\e[0m\n' "$*"; }
warn() { printf '\e[33m!!  %s\e[0m\n' "$*"; }
die()  { printf '\e[31mxx  %s\e[0m\n' "$*"; exit 1; }
row()  { printf '  %-10s %s\n' "$1" "$2"; }
# Y/n question, Enter = yes. Reads the keyboard, not stdin, so `curl ... | bash` works.
ask()  { local a; read -rp "$1 [Y/n] " a </dev/tty; [[ -z $a || $a == [Yy]* ]]; }


# ---------------------------------------------------------------- stage 0: can we run here?
preflight() {
  [[ $EUID -eq 0 ]] || die "run as root (the Arch ISO logs you in as root)"
  [[ -d /run/archiso ]] || die "run this from the Arch ISO, not an installed system"
  ping -c1 -W3 archlinux.org >/dev/null 2>&1 \
    || die "no internet -- connect first: iwctl station wlan0 connect \"<network>\""
  local v
  v=$(archinstall --version 2>/dev/null | awk '{print $2}')
  [[ " $TESTED_ARCHINSTALL " == *" $v "* ]] \
    || warn "archinstall $v is untested (tested: $TESTED_ARCHINSTALL) -- its config format may have changed"
}


# ---------------------------------------------------------------- stage 1: scan
scan() {
  if [[ -r /sys/firmware/efi/fw_platform_size ]]; then
    FIRMWARE="UEFI $(cat /sys/firmware/efi/fw_platform_size)-bit"
  else
    FIRMWARE="BIOS (legacy)"
  fi

  CPU=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)
  CORES=$(nproc)
  RAM_GIB=$(awk '/^MemTotal/ {printf "%d", $2 / 1048576 + 0.5}' /proc/meminfo)

  # display controllers: VGA [0300], 3D [0302], other display [0380]
  GPU_LINES=$(lspci -nn | grep -E '\[030[028]\]' || true)
  GPUS=()
  grep -q '\[10de:' <<<"$GPU_LINES" && GPUS+=(nvidia)
  grep -q '\[1002:' <<<"$GPU_LINES" && GPUS+=(amd)
  grep -q '\[8086:' <<<"$GPU_LINES" && GPUS+=(intel)
  ((${#GPUS[@]})) || GPUS+=(generic)

  # laptop = has a battery, or DMI says portable chassis (8-10, 14, 31, 32)
  LAPTOP=no
  compgen -G '/sys/class/power_supply/BAT*' >/dev/null && LAPTOP=yes
  case $(cat /sys/class/dmi/id/chassis_type 2>/dev/null) in
    8|9|10|14|31|32) LAPTOP=yes ;;
  esac

  WIFI=no
  compgen -G '/sys/class/net/*/wireless' >/dev/null && WIFI=yes

  VIRT=$(systemd-detect-virt 2>/dev/null || true)

  # real disks only: the ISO itself shows up as loop/sr, plus fd/zram noise
  mapfile -t DISKS < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" && $1 !~ /\/(fd|zram)[0-9]/ {print $1}')
}

show_scan() {
  say "This machine"
  row Firmware "$FIRMWARE"
  row CPU "$CPU ($CORES threads)"
  row RAM "$RAM_GIB GiB"
  local line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    # "00:02.0 VGA compatible controller [0300]: Vendor Model [10de:2d04] (rev a1)" -> "Vendor Model"
    row GPU "$(sed -E 's/^.*\[030[028]\]: //; s/ \[[0-9a-f]{4}:[0-9a-f]{4}\]//; s/ \(rev .*\)$//' <<<"$line")"
  done <<<"$GPU_LINES"
  ((${#GPUS[@]} > 1)) && row "" "-> hybrid graphics (${GPUS[*]})"
  row Laptop "$LAPTOP"
  row Wi-Fi "$WIFI"
  [[ $VIRT != none && -n $VIRT ]] && row VM "$VIRT"

  local d
  for d in "${DISKS[@]}"; do
    row Disk "$d  $(lsblk -dno SIZE,MODEL "$d" | xargs)"
    lsblk -pno NAME,SIZE,FSTYPE,PARTTYPENAME,LABEL "$d" | tail -n +2 | sed 's/^/               /'
    lsblk -no FSTYPE,PARTTYPENAME "$d" | grep -qiE 'ntfs|microsoft' && row "" "-> Windows found on this disk"
  done
  ((${#DISKS[@]})) || warn "no disks found"
}


# ---------------------------------------------------------------- profile
# Weak machines get minimal suggested. The user decides.
choose_profile() {
  local suggest=full
  (( RAM_GIB < 6 || CORES < 4 )) && suggest=minimal
  local other=minimal
  [[ $suggest == minimal ]] && other=full
  if ask "Suggested profile: $suggest. Use it?"; then
    PROFILE=$suggest
  else
    PROFILE=$other
  fi
  say "Profile: $PROFILE"
}


preflight
scan
show_scan
choose_profile
say "Next stages (partitions, archinstall) are not written yet."

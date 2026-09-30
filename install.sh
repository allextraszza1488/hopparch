#!/bin/bash
# hopparch installer -- run as root from the Arch ISO, after:
#   1. Wi-Fi:       iwctl station wlan0 connect "<network>"
#   2. partitions:  cfdisk /dev/<disk>   (an EFI partition + one root partition)
# Stages: scan -> profile -> partitions -> archinstall (preset) -> our setup.
# The script never creates, deletes or wipes partitions; it formats only the
# ones you confirm.
set -euo pipefail

# archinstall versions this script was tested against; others get a warning
TESTED_ARCHINSTALL="4.4 4.5"
# config + credentials for archinstall; /tmp is RAM on the ISO
WORK=/tmp/hopparch
# where the new system clones hopparch from (override for testing)
REPO_URL=${HOPPARCH_REPO:-https://github.com/allextraszza1488/hopparch.git}

# ---------------------------------------------------------------- helpers
say()  { printf '\e[1m==> %s\e[0m\n' "$*"; }
warn() { printf '\e[33m!!  %s\e[0m\n' "$*"; }
die()  { printf '\e[31mxx  %s\e[0m\n' "$*"; exit 1; }
row()  { printf '  %-10s %s\n' "$1" "$2"; }
# All questions read the keyboard, not stdin, so `curl ... | bash` works.
# Y/n, Enter = yes
ask()    { local a; read -rp "$1 [Y/n] " a </dev/tty; [[ -z $a || $a == [Yy]* ]]; }
# y/N, Enter = no -- for anything destructive
ask_no() { local a; read -rp "$1 [y/N] " a </dev/tty; [[ $a == [Yy]* ]]; }
# free text with a default: value=$(ask_value "Hostname" hopparch)
ask_value() { local a; read -rp "$1 [$2]: " a </dev/tty; echo "${a:-$2}"; }
# hidden, typed twice: pw=$(ask_secret "Password")
ask_secret() {
  local a b
  while true; do
    read -rsp "$1: " a </dev/tty; echo >/dev/tty
    read -rsp "$1 again: " b </dev/tty; echo >/dev/tty
    [[ -n $a && $a == "$b" ]] && { echo "$a"; return; }
    echo "empty or not matching, again" >/dev/tty
  done
}


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


# ---------------------------------------------------------------- stage 4: partitions
# GPT type GUIDs: EFI system partition, and the two Linux types cfdisk offers
ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
LINUX_GUIDS="0fc63daf-8483-4772-8e79-3d69d8477de4 4f68bce3-e8cd-4db1-96e7-fbcaf984b709"

# pick one of several devices: pick "EFI partition" /dev/a /dev/b
pick() {
  local what=$1; shift
  (($# == 1)) && { echo "$1"; return; }
  local i=1 d
  for d in "$@"; do
    echo "  $i) $d  $(lsblk -dno SIZE,FSTYPE,PARTTYPENAME "$d" | xargs)" >/dev/tty
    i=$((i + 1))
  done
  while true; do
    read -rp "Which $what? [1-$#]: " i </dev/tty
    [[ $i =~ ^[0-9]+$ ]] && ((i >= 1 && i <= $#)) && { echo "${!i}"; return; }
  done
}

find_partitions() {
  [[ $FIRMWARE == UEFI* ]] || die "only UEFI machines are supported for now"
  local esps=() roots=() name type
  # fresh cfdisk changes need udev to finish before lsblk shows the types
  udevadm settle
  while read -r name type; do
    [[ $type == "$ESP_GUID" ]] && esps+=("$name")
    [[ " $LINUX_GUIDS " == *" $type "* ]] && roots+=("$name")
  done < <(lsblk -lpno NAME,PARTTYPE | awk 'NF == 2')

  ((${#esps[@]})) || die "no EFI partition -- make one in cfdisk (type 'EFI System', ~1G)"
  ((${#roots[@]})) || die "no Linux partition -- make one in cfdisk (type 'Linux filesystem')"
  ESP=$(pick "EFI partition" "${esps[@]}")
  ROOT=$(pick "root partition" "${roots[@]}")

  # An ESP that already holds boot files (Windows, another Linux) is kept as
  # it is and only mounted; an empty or unformatted one gets formatted.
  ESP_STATUS=modify
  if [[ $(lsblk -no FSTYPE "$ESP") == vfat ]]; then
    local m
    m=$(mktemp -d)
    if mount -o ro "$ESP" "$m" 2>/dev/null; then
      [[ -n $(ls -A "$m") ]] && ESP_STATUS=existing
      umount "$m"
    fi
    rmdir "$m"
  fi

  say "Partitions"
  if [[ $ESP_STATUS == existing ]]; then
    row EFI "$ESP  $(lsblk -dno SIZE "$ESP" | xargs)  -- has boot files, KEPT (only mounted at /boot)"
    local mib=$(( $(cat "/sys/class/block/${ESP#/dev/}/size") / 2048 ))
    ((mib >= 400)) || warn "this EFI partition is only ${mib} MiB; kernels may not fit (Windows makes 100 MiB ones)"
  else
    row EFI "$ESP  $(lsblk -dno SIZE "$ESP" | xargs)  -- will be FORMATTED (FAT32, /boot)"
  fi
  row Root "$ROOT  $(lsblk -dno SIZE "$ROOT" | xargs)  -- will be FORMATTED (btrfs)"
  local old
  old=$(lsblk -no FSTYPE "$ROOT")
  [[ -n $old ]] && warn "$ROOT currently holds a $old filesystem -- everything on it will be erased"
  ask_no "Format as shown?" || die "stopped, nothing was changed"
}


# ---------------------------------------------------------------- stage 5: archinstall
# GPU driver packages. archinstall's Minimal profile ignores its own driver
# option, so the packages go in the package list.
gpu_packages() {
  local g
  for g in "${GPUS[@]}"; do
    case $g in
      nvidia) echo nvidia-open libva-nvidia-driver ;;
      amd)    echo mesa vulkan-radeon ;;
      intel)  echo mesa vulkan-intel intel-media-driver ;;
      *)      echo mesa ;;
    esac
  done | tr ' ' '\n' | sort -u | xargs
}

ask_install_settings() {
  say "Settings"
  HOSTNAME_=$(ask_value "Hostname" hopparch)
  TIMEZONE=$(ask_value "Timezone" Europe/Kyiv)
  [[ -f /usr/share/zoneinfo/$TIMEZONE ]] || die "unknown timezone: $TIMEZONE"
  USERNAME=$(ask_value "Username" "")
  [[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "username: lowercase letters, digits, _ and - only"
  USER_PW=$(ask_secret "Password for $USERNAME")
  ENCRYPT=no
  LUKS_PW=""
  if ask "Encrypt the root partition (password at every boot)?"; then
    ENCRYPT=yes
    LUKS_PW=$(ask_secret "Disk encryption password")
  fi
}

write_config() {
  mkdir -p "$WORK"
  chmod 700 "$WORK"
  ESP="$ESP" ESP_STATUS="$ESP_STATUS" ROOT="$ROOT" ENCRYPT="$ENCRYPT" \
  HOSTNAME_="$HOSTNAME_" TIMEZONE="$TIMEZONE" PACKAGES="git base-devel $(gpu_packages)" \
  python3 - >"$WORK/user_configuration.json" <<'EOF'
import json, os

def part(dev, obj_id, status, fs, mountpoint, options, flags, subvols):
    name = os.path.basename(dev)
    disk = os.path.basename(os.path.dirname(os.path.realpath(f"/sys/class/block/{name}")))
    lss = int(open(f"/sys/block/{disk}/queue/logical_block_size").read())
    ss = {"value": lss, "unit": "B"}
    # sysfs start/size are always in 512-byte units; bytes avoid 4K-sector mixups
    start = int(open(f"/sys/class/block/{name}/start").read()) * 512
    size = int(open(f"/sys/class/block/{name}/size").read()) * 512
    return "/dev/" + disk, {
        "obj_id": obj_id, "status": status, "type": "primary", "dev_path": dev,
        "start": {"value": start, "unit": "B", "sector_size": ss},
        "size": {"value": size, "unit": "B", "sector_size": ss},
        "fs_type": fs, "mountpoint": mountpoint, "mount_options": options,
        "flags": flags, "btrfs": subvols,
    }

e = os.environ
parts = [
    part(e["ESP"], "hopparch-efi", e["ESP_STATUS"], "fat32", "/boot", [], ["boot", "esp"], []),
    # snapshots are set up by setup.sh, not archinstall (its preset takes hourly ones)
    part(e["ROOT"], "hopparch-root", "modify", "btrfs", None, ["compress=zstd"], [], [
        {"name": "@", "mountpoint": "/"},
        {"name": "@home", "mountpoint": "/home"},
        {"name": "@log", "mountpoint": "/var/log"},
        {"name": "@pkg", "mountpoint": "/var/cache/pacman/pkg"},
    ]),
]
# ESP and root may sit on different disks: one entry per disk, never wiped
devices = {}
for disk, p in parts:
    devices.setdefault(disk, []).append(p)

disk_config = {
    "config_type": "manual_partitioning",
    "device_modifications": [{"device": d, "wipe": False, "partitions": p} for d, p in devices.items()],
}
if e["ENCRYPT"] == "yes":
    disk_config["disk_encryption"] = {"encryption_type": "luks", "partitions": ["hopparch-root"], "lvm_volumes": []}

print(json.dumps({
    "archinstall-language": "English",
    "script": "guided",
    "disk_config": disk_config,
    # removable=false: don't overwrite the fallback bootloader other OSes use
    "bootloader_config": {"bootloader": "Grub", "uki": False, "removable": False},
    "kernels": ["linux"],
    "app_config": {"audio_config": {"audio": "pipewire"}},
    "network_config": {"type": "nm"},
    "profile_config": {"profile": {"main": "Minimal"}, "gfx_driver": None, "greeter": None},
    "locale_config": {"kb_layout": "us", "sys_lang": "en_US.UTF-8", "sys_enc": "UTF-8", "console_font": "default8x16"},
    "timezone": e["TIMEZONE"],
    "ntp": True,
    "hostname": e["HOSTNAME_"],
    "swap": {"enabled": True, "algorithm": "zstd"},
    "pacman_config": {"parallel_downloads": 5, "color": True},
    "packages": e["PACKAGES"].split(),
    "services": [],
    "custom_commands": [],
}, indent=2))
EOF

  # Passwords live only in this file, in RAM, and it is shredded after the
  # install. Never run archinstall with --debug: it logs credentials.
  local hash
  hash=$(openssl passwd -6 -stdin <<<"$USER_PW")
  USERNAME="$USERNAME" HASH="$hash" LUKS_PW="$LUKS_PW" \
  python3 - >"$WORK/creds.json" <<'EOF'
import json, os
e = os.environ
creds = {"users": [{"username": e["USERNAME"], "enc_password": e["HASH"], "sudo": True, "groups": []}]}
if e["LUKS_PW"]:
    creds["encryption_password"] = e["LUKS_PW"]
print(json.dumps(creds))
EOF
  chmod 600 "$WORK/creds.json"
  # gone however the script ends, even on Ctrl+C
  trap 'shred -u "$WORK/creds.json" 2>/dev/null || true' EXIT
  unset USER_PW LUKS_PW
}

run_archinstall() {
  say "Starting archinstall: check the settings, then choose Install."
  say "When it says 'Installation completed', choose 'Exit archinstall' (not Reboot) -- the desktop setup runs after that."
  archinstall --config "$WORK/user_configuration.json" --creds "$WORK/creds.json" || true
}


# ---------------------------------------------------------------- stage 6: our setup
# Clone hopparch into the new user's ~/hopparch and run setup.sh inside the new
# system. Later updates: cd ~/hopparch && git pull && sudo ./setup.sh
run_setup() {
  # archinstall writes /etc/fstab as its very last step: no root entry there =
  # it stopped or failed partway, and setup must not run on a half-made system
  grep -qE '^[^#].*[[:space:]]/[[:space:]]' /mnt/etc/fstab 2>/dev/null \
    || die "archinstall did not finish (no complete /mnt/etc/fstab) -- nothing else was done"
  say "Getting hopparch into ~/hopparch"
  arch-chroot /mnt runuser -u "$USERNAME" -- git clone -q "$REPO_URL" "/home/$USERNAME/hopparch"
  arch-chroot /mnt "/home/$USERNAME/hopparch/setup.sh" "$USERNAME"
}


preflight
scan
show_scan
choose_profile
find_partitions
ask_install_settings
write_config
run_archinstall
run_setup
say "All done. Reboot, unlock the disk, log in, type: start-hyprland"

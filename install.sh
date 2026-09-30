#!/bin/bash
# hopparch installer -- run as root from the Arch ISO, after:
#   1. Wi-Fi:       iwctl station wlan0 connect "<network>"
#   2. partitions:  cfdisk /dev/<disk>   (an EFI partition + one root partition)
# Stages: scan -> profile -> partitions -> settings -> one summary + y/N ->
# archinstall (no questions) -> our setup.
# The script never creates, deletes or wipes partitions; it formats only the
# ones you confirm.
#   bash install.sh            ask a few things, confirm once, install
#   bash install.sh --review   also open archinstall's menu before it installs
set -euo pipefail

REVIEW=no
for arg in "$@"; do
  case $arg in
    --review) REVIEW=yes ;;
    *) echo "usage: bash install.sh [--review]"; exit 1 ;;
  esac
done

# archinstall versions this script was tested against; others get a warning
TESTED_ARCHINSTALL="4.4 4.5"
# config + credentials for archinstall; /tmp is RAM on the ISO
WORK=/tmp/hopparch
# where the new system clones hopparch from (override for testing)
REPO_URL=${HOPPARCH_REPO:-https://github.com/allextraszza1488/hopparch.git}
# which branch the new system gets (override for testing: HOPPARCH_BRANCH=next)
REPO_BRANCH=${HOPPARCH_BRANCH:-main}

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
  # before any question: BIOS machines would only find out at the partitions
  [[ -d /sys/firmware/efi ]] || die "only UEFI machines are supported for now (this one booted in BIOS mode)"
  ping -c1 -W3 archlinux.org >/dev/null 2>&1 \
    || die "no internet -- connect first: iwctl station wlan0 connect \"<network>\""
  # the newest archinstall, not the one frozen into the ISO -- but only while
  # the repos have the ISO's Python: archinstall's python dependency has no
  # version, so after a Python update it would land in a site-packages the
  # ISO's Python never reads, and not start at all
  say "Updating archinstall to the latest version"
  if ! pacman -Sy >/dev/null 2>&1; then
    warn "could not reach the package repos; using the ISO's archinstall"
  elif [[ $(pacman -Si python | awk '$1 == "Version" {print $3}') != "$(pacman -Q python | awk '{print $2}')" ]]; then
    warn "the repos moved to a newer Python than this ISO's: keeping the ISO's archinstall (a newer ISO gets the newest)"
  else
    pacman -S --needed --noconfirm archinstall >/dev/null 2>&1 || warn "could not update archinstall; using the ISO's version"
  fi
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

  # nvidia-open drives Turing and newer only: PCI ids 1e00 and up (pci.ids;
  # NVIDIA's open-gpu-kernel-modules list starts at 1e02). Arch has no driver
  # for older NVIDIA cards any more (legacy ones are AUR-only): those get the
  # open nouveau driver, unless a newer NVIDIA card is also present.
  NVIDIA_DRIVER=""
  local id
  NVIDIA_MIXED=no
  while read -r id; do
    if ((16#$id >= 16#1e00)); then NVIDIA_DRIVER=open; else NVIDIA_DRIVER=${NVIDIA_DRIVER:-nouveau}; NVIDIA_MIXED=old; fi
  done < <(grep -o '\[10de:[0-9a-f]\{4\}\]' <<<"$GPU_LINES" | cut -c7-10)

  # the GPU Hyprland will draw on: the one with a laptop's built-in panel,
  # else the firmware's boot GPU (same rule as Hyprland's aquamarine)
  SCREEN_GPU=""
  local f vendor=""
  for f in /sys/class/drm/card*-{eDP,LVDS,DSI}-*/status; do
    [[ $(cat "$f" 2>/dev/null) == connected ]] || continue
    vendor=$(cat "${f%%-*}/device/vendor"); break
  done
  if [[ -z $vendor ]]; then
    for f in /sys/bus/pci/devices/*/boot_vga; do
      [[ $(cat "$f" 2>/dev/null) == 1 ]] && vendor=$(cat "${f%/boot_vga}/vendor")
    done
  fi
  case $vendor in 0x10de) SCREEN_GPU=nvidia ;; 0x1002) SCREEN_GPU=amd ;; 0x8086) SCREEN_GPU=intel ;; esac

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
  ((${#GPUS[@]} > 1)) && row "" "-> hybrid graphics (${GPUS[*]}), screen on: ${SCREEN_GPU:-unknown}"
  if [[ $NVIDIA_DRIVER == nouveau ]]; then
    row "" "-> NVIDIA older than GTX 16xx/RTX: open nouveau driver. The desktop works; games"
    row "" "   are very slow (GTX 9xx/10xx can't clock up). NVIDIA's own driver for them is AUR-only"
    row "" "   (nvidia-580xx-dkms, Kepler: nvidia-470xx-dkms): install it later if you need it"
  elif [[ $NVIDIA_MIXED == old ]]; then
    row "" "-> the older NVIDIA card gets no driver (nvidia-open only drives GTX 16xx/RTX and newer)"
  fi
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

  # optional: /home on a partition of its own (one you made in cfdisk).
  # Always shown by name, even as the only choice: it will be formatted.
  HOME_PART=""
  local rest=() p
  for p in "${roots[@]}"; do [[ $p != "$ROOT" ]] && rest+=("$p"); done
  if ((${#rest[@]})) && ask_no "Separate /home partition?"; then
    if ((${#rest[@]} == 1)); then
      row Home "${rest[0]}  $(lsblk -dno SIZE,FSTYPE,PARTTYPENAME "${rest[0]}" | xargs)" >/dev/tty
      ask_no "Use ${rest[0]} as /home (it gets formatted)?" && HOME_PART=${rest[0]}
    else
      HOME_PART=$(pick "/home partition" "${rest[@]}")
    fi
  fi

  # The EFI partition is /boot: kernels need room (Windows makes 100 MiB ones)
  local mib=$(( $(cat "/sys/class/block/${ESP#/dev/}/size") / 2048 ))
  ((mib >= 400)) || die "the EFI partition $ESP is only ${mib} MiB, kernels won't fit: make a new one of ~1G in cfdisk and pick that -- nothing was changed"

  # What is on the chosen EFI partition decides what happens to it:
  #  - empty or not FAT: formatted
  #  - Windows' boot files: kept, only mounted at /boot
  #  - an earlier hopparch attempt on this same root (its grub.cfg names the
  #    root partition): those files are removed after the final yes, the
  #    rest is kept
  #  - another Linux's kernels or boot loader: refused. Two Linux systems
  #    can't share /boot (same kernel file names), and archinstall's GRUB
  #    would overwrite the other one's
  #  - FAT that won't mount: refused, it could be Windows' with errors
  ESP_STATUS=modify
  ESP_CLEAN=()
  if [[ $(lsblk -no FSTYPE "$ESP") == vfat ]]; then
    local m linux root_uuid
    m=$(mktemp -d)
    mount -o ro "$ESP" "$m" 2>/dev/null \
      || { rmdir "$m"; die "can't read the EFI partition $ESP (FAT errors?): check it, or make a new one -- nothing was changed"; }
    # a Linux's kernels, initramfs, microcode, GRUB/systemd-boot/shim
    linux=$(cd "$m" && find . -maxdepth 3 \( -iname 'vmlinuz-*' -o -iname 'initramfs-*' -o -iname '*-ucode.img' \
                -o -ipath './grub' -o -ipath './loader' -o -ipath './efi/*/grubx64.efi' -o -ipath './efi/*/shimx64.efi' \
                -o -ipath './efi/*/systemd-bootx64.efi' \) ! -ipath './efi/boot/*' ! -ipath './grub/*' ! -ipath './loader/*' | sort)
    if [[ -n $linux ]]; then
      root_uuid=$(lsblk -no UUID "$ROOT" | head -1)
      if [[ -n $root_uuid && -f $m/grub/grub.cfg ]] && grep -q -- "$root_uuid" "$m/grub/grub.cfg" \
         && ! grep -vixE './(vmlinuz-linux|initramfs-linux(-fallback)?\.img|(intel|amd)-ucode\.img|grub|EFI/GRUB/grubx64\.efi)' <<<"$linux" | grep -q .; then
        ESP_CLEAN=(vmlinuz-linux initramfs-linux.img initramfs-linux-fallback.img intel-ucode.img amd-ucode.img grub EFI/GRUB)
      else
        umount "$m"; rmdir "$m"
        while read -r p; do echo "    ${p#./}"; done <<<"$linux" >/dev/tty
        die "$ESP holds another Linux's boot files (above): hopparch needs an EFI partition of its own (~1G, see 'Next to another system' in the README) -- nothing was changed"
      fi
    fi
    # anything else on it (Windows' files, vendor tools) is someone else's: kept
    local e d
    shopt -s nocasematch dotglob nullglob
    for e in "$m"/*; do
      case ${e##*/} in
        vmlinuz-linux|initramfs-linux.img|initramfs-linux-fallback.img|intel-ucode.img|amd-ucode.img|grub)
          ((${#ESP_CLEAN[@]})) && continue ;;
        efi)
          if ((${#ESP_CLEAN[@]})); then
            for d in "$e"/*; do [[ ${d##*/} == grub ]] || ESP_STATUS=existing; done
            continue
          fi ;;
      esac
      ESP_STATUS=existing
    done
    shopt -u nocasematch dotglob nullglob
    umount "$m"
    rmdir "$m"
  fi

  # what happens to each partition; shown and confirmed in the final summary
  if [[ $ESP_STATUS == existing ]]; then
    ESP_NOTE="has boot files: KEPT, only mounted at /boot"
  else
    ESP_NOTE="will be FORMATTED (FAT32, /boot)"
  fi
  ((${#ESP_CLEAN[@]})) && ESP_NOTE+=" -- the earlier hopparch attempt's kernels and GRUB on it are removed first"
  ROOT_NOTE="will be FORMATTED (btrfs)"
  local old
  old=$(lsblk -no FSTYPE "$ROOT")
  if [[ -n $old ]]; then ROOT_NOTE+=" -- its $old data will be erased"; fi
  if [[ -n $HOME_PART ]]; then
    HOME_NOTE="will be FORMATTED (btrfs, /home)"
    old=$(lsblk -no FSTYPE "$HOME_PART")
    if [[ -n $old ]]; then HOME_NOTE+=" -- its $old data will be erased"; fi
  fi
}


# ---------------------------------------------------------------- stage 5: archinstall
# GPU driver packages. archinstall's Minimal profile ignores its own driver
# option, so the packages go in the package list.
gpu_packages() {
  local g
  for g in "${GPUS[@]}"; do
    case $g in
      nvidia)
        if [[ $NVIDIA_DRIVER == open ]]; then
          echo nvidia-open libva-nvidia-driver
          # hybrid drawing on the iGPU: prime-run starts a game on NVIDIA
          if ((${#GPUS[@]} > 1)) && [[ -n $SCREEN_GPU && $SCREEN_GPU != nvidia ]]; then echo nvidia-prime; fi
        else
          echo mesa vulkan-nouveau
        fi ;;
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

# an earlier attempt's kernels/GRUB on a kept EFI partition, only after the
# final yes (find_partitions named them)
clean_esp() {
  ((${#ESP_CLEAN[@]})) || return 0
  local m f
  m=$(mktemp -d)
  mount "$ESP" "$m"
  for f in "${ESP_CLEAN[@]}"; do rm -rf "${m:?}/$f"; done
  umount "$m"
  rmdir "$m"
}

# everything in one place, one yes -- after this nothing asks anymore
confirm_install() {
  say "Ready to install"
  row EFI "$ESP  $(lsblk -dno SIZE "$ESP" | xargs)  $ESP_NOTE"
  row Root "$ROOT  $(lsblk -dno SIZE "$ROOT" | xargs)  $ROOT_NOTE"
  [[ -n $HOME_PART ]] && row Home "$HOME_PART  $(lsblk -dno SIZE "$HOME_PART" | xargs)  $HOME_NOTE"
  if [[ -n $HOME_PART && $ENCRYPT == yes ]]; then row Encrypted "yes: root + /home, one password (/home opens with a key file inside root)"
  else row Encrypted "$ENCRYPT"; fi
  row Hostname "$HOSTNAME_"
  row Timezone "$TIMEZONE"
  row User "$USERNAME (admin through sudo; root stays locked)"
  row Profile "$PROFILE"
  row Drivers "$(gpu_packages)"
  row Boot "GRUB, snapshots listed in its menu; other systems too (Windows, another Linux's EFI partition)"
  # grub-install drops every firmware boot entry with "grub" anywhere in its
  # line (name or path): another Linux's entry goes, hopparch's comes
  if efibootmgr 2>/dev/null | grep -qi '^Boot[0-9A-F]\{4\}.*grub'; then
    row Firmware "boot entries mentioning GRUB (another Linux's?) are replaced by hopparch's; that system stays in hopparch's menu"
  fi
  ask_no "Install now? The partitions above get formatted" || die "stopped, nothing was changed"
}

write_config() {
  mkdir -p "$WORK"
  chmod 700 "$WORK"
  ESP="$ESP" ESP_STATUS="$ESP_STATUS" ROOT="$ROOT" ENCRYPT="$ENCRYPT" \
  HOME_PART="$HOME_PART" HOSTNAME_="$HOSTNAME_" TIMEZONE="$TIMEZONE" PACKAGES="git base-devel $(gpu_packages)" \
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
home = e["HOME_PART"]
root_subvols = [{"name": "@", "mountpoint": "/"}]
# @home in root, unless /home has a partition of its own
if not home:
    root_subvols.append({"name": "@home", "mountpoint": "/home"})
root_subvols += [
    {"name": "@log", "mountpoint": "/var/log"},
    {"name": "@pkg", "mountpoint": "/var/cache/pacman/pkg"},
]
parts = [
    part(e["ESP"], "hopparch-efi", e["ESP_STATUS"], "fat32", "/boot", [], ["boot", "esp"], []),
    # snapshots are set up by setup.sh, not archinstall (its preset takes hourly ones)
    part(e["ROOT"], "hopparch-root", "modify", "btrfs", None, ["compress=zstd"], [], root_subvols),
]
if home:
    parts.append(part(home, "hopparch-home", "modify", "btrfs", None, ["compress=zstd"], [],
                      [{"name": "@home", "mountpoint": "/home"}]))
# ESP and root may sit on different disks: one entry per disk, never wiped
devices = {}
for disk, p in parts:
    devices.setdefault(disk, []).append(p)

disk_config = {
    "config_type": "manual_partitioning",
    "device_modifications": [{"device": d, "wipe": False, "partitions": p} for d, p in devices.items()],
}
if e["ENCRYPT"] == "yes":
    # with /home encrypted too, archinstall puts a key file for it inside the
    # encrypted root (/etc/cryptsetup-keys.d + crypttab): one password at boot
    disk_config["disk_encryption"] = {"encryption_type": "luks", "lvm_volumes": [],
                                      "partitions": ["hopparch-root"] + (["hopparch-home"] if home else [])}

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
  # its exit code is only shown: whether the install is complete is decided
  # by run_setup's fstab check (a config archinstall rejects still exits 0)
  local rc=0
  if [[ $REVIEW == yes ]]; then
    say "archinstall's menu: check the settings, then choose Install."
    say "When it says 'Installation completed', choose 'Exit archinstall' (not Reboot) -- the desktop setup runs after that."
    archinstall --config "$WORK/user_configuration.json" --creds "$WORK/creds.json" || rc=$?
  else
    say "Installing the base system (archinstall, no questions)"
    archinstall --config "$WORK/user_configuration.json" --creds "$WORK/creds.json" --silent || rc=$?
  fi
  ((rc == 0)) || warn "archinstall exited with code $rc (its log: /var/log/archinstall/install.log)"
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
  arch-chroot /mnt runuser -u "$USERNAME" -- git clone -q -b "$REPO_BRANCH" "$REPO_URL" "/home/$USERNAME/hopparch"
  arch-chroot /mnt "/home/$USERNAME/hopparch/setup.sh" --profile="$PROFILE" "$USERNAME"
}


preflight
scan
show_scan
choose_profile
find_partitions
ask_install_settings
confirm_install
clean_esp
write_config
run_archinstall
run_setup
say "All done. Reboot, unlock the disk, then log in on the login screen."

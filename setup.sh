#!/bin/bash
# hopparch setup -- installs the packages, copies config/ into one user's
# ~/.config and system/ into /.
#   first install:  install.sh runs it inside the new system
#   any time later: cd ~/hopparch && git pull && sudo ./setup.sh
#   switch profile: sudo ./setup.sh --profile=minimal   (or full; remembered
#                   in ~/.config/hopparch/profile)
# A config file you changed yourself is kept as <file>.bak-<date> before being
# replaced; files you never touched are just updated.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

say() { printf '\e[1m==> %s\e[0m\n' "$*"; }
warn() { printf '\e[33m!!  %s\e[0m\n' "$*"; }
die() { printf '\e[31mxx  %s\e[0m\n' "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "run it with sudo: sudo ./setup.sh"

# A booted system, not install.sh's chroot. systemd running isn't enough:
# arch-chroot passes the ISO's /run through, and anything "started now" from
# the chroot (like the firewall) would hit the ISO's own kernel instead.
booted() { [[ -d /run/systemd/system ]] && ! systemd-detect-virt --quiet --chroot; }

PROFILE_ARG=""
args=()
for a in "$@"; do
  case $a in --profile=*) PROFILE_ARG=${a#--profile=} ;; *) args+=("$a") ;; esac
done
# the user whose config this is: argument (from install.sh) or whoever ran sudo
USER_=${args[0]:-${SUDO_USER:-}}
[[ -n $USER_ && $USER_ != root ]] || die "usage: sudo ./setup.sh [--profile=full|minimal] [user]"
HOME_=$(getent passwd "$USER_" | cut -d: -f6)
GROUP_=$(id -gn "$USER_")
# minimal = plain and light for old machines; full = minimal + gaming, coding
# tools, media, nicer look. Given now, else what was used last time, else full.
PROFILE_FILE="$HOME_/.config/hopparch/profile"
PROFILE=${PROFILE_ARG:-$(cat "$PROFILE_FILE" 2>/dev/null || echo full)}
[[ $PROFILE == full || $PROFILE == minimal ]] || die "profile must be full or minimal, not '$PROFILE'"
# copies of what setup.sh installed last time, to tell your edits from ours
STATE="$HOME_/.local/state/hopparch/installed"

# launcher entries hidden from SUPER+D (and listed in "Stashed apps")
STASHED=$(grep -v -e '^#' -e '^\s*$' config/hopparch/stashed.list)


packages() {
  say "Packages"
  pacman -S --needed --noconfirm \
    hyprland xdg-desktop-portal-hyprland waybar kitty fuzzel \
    fish eza zoxide fzf bat glow neovim btop firefox thunar \
    greetd greetd-tuigreet wtype \
    brightnessctl power-profiles-daemon python-gobject fastfetch \
    grim slurp wl-clipboard cliphist mako libnotify hyprlock hypridle hyprpaper \
    ttf-jetbrains-mono-nerd noto-fonts adwaita-fonts \
    jq pacman-contrib reflector \
    gocryptfs rtkit wireless-regdb
}

# Mullvad on every profile (minimal and full). The package only prints
# "systemctl enable"; it does not enable the daemon, and the unit looks for
# ca.crt in /opt/Mullvad VPN/resources/ while the file ships in
# /usr/lib/mullvad-vpn/. Without both, the app cannot reach the daemon.
# Connect only when an account is already set. A fresh install has none,
# and connecting with no account takes the network down. No lockdown, no
# location hop.
mullvad_vpn() {
  say "Mullvad VPN"
  pacman -S --needed --noconfirm mullvad-vpn
  mkdir -p "/opt/Mullvad VPN/resources"
  ln -sfn /usr/lib/mullvad-vpn/ca.crt "/opt/Mullvad VPN/resources/ca.crt"
  systemctl enable mullvad-daemon.service
  if booted; then
    systemctl start mullvad-daemon.service
    # shortcut: exit 0 from `account get` means logged in, re-check if the CLI changes
    if mullvad account get >/dev/null 2>&1; then
      mullvad auto-connect set on && mullvad connect \
        || warn "Mullvad: account is set, but it did not connect"
    fi
  fi
}

# The on-screen keyboard (mouse bar's kbd button) comes from the AUR
# (wvkbd-deskintl, the desktop layout): built as the user, since makepkg
# refuses root. Rebuilt only when the AUR version differs from the installed
# one (pacman -Syu never updates AUR packages). A failed build (no internet?)
# only costs the keyboard, so setup goes on.
AUR=${HOPPARCH_AUR:-https://aur.archlinux.org}
# empty = always the latest AUR version (owner's choice); a commit id pins it
WVKBD_AUR_COMMIT=""
onscreen_keyboard() {
  local tmp ver deps
  tmp=$(mktemp -d)
  chown "$USER_" "$tmp"
  if ! runuser -u "$USER_" -- env HOME="$HOME_" git clone -q "$AUR/wvkbd-deskintl.git" "$tmp/wvkbd" ||
     { [[ -n $WVKBD_AUR_COMMIT ]] && ! runuser -u "$USER_" -- env HOME="$HOME_" git -C "$tmp/wvkbd" checkout -q "$WVKBD_AUR_COMMIT"; }; then
    warn "could not get wvkbd from the AUR: no on-screen keyboard until the next ./setup.sh"
    rm -rf "$tmp"; return 0
  fi
  ver=$(awk '$1 == "pkgver" {v = $3} $1 == "pkgrel" {r = $3} END {print v "-" r}' "$tmp/wvkbd/.SRCINFO")
  if [[ $(pacman -Q wvkbd-deskintl 2>/dev/null) == "wvkbd-deskintl $ver" ]]; then
    rm -rf "$tmp"; return 0
  fi
  say "On-screen keyboard: building wvkbd-deskintl $ver from the AUR"
  # what it needs to build and run, as the package itself lists it
  deps=$(awk '$1 == "depends" || $1 == "makedepends" {print $3}' "$tmp/wvkbd/.SRCINFO" | sed 's/[<>=].*//')
  # shellcheck disable=SC2086 # one word per package
  pacman -S --needed --noconfirm base-devel $deps >/dev/null
  # the package lands in $tmp whatever the user's makepkg.conf says
  if (cd "$tmp/wvkbd" && runuser -u "$USER_" -- env HOME="$HOME_" PKGDEST="$tmp" PKGEXT=.pkg.tar.zst makepkg --noconfirm); then
    pacman -U --noconfirm "$tmp"/wvkbd-deskintl-"$ver"-*.pkg.tar.zst
  else
    warn "building wvkbd failed (see above): no on-screen keyboard until the next ./setup.sh"
  fi
  rm -rf "$tmp"
}

# The pieces only the full profile has: gaming, coding tools, media.
# Steam needs the 32-bit repo (multilib), which Arch ships switched off.
gpu_vendors() {
  local d
  for d in /sys/bus/pci/devices/*; do
    [[ $(cat "$d/class" 2>/dev/null) == 0x03* ]] || continue
    case $(cat "$d/vendor") in 0x10de) echo nvidia ;; 0x1002) echo amd ;; 0x8086) echo intel ;; esac
  done | sort -u
}

full_extras() {
  say "Full profile: gaming, coding tools, media"
  if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
    pacman -Sy >/dev/null
  fi
  local lib32=(lib32-mesa lib32-vulkan-icd-loader) v known=no
  for v in $(gpu_vendors); do
    case $v in
      # the 32-bit half of whatever install.sh chose: NVIDIA's driver, or
      # nouveau for cards too old for it (nvidia-utils would block nouveau)
      nvidia) known=yes; if pacman -Q nvidia-utils >/dev/null 2>&1; then lib32+=(lib32-nvidia-utils); else lib32+=(lib32-vulkan-nouveau); fi ;;
      amd)    known=yes; lib32+=(lib32-vulkan-radeon) ;;
      intel)  known=yes; lib32+=(lib32-vulkan-intel) ;;
    esac
  done
  # no known GPU (a VM, ...): Mesa's software Vulkan. Without a named driver,
  # Steam's "some Vulkan driver" dependency makes pacman pick NVIDIA's.
  [[ $known == yes ]] || lib32+=(vulkan-swrast lib32-vulkan-swrast)
  pacman -S --needed --noconfirm \
    steam gamemode lib32-gamemode vulkan-icd-loader "${lib32[@]}" \
    clang lua-language-server arduino-language-server arduino-cli gdb \
    tree-sitter-bash tree-sitter-python \
    mpv imv ffmpegthumbnailer tumbler \
    nodejs npm
  # gamemode may raise a game's priority only for members of this group
  usermod -aG gamemode "$USER_"
}

# config/ with the profile's own files (profiles/<name>/config/) laid over it,
# then copied into ~/.config
copy_config() {
  say "Config -> $HOME_/.config ($PROFILE profile)"
  local tree
  tree=$(mktemp -d)
  cp -a config/. "$tree"/
  if [[ -d profiles/$PROFILE/config ]]; then cp -a "profiles/$PROFILE/config/." "$tree"/; fi
  copy_tree "$tree"
  rm -rf "$tree"
}

copy_tree() {
  local tree=$1 src rel dst mode
  while IFS= read -r -d '' src; do
    rel=${src#"$tree"/}
    dst="$HOME_/.config/$rel"
    runuser -u "$USER_" -- mkdir -p "$(dirname "$dst")" "$(dirname "$STATE/$rel")"
    # already up to date: don't touch it (apps watching it would reload)
    if ! cmp -s "$src" "$dst" 2>/dev/null; then
      # differs from what we installed last time = your edit, keep a copy
      if [[ -f $dst ]] && ! cmp -s "$dst" "$STATE/$rel" 2>/dev/null; then
        local bak="$dst.bak-$(date +%F-%H%M%S)"
        cp -p "$dst" "$bak"
        echo "  kept your version: $bak"
      fi
      mode=644
      [[ -x $src ]] && mode=755
      # write next to it, then rename over it: the file is never missing, even
      # for a split second (Hyprland reloads the moment its config changes)
      install -m "$mode" -o "$USER_" -g "$GROUP_" "$src" "$dst.hopparch-new"
      mv -f "$dst.hopparch-new" "$dst"
    fi
    # remember what we installed, to recognise your edits next time
    install -m 644 -o "$USER_" -g "$GROUP_" "$src" "$STATE/$rel"
  done < <(find "$tree" -type f -print0)
  # which profile this is, for the next ./setup.sh
  echo "$PROFILE" | runuser -u "$USER_" -- tee "$PROFILE_FILE" >/dev/null

  # files we installed earlier that are gone from the repo: remove them too,
  # unless you edited them -- no leftovers piling up in ~/.config
  [[ -d $STATE ]] || return 0
  local old
  while IFS= read -r -d '' old; do
    rel=${old#"$STATE"/}
    [[ -e $tree/$rel ]] && continue
    dst="$HOME_/.config/$rel"
    if [[ ! -e $dst ]] || cmp -s "$old" "$dst"; then
      rm -f "$dst"
      echo "  removed (no longer in hopparch): $dst"
    else
      echo "  no longer in hopparch, kept because you edited it: $dst"
    fi
    rm -f "$old"
  done < <(find "$STATE" -type f -print0)
}

# a same-named entry in ~/.local/share/applications overrides the system one
stash_apps() {
  say "Stashing launcher clutter"
  local dir="$HOME_/.local/share/applications" app
  runuser -u "$USER_" -- mkdir -p "$dir"
  # drop our old overrides first, so names removed from the list come back
  # (|| true: grep finding nothing is fine and must not stop setup.sh)
  grep -l -x '# hopparch-stash' "$dir"/*.desktop 2>/dev/null | xargs -r rm -f || true
  for app in $STASHED; do
    printf '[Desktop Entry]\n# hopparch-stash\nType=Application\nName=%s\nNoDisplay=true\nHidden=true\n' "$app" \
      | runuser -u "$USER_" -- tee "$dir/$app.desktop" >/dev/null
  done
  # the one entry that opens the stashed list
  printf '[Desktop Entry]\n# hopparch-stash\nType=Application\nName=Stashed apps\nIcon=folder\nExec=%s\n' \
    "$HOME_/.config/scripts/stashed.sh" \
    | runuser -u "$USER_" -- tee "$dir/hopparch-stashed.desktop" >/dev/null
}

# "Wi-Fi", "Bluetooth"... entries in SUPER+D, all opening settings.sh. Only for
# hardware this machine has, so a desktop gets no Battery entry. Regenerated
# on every run, like the stashed apps.
settings_entries() {
  say "Settings entries in the launcher"
  local dir="$HOME_/.local/share/applications" entry name arg have
  runuser -u "$USER_" -- mkdir -p "$dir"
  grep -l -x '# hopparch-settings' "$dir"/*.desktop 2>/dev/null | xargs -r rm -f || true
  # "/" = always (a package we install); the rest need the hardware
  for entry in "Wi-Fi:wifi:/sys/class/net/*/wireless" "Bluetooth:bluetooth:/sys/class/bluetooth/hci*" \
               "Brightness:brightness:/sys/class/backlight/*" "Power mode:power:/" \
               "Battery:battery:/sys/class/power_supply/BAT*" "Specs:specs:/"; do
    IFS=: read -r name arg have <<<"$entry"
    # shellcheck disable=SC2086  # $have is a glob on purpose
    compgen -G $have >/dev/null || continue
    printf '[Desktop Entry]\n# hopparch-settings\nType=Application\nName=%s\nIcon=preferences-system\nExec=%s %s\n' \
      "$name" "$HOME_/.config/scripts/settings.sh" "$arg" \
      | runuser -u "$USER_" -- tee "$dir/hopparch-settings-$arg.desktop" >/dev/null
  done
}

copy_system() {
  say "System files -> /"
  local src
  while IFS= read -r -d '' src; do
    install -D -m644 "$src" "/${src#system/}"
  done < <(find system -type f -print0)
}

services() {
  say "Shell + login screen"
  [[ $(getent passwd "$USER_" | cut -d: -f7) == /usr/bin/fish ]] || chsh -s /usr/bin/fish "$USER_"
  systemctl enable greetd.service
  # login screen: username already filled in, only the password is asked.
  # tuigreet --remember keeps this file up to date after each login.
  install -d -o greeter -g greeter /var/cache/tuigreet
  if [[ ! -s /var/cache/tuigreet/lastuser ]]; then
    echo "$USER_" >/var/cache/tuigreet/lastuser
    chown greeter:greeter /var/cache/tuigreet/lastuser
  fi

  # power modes (Settings > Power mode); bluetooth only where an adapter exists
  systemctl enable power-profiles-daemon.service
  if booted; then systemctl start power-profiles-daemon.service; fi
  # AMD laptops: if a power profile raises the advertised clock and leaves the
  # cap behind, reload the driver once at boot. Laptops only (the unit checks
  # for a battery too); no-op on Intel and when the cap is already at max.
  if [[ -f /etc/systemd/system/hopparch-cpu-cap.service ]]; then
    chmod 755 /usr/local/lib/hopparch/cpu-cap.sh
    if compgen -G '/sys/class/power_supply/BAT*' >/dev/null; then
      systemctl enable hopparch-cpu-cap.service
    else
      systemctl disable hopparch-cpu-cap.service 2>/dev/null || true
    fi
  fi
  # Bluetooth only where an adapter exists, and off until it is turned on in
  # Settings > Bluetooth: the adapter stays unpowered at every boot
  if compgen -G '/sys/class/bluetooth/hci*' >/dev/null; then
    pacman -S --needed --noconfirm bluez bluez-utils >/dev/null
    local bt=/etc/bluetooth/main.conf
    if grep -q '^#\?AutoEnable *=' "$bt"; then
      sed -i 's/^#\?AutoEnable *=.*/AutoEnable=false/' "$bt"
    else
      printf '\n[Policy]\nAutoEnable=false\n' >>"$bt"
    fi
    systemctl enable bluetooth.service
    if booted; then systemctl start bluetooth.service; fi
  fi
  return 0
}

# What older hopparch versions installed and this one doesn't: removed on the
# next ./setup.sh, so an updated machine ends up like a fresh install.
leftovers() {
  # the keyboard mouse: a root ydotoold service that could type and click
  # for any program of the user
  if [[ -f /etc/systemd/system/ydotoold.service ]]; then
    say "Removing the keyboard mouse (ydotoold)"
    systemctl disable --now ydotoold.service 2>/dev/null || true
    rm -f /etc/systemd/system/ydotoold.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  if pacman -Q ydotool >/dev/null 2>&1; then
    pacman -Rns --noconfirm ydotool >/dev/null || warn "could not remove ydotool"
  fi
  # the passwordless sudo rule for cpu-cap.sh: nothing gets root without a password
  rm -f /etc/sudoers.d/hopparch-cpu-cap
}

# A second kernel in the boot menu: if a new `linux` breaks the boot, pick
# linux-lts in GRUB. NVIDIA's open driver is prebuilt per kernel, so LTS gets
# its own. grub-mkconfig sorts linux-lts above linux; GRUB_TOP_LEVEL keeps
# linux the default entry (the menu is rebuilt in snapshots()).
lts_kernel() {
  say "Fallback kernel: linux-lts"
  pacman -S --needed --noconfirm linux-lts >/dev/null
  if pacman -Q nvidia-open >/dev/null 2>&1; then
    pacman -S --needed --noconfirm nvidia-open-lts >/dev/null
  fi
  if [[ -f /etc/default/grub ]] && ! grep -q '^GRUB_TOP_LEVEL=' /etc/default/grub; then
    echo 'GRUB_TOP_LEVEL="/boot/vmlinuz-linux"' >>/etc/default/grub
  fi
}

# Upkeep once a week, no daemons: old package files cleaned (paccache keeps
# the last 3 versions), mirror list refreshed (system/etc/xdg/reflector).
# Parallel builds come from system/etc/makepkg.conf.d.
upkeep() {
  say "Weekly upkeep: package cache, mirror list"
  systemctl enable paccache.timer reflector.timer
}

firewall() {
  say "Firewall: block everything incoming, allow outgoing"
  pacman -S --needed --noconfirm ufw >/dev/null
  sed -i -e 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' \
         -e 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
  sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
  systemctl enable ufw.service
  if booted; then ufw --force enable >/dev/null; fi
  return 0
}

# Snapshots of / before and after every pacman run, bootable from the GRUB
# menu. Only for btrfs + GRUB (what install.sh makes). /home is not included:
# rolling back the system never touches your files.
snapshots() {
  if [[ $(findmnt -no FSTYPE /) != btrfs || ! -d /boot/grub ]]; then
    say "Snapshots: skipped (needs btrfs + GRUB)"
    return 0
  fi
  say "Snapshots: before/after each update, in the boot menu"
  pacman -S --needed --noconfirm snapper snap-pac grub-btrfs >/dev/null

  if [[ ! -f /etc/snapper/configs/root ]]; then
    # --no-dbus: works inside install.sh's chroot too
    snapper --no-dbus -c root create-config /
  fi
  # no hourly snapshots; keep the last 10 (= 5 updates, before + after)
  snapper --no-dbus -c root set-config TIMELINE_CREATE=no NUMBER_LIMIT=10 NUMBER_LIMIT_IMPORTANT=5
  systemctl enable snapper-cleanup.timer

  # booting an old snapshot: it's read-only, this hook lays a RAM overlay on
  # top so the system can start normally
  if ! grep -q '^HOOKS=.*grub-btrfs-overlayfs' /etc/mkinitcpio.conf; then
    sed -i 's/^HOOKS=(\(.*\))/HOOKS=(\1 grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
    mkinitcpio -P >/dev/null
  fi

  # snap-pac snapshots every install. The menu has to list that snapshot,
  # or GRUB cannot boot it. grub-mkconfig walks every EFI entry, so this
  # hook is slow on purpose. "zzz" sorts after snap-pac's own hook.
  mkdir -p /etc/pacman.d/hooks
  cat >/etc/pacman.d/hooks/zzz-hopparch-grub-snapshots.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Adding the new snapshots to the boot menu (hopparch)
When = PostTransaction
Exec = /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
Depends = grub
EOF
  grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || die "grub-mkconfig failed (boot menu not updated)"
  return 0
}


# The FA506NC panel is drawn by amdgpu. The EC brightness device accepts a
# number and the picture does not change. amdgpu's automatic path uses AUX,
# which this panel also ignores. PWM (acpi_backlight=native amdgpu.backlight=0)
# is the path that moves the backlight. Only that machine: drop the old
# blacklist there, and rebuild the boot menu when those words are not in it.
# Other machines are left alone, including a blacklist they still need.
backlight_fix() {
  booted || return 0
  local conf=/etc/modprobe.d/hopparch-backlight.conf grub=/etc/default/grub product
  product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  if [[ $product == *FA506NC* && -f $grub ]]; then
    if [[ -f $conf ]] && grep -q 'nvidia_wmi_ec_backlight' "$conf"; then
      rm -f "$conf"
      say "Backlight: removed the EC driver blacklist"
    fi
    local token
    for token in acpi_backlight=native amdgpu.backlight=0; do
      grep -Fq "$token" "$grub" && continue
      sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 $token\"/" "$grub"
    done
    if ! grep -Fq 'acpi_backlight=native' /boot/grub/grub.cfg \
      || ! grep -Fq 'amdgpu.backlight=0' /boot/grub/grub.cfg; then
      grub-mkconfig -o /boot/grub/grub.cfg >/dev/null \
        && warn "Backlight: PWM mode is set. It starts working after the next reboot" \
        || warn "Backlight: could not update the boot menu"
    fi
    return 0
  fi
  [[ -d /sys/class/backlight/nvidia_wmi_ec_backlight ]] && return 0
  compgen -G '/sys/class/backlight/amdgpu_bl*' >/dev/null && return 0
  compgen -G '/sys/class/backlight/intel_backlight' >/dev/null && return 0
  compgen -G '/sys/bus/wmi/devices/603E9613-EF25-4338-A3D0-C46177516DB7*' >/dev/null || return 0
  modprobe nvidia_wmi_ec_backlight 2>/dev/null \
    && say "Backlight: EC driver loaded" \
    || warn "Backlight: EC driver did not load"
}

packages
mullvad_vpn
onscreen_keyboard
[[ $PROFILE == full ]] && full_extras
copy_config
stash_apps
settings_entries
copy_system
services
leftovers
lts_kernel
upkeep
firewall
snapshots
backlight_fix
say "Done. Log out and back in (or reboot): running apps keep the old config until then."

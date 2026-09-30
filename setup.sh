#!/bin/bash
# hopparch setup -- installs the packages, copies config/ into one user's
# ~/.config and system/ into /.
#   first install:  install.sh runs it inside the new system
#   any time later: cd ~/hopparch && git pull && sudo ./setup.sh
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
# the user whose config this is: argument (from install.sh) or whoever ran sudo
USER_=${1:-${SUDO_USER:-}}
[[ -n $USER_ && $USER_ != root ]] || die "usage: sudo ./setup.sh"
HOME_=$(getent passwd "$USER_" | cut -d: -f6)
GROUP_=$(id -gn "$USER_")
# copies of what setup.sh installed last time, to tell your edits from ours
STATE="$HOME_/.local/state/hopparch/installed"

# launcher entries hidden from SUPER+D (and listed in "Stashed apps")
STASHED=$(grep -v -e '^#' -e '^\s*$' config/hopparch/stashed.list)


packages() {
  say "Packages"
  pacman -S --needed --noconfirm \
    hyprland xdg-desktop-portal-hyprland waybar kitty fuzzel \
    fish eza zoxide fzf bat glow neovim btop firefox thunar \
    greetd greetd-tuigreet ydotool \
    bluez bluez-utils brightnessctl power-profiles-daemon fastfetch \
    grim slurp wl-clipboard cliphist mako libnotify hyprlock hypridle \
    ttf-jetbrains-mono-nerd noto-fonts \
    jq pacman-contrib reflector
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

copy_config() {
  say "Config -> $HOME_/.config"
  local src rel dst mode
  while IFS= read -r -d '' src; do
    rel=${src#config/}
    dst="$HOME_/.config/$rel"
    runuser -u "$USER_" -- mkdir -p "$(dirname "$dst")" "$(dirname "$STATE/$rel")"
    # already up to date: don't touch it (apps watching it would reload)
    if ! cmp -s "$src" "$dst" 2>/dev/null; then
      # differs from what we installed last time = your edit, keep a copy
      if [[ -f $dst ]] && ! cmp -s "$dst" "$STATE/$rel" 2>/dev/null; then
        cp -p "$dst" "$dst.bak-$(date +%F-%H%M%S)"
        echo "  kept your version: $dst.bak-*"
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
  done < <(find config -type f -print0)

  # files we installed earlier that are gone from the repo: remove them too,
  # unless you edited them -- no leftovers piling up in ~/.config
  [[ -d $STATE ]] || return 0
  local old
  while IFS= read -r -d '' old; do
    rel=${old#"$STATE"/}
    [[ -e config/$rel ]] && continue
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

  # mouse from the keyboard: ydotoold makes a virtual mouse (needs root for
  # that) and gives this user its socket. Written here, not in system/,
  # because it needs the user's id.
  cat >/etc/systemd/system/ydotoold.service <<EOF
[Unit]
Description=ydotoold: mouse from the keyboard (hopparch)

[Service]
ExecStart=/usr/bin/ydotoold --socket-path=/run/ydotoold/socket --socket-own=$(id -u "$USER_"):$(id -g "$USER_")
RuntimeDirectory=ydotoold

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable ydotoold.service
  # power modes (Settings > Power mode); bluetooth only where an adapter exists
  systemctl enable power-profiles-daemon.service
  if booted; then systemctl start power-profiles-daemon.service; fi
  if compgen -G '/sys/class/bluetooth/hci*' >/dev/null; then
    systemctl enable bluetooth.service
    if booted; then systemctl start bluetooth.service; fi
  fi
  # start it now too, unless we're inside install.sh's chroot
  if booted; then systemctl daemon-reload && systemctl restart ydotoold.service; fi
  return 0
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

  # new snapshots get into the boot menu right after each update. A pacman
  # hook instead of grub-btrfs's background daemon: nothing runs in between.
  # "zzz" sorts after snap-pac's own "zz-snap-pac-post" hook.
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


packages
onscreen_keyboard
copy_config
stash_apps
settings_entries
copy_system
services
upkeep
firewall
snapshots
say "Done. Log out and back in (or reboot): running apps keep the old config until then."

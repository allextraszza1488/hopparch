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
die() { printf '\e[31mxx  %s\e[0m\n' "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "run it with sudo: sudo ./setup.sh"
# the user whose config this is: argument (from install.sh) or whoever ran sudo
USER_=${1:-${SUDO_USER:-}}
[[ -n $USER_ && $USER_ != root ]] || die "usage: sudo ./setup.sh"
HOME_=$(getent passwd "$USER_" | cut -d: -f6)
GROUP_=$(id -gn "$USER_")
# copies of what setup.sh installed last time, to tell your edits from ours
STATE="$HOME_/.local/state/hopparch/installed"


packages() {
  say "Packages"
  pacman -S --needed --noconfirm \
    hyprland xdg-desktop-portal-hyprland waybar kitty fuzzel \
    fish eza zoxide fzf bat glow neovim btop firefox thunar \
    greetd greetd-tuigreet \
    ttf-jetbrains-mono-nerd noto-fonts
}

copy_config() {
  say "Config -> $HOME_/.config"
  local src rel dst mode
  while IFS= read -r -d '' src; do
    rel=${src#config/}
    dst="$HOME_/.config/$rel"
    runuser -u "$USER_" -- mkdir -p "$(dirname "$dst")" "$(dirname "$STATE/$rel")"
    # changed since we last installed it = your edit, keep it
    if [[ -f $dst ]] && ! cmp -s "$src" "$dst" && ! cmp -s "$dst" "$STATE/$rel" 2>/dev/null; then
      mv "$dst" "$dst.bak-$(date +%F-%H%M%S)"
      echo "  kept your version: $dst.bak-*"
    fi
    mode=644
    [[ -x $src ]] && mode=755
    install -m "$mode" -o "$USER_" -g "$GROUP_" "$src" "$dst"
    install -m 644 -o "$USER_" -g "$GROUP_" "$src" "$STATE/$rel"
  done < <(find config -type f -print0)
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
}


packages
copy_config
copy_system
services
say "Done. Reboot (or log out) to get the login screen."

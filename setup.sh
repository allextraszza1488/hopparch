#!/bin/bash
# hopparch setup -- installs the packages and copies config/ into one user's ~/.config.
#   first install:  install.sh runs it inside the new system
#   any time later: cd ~/hopparch && git pull && sudo ./setup.sh
# A config file you changed locally is kept as <file>.bak-<date> before being replaced.
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


packages() {
  say "Packages"
  pacman -S --needed --noconfirm \
    hyprland xdg-desktop-portal-hyprland \
    kitty fuzzel \
    ttf-jetbrains-mono-nerd noto-fonts
}

copy_config() {
  say "Config -> $HOME_/.config"
  local src dst
  while IFS= read -r -d '' src; do
    dst="$HOME_/.config/${src#config/}"
    runuser -u "$USER_" -- mkdir -p "$(dirname "$dst")"
    if [[ -f $dst ]] && ! cmp -s "$src" "$dst"; then
      mv "$dst" "$dst.bak-$(date +%F-%H%M%S)"
      echo "  kept your version: $dst.bak-*"
    fi
    install -m644 -o "$USER_" -g "$GROUP_" "$src" "$dst"
  done < <(find config -type f -print0)
}


packages
copy_config
say "Done. Log in on the text console and type: start-hyprland"

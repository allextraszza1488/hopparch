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

# launcher entries hidden from SUPER+D (and listed in "Stashed apps")
STASHED=$(grep -v -e '^#' -e '^\s*$' config/hopparch/stashed.list)


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
stash_apps
copy_system
services
say "Done. Reboot (or log out) to get the login screen."

#!/bin/bash
# Move credential files into the mounted vault and leave symlinks behind.
# Running this again is safe. ~/.grok/auth.json is left alone while grok is open.

set -euo pipefail

MOUNT="$HOME/Vault"

if ! mountpoint -q "$MOUNT"; then
  echo "Vault is not mounted."
  exit 1
fi

move() {
  local src=$1 dest=$2
  if [[ -L $src || ! -e $src ]]; then
    return 0
  fi
  if [[ -e $dest ]]; then
    if cmp -s "$src" "$dest"; then
      rm -f "$src"
      ln -s "$dest" "$src"
      echo "locked $src"
      return 0
    fi
    echo "both copies differ, left both:" >&2
    echo "  $src" >&2
    echo "  $dest" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  mv "$src" "$dest"
  ln -s "$dest" "$src"
  echo "locked $src"
}

move "$HOME/.config/gh/hosts.yml" "$MOUNT/gh/hosts.yml"
move "$HOME/.claude/.credentials.json" "$MOUNT/claude/credentials.json"
move "$HOME/.claude.json" "$MOUNT/claude/claude.json"
move "$HOME/.steam/steam.token" "$MOUNT/steam/steam.token"

if pgrep -x grok >/dev/null; then
  if [[ -e $HOME/.grok/auth.json && ! -L $HOME/.grok/auth.json ]]; then
    echo "grok is still open. ~/.grok/auth.json stays put until it exits."
  fi
else
  move "$HOME/.grok/auth.json" "$MOUNT/grok/auth.json"
fi

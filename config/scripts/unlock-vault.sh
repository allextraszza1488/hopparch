#!/bin/bash
# Ask once for the vault passphrase and mount ~/Vault.
# The passphrase is typed into the terminal. It is not stored here.
# Quiet when the vault has not been created yet.

set -euo pipefail

CIPHER="$HOME/.cipher"
MOUNT="$HOME/Vault"
MIGRATE="$HOME/.config/scripts/migrate-vault.sh"

[[ -f $CIPHER/gocryptfs.conf ]] || exit 0
mkdir -p "$MOUNT"

if mountpoint -q "$MOUNT"; then
  "$MIGRATE"
  exit 0
fi

kitty -1 --title 'unlock vault' -e bash -c '
  set -euo pipefail
  echo "Unlock ~/Vault. Same passphrase as root. It is not saved."
  if gocryptfs "$HOME/.cipher" "$HOME/Vault"; then
    "$HOME/.config/scripts/migrate-vault.sh"
  else
    echo
    echo "Vault stayed locked."
    read -r -p "Press enter to close."
  fi
'

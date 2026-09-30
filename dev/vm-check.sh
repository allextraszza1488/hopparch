#!/bin/bash
# Health check of the test VM after a change. Read-only: SSH only, never types
# on the VM's screen. Run on the laptop: dev/vm-check.sh
# Expects the VM rig from DESIGN.md (user test/test, SSH on 127.0.0.1:2222).
set -uo pipefail

ssh -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o LogLevel=ERROR test@127.0.0.1 bash -s <<'EOF'
sig=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
export HYPRLAND_INSTANCE_SIGNATURE=$sig
section() { printf '\n== %s\n' "$1"; }

section "Hyprland"
if [[ -n $sig ]] && hyprctl version >/dev/null 2>&1; then
  hyprctl version | head -1 | cut -c1-40
  errors=$(hyprctl configerrors | grep -v '^\s*$')
  echo "config errors: ${errors:-none}"
  echo "binds: $(hyprctl binds | grep -c '^bind')"
else
  echo "not running (nobody logged in?)"
fi

section "Expected processes"
for p in Hyprland waybar; do
  pgrep -x "$p" >/dev/null && echo "ok   $p" || echo "MISSING $p"
done

section "Memory"
free -m | awk 'NR==2 {printf "used %d MiB of %d MiB\n", $3, $2}'

section "User processes by RAM (MiB)"
ps -u test -o rss=,comm= --sort=-rss | awk '{printf "%6.1f  %s\n", $1/1024, $2}' | head -15

section "Failed services"
{ systemctl --failed --no-legend; systemctl --user --failed --no-legend; } | sed 's/^/  /'
echo "(end)"

section "Errors in the log since boot"
echo test | sudo -S -p '' journalctl -b -p err --no-pager -o cat 2>/dev/null | tail -15
echo "(end)"
EOF

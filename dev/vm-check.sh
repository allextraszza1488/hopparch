#!/bin/bash
# Health check of the test VM after a change. Read-only: SSH only, never types
# on the VM's screen. Run on the laptop: dev/vm-check.sh
# Expects the VM rig from DESIGN.md (user test/test, SSH on 127.0.0.1:2222;
# second VM: PORT=2223 dev/vm-check.sh).
set -uo pipefail

ssh -p "${PORT:-2222}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
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
for p in Hyprland waybar mako hypridle; do
  pgrep -x "$p" >/dev/null && echo "ok   $p" || echo "MISSING $p"
done

section "Services"
for s in greetd ydotoold NetworkManager; do
  printf '%-15s enabled=%s active=%s\n' "$s" "$(systemctl is-enabled $s 2>&1)" "$(systemctl is-active $s 2>&1)"
done
[[ -S /run/ydotoold/socket && -O /run/ydotoold/socket ]] && echo "ok   ydotool socket belongs to test" || echo "BAD  ydotool socket"
echo test | sudo -S -p "" ufw status verbose 2>/dev/null | grep -q 'deny (incoming)' && echo "ok   firewall: incoming blocked" || echo "BAD  firewall"
[[ -f /etc/snapper/configs/root ]] && echo "ok   snapshots configured ($(echo test | sudo -S -p "" snapper -c root list 2>/dev/null | tail -n +3 | grep -vc current) kept)" || echo "BAD  no snapper config"
echo "listening ports (only VM-dev sshd expected): $(echo test | sudo -S -p "" ss -tlnpH 2>/dev/null | grep -o 'users:(("[^"]*' | cut -d'"' -f2 | sort -u | xargs)"

section "Configs parse"
fish -n ~/.config/fish/config.fish && echo "ok   fish"
out=$(nvim --headless -u ~/.config/nvim/init.lua +qa 2>&1); [[ -z $out ]] && echo "ok   nvim" || echo "BAD  nvim: $out"
fuzzel --check-config >/dev/null 2>&1 && echo "ok   fuzzel" || echo "BAD  fuzzel"
python3 -c "import json,re,sys; json.loads(re.sub(r'^\s*//.*$','',open(sys.argv[1]).read(),flags=re.M))" ~/.config/waybar/config.jsonc && echo "ok   waybar json"
for f in ~/.config/scripts/*.sh; do [[ -x $f ]] && bash -n "$f" && echo "ok   $(basename "$f")" || echo "BAD  $f"; done
[[ $(getent passwd test | cut -d: -f7) == /usr/bin/fish ]] && echo "ok   login shell fish"
echo "stashed launcher entries: $(grep -l -x '# hopparch-stash' ~/.local/share/applications/*.desktop 2>/dev/null | wc -l)"

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

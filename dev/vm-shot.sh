#!/bin/bash
# Screenshot of the test VM's Hyprland session (works in 3D mode, where QEMU's
# own screendump can't). Needs grim in the VM. Prints the local PNG path.
#   dev/vm-shot.sh [out.png]      (second VM: PORT=2223 dev/vm-shot.sh)
set -euo pipefail
out=${1:-/tmp/vm-shot.png}
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

ssh -p "${PORT:-2222}" "${ssh_opts[@]}" test@127.0.0.1 bash -s <<'EOF'
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=$(basename "$(ls /run/user/1000/wayland-[0-9] | head -1)")
grim /tmp/vm-shot.png
EOF
scp -q -P "${PORT:-2222}" "${ssh_opts[@]}" test@127.0.0.1:/tmp/vm-shot.png "$out"
echo "$out"

#!/bin/bash
# The destructive branches: ESP mount failure, vault copies, Wi-Fi delete, brightness 0.
# No root, no real NetworkManager, no real backlight.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

fns=$tmp/install-fns.sh
sed '/^preflight$/,$d' "$root/install.sh" > "$fns"

if ( source "$fns"
     lsblk() { echo vfat; }
     mount() { return 1; }
     ESP=/dev/sda1
     classify_esp
   ) >"$tmp/esp-fail.out" 2>&1
then
  fail "a FAT ESP that will not mount was not refused"
fi
grep -q 'Not formatting it' "$tmp/esp-fail.out" || fail "mount failure did not say it would not format"

( source "$fns"
  lsblk() { echo vfat; }
  mount() { echo boot > "$4/EFI"; }
  umount() { rm -f "$1"/*; }
  ESP=/dev/sda1
  classify_esp
  [[ $ESP_STATUS == existing ]]
) || fail "a FAT ESP with files was not kept"

( source "$fns"
  lsblk() { echo btrfs; }
  mount() { echo mounted >"$tmp/mounted"; }
  ESP=/dev/sda1
  classify_esp
  [[ $ESP_STATUS == modify && ! -e $tmp/mounted ]]
) || fail "a non-FAT ESP was mounted"

unshare --user --map-root-user --mount bash -s "$root" "$tmp" << 'EOF'
set -euo pipefail
root=$1
tmp=$2
differ=$tmp/differ
src=$tmp/differ-src
mkdir -p "$differ/.config/gh" "$differ/.claude" "$differ/.steam" "$differ/Vault" "$src/gh"
echo only-home > "$differ/.config/gh/hosts.yml"
echo only-vault > "$src/gh/hosts.yml"
mount --bind "$src" "$differ/Vault"
set +e
HOME=$differ bash "$root/config/scripts/migrate-vault.sh" >"$tmp/differ.out" 2>"$tmp/differ.err"
st=$?
set -e
[[ $st == 1 ]] || { echo "differ exited $st"; exit 1; }
[[ $(cat "$differ/.config/gh/hosts.yml") == only-home ]]
[[ $(cat "$src/gh/hosts.yml") == only-vault ]]
grep -q 'both copies differ' "$tmp/differ.err"

miss=$tmp/miss
msrc=$tmp/miss-src
mkdir -p "$miss/.claude" "$miss/.steam" "$miss/Vault" "$msrc/gh"
echo secret > "$msrc/gh/hosts.yml"
mount --bind "$msrc" "$miss/Vault"
HOME=$miss bash "$root/config/scripts/migrate-vault.sh" >"$tmp/miss.out"
[[ -L $miss/.config/gh/hosts.yml ]]
[[ $(readlink "$miss/.config/gh/hosts.yml") == "$miss/Vault/gh/hosts.yml" ]]
[[ $(cat "$miss/.config/gh/hosts.yml") == secret ]]
EOF

mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/notify-send" << 'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${NOTELOG:?}"
SH
cat > "$tmp/bin/fuzzel" << 'SH'
#!/bin/bash
cat >/dev/null
n=$(cat "${FUZ_COUNT:?}")
echo $((n + 1)) > "$FUZ_COUNT"
if [[ $n == 0 ]]; then printf '%s\n' "${FUZ_CHOICE:?}"
else printf '%s\n' secret
fi
SH
cat > "$tmp/bin/nmcli" << 'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${NMLOG:?}"
case "$*" in
  "radio wifi") echo enabled ;;
  "-t --escape no -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan auto")
    printf '%s\n' " :80:${WIFI_SEC:?}:Cafe" ;;
  "-t -f NAME connection show")
    [[ ${WIFI_EXIST:-0} == 1 ]] && echo Cafe ;;
  "-t --escape no -f SECURITY,SSID device wifi list --rescan no")
    printf '%s\n' "${WIFI_SEC:?}:Cafe" ;;
  "device wifi connect Cafe") exit 1 ;;
  connection\ add\ *) exit 0 ;;
  connection\ up\ *) exit 1 ;;
  connection\ delete\ *) exit 0 ;;
  *) echo "bad nmcli: $*" >> "$NMLOG"; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/"*
run_wifi() {
  : > "$tmp/nm.log"
  : > "$tmp/notes"
  echo 0 > "$tmp/fuz.count"
  NOTELOG=$tmp/notes NMLOG=$tmp/nm.log FUZ_COUNT=$tmp/fuz.count \
    FUZ_CHOICE='   80%  lock  Cafe' WIFI_SEC=$1 WIFI_EXIST=$2 \
    PATH="$tmp/bin:$PATH" HOME=$tmp/home \
    bash "$root/config/scripts/settings.sh" wifi
}
run_wifi WPA2 1
grep -q 'connection delete' "$tmp/nm.log" && fail "a saved Wi-Fi profile was deleted"
grep -q 'connection add' "$tmp/nm.log" && fail "a saved Wi-Fi profile was created again"
run_wifi WPA3 0
grep -q 'wifi-sec.key-mgmt sae' "$tmp/nm.log" || fail "WPA3-only was not sae"
run_wifi "WPA2 802.1X" 0
grep -q 'connection add' "$tmp/nm.log" && fail "802.1X created a password profile"
grep -q 'needs a username' "$tmp/notes" || fail "802.1X did not say it needs a username"

unshare --user --map-root-user --mount bash -s "$root" "$tmp" << 'EOF'
set -euo pipefail
root=$1
tmp=$2
home=$tmp/bright
mkdir -p "$home/.config/scripts" "$tmp/bbin"
cp "$root/config/scripts/brightness.sh" "$root/config/scripts/settings.sh" "$home/.config/scripts/"
cat > "$tmp/bbin/notify-send" << 'SH'
#!/bin/bash
exit 0
SH
cat > "$tmp/bbin/fuzzel" << 'SH'
#!/bin/bash
cat >> "${FUZLOG:?}"
SH
chmod +x "$tmp/bbin/"*
mount -t tmpfs t /sys/class/backlight
one() {
  rm -rf /sys/class/backlight/*
  mkdir -p "/sys/class/backlight/$1"
  echo "$2" > "/sys/class/backlight/$1/actual_brightness"
  : > "$tmp/fuz"
  PATH="$tmp/bbin:$PATH" HOME=$home FUZLOG=$tmp/fuz \
    bash "$home/.config/scripts/settings.sh" brightness
}
one amdgpu_bl0 0
grep -q '100%' "$tmp/fuz" || { echo 'working panel at 0 offered no levels'; exit 1; }
one nvidia_wmi_ec_backlight 0
grep -q 'not wired' "$tmp/fuz" || { echo 'EC device at 0 did not warn'; exit 1; }
if grep -q '100%' "$tmp/fuz"; then
  echo 'EC device at 0 still offered levels'
  exit 1
fi
EOF

echo OK

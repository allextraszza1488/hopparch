# hopparch

A plain, keyboard-first Arch Linux + Hyprland setup, installed from the Arch ISO
on any machine.

## Install

1. Boot the Arch ISO. Wi-Fi: `iwctl station wlan0 connect "<network>"`
2. Partition by hand: `cfdisk /dev/<disk>`. Make one EFI partition (~1G, type
   *EFI System*; on dual-boot, reuse the existing one) and one root partition
   (type *Linux filesystem*). The script never creates, deletes or wipes
   partitions.
3. Run:
   ```
   curl -LO https://raw.githubusercontent.com/allextraszza1488/hopparch/main/install.sh
   bash install.sh
   ```
   It scans the machine, asks a few questions, opens archinstall pre-filled
   (review, then Install), and then sets up the desktop.

## Update

```
cd ~/hopparch && git pull && sudo ./setup.sh
```
Files you changed yourself are kept as `<file>.bak-<date>`.

## Layout

- `install.sh`: runs on the ISO (scan, partitions, archinstall preset, setup)
- `setup.sh`: packages, `config/` → `~/.config`, `system/` → `/`
- `dev/`: test-VM helpers
- `notes/`: research and test reports

# hopparch

A keyboard-first Arch Linux desktop. Hyprland, a top bar, and a small set of tools. One script from the Arch ISO. The same config on a laptop or a PC. The driver packages follow the hardware.

## Install

Boot the Arch ISO. Partition the disk yourself with `cfdisk`. One EFI partition, about 1 GB, type **EFI System**. One root partition, type **Linux filesystem**. On a dual-boot machine, reuse the EFI partition that is already there. The script does not create, delete, or wipe partitions. It formats only what you confirm.

Wi-Fi, if the ISO has no ethernet:

```bash
iwctl station wlan0 connect "<network>"
```

Then:

```bash
curl -LO https://raw.githubusercontent.com/allextraszza1488/hopparch/main/install.sh
bash install.sh
```

It prints what it found, asks for a profile, a username, and a password, then shows one summary. Confirm with `y`. archinstall runs from that preset. `setup.sh` installs the desktop. Reboot, unlock the disk, and log in.

## What the scan installs

| Hardware | Packages |
| --- | --- |
| NVIDIA GTX 16xx, RTX, and newer | `nvidia-open`, `libva-nvidia-driver` |
| Older NVIDIA | `mesa`, `vulkan-nouveau` |
| AMD | `mesa`, `vulkan-radeon` |
| Intel | `mesa`, `vulkan-intel`, `intel-media-driver` |
| Hybrid, screen on the other GPU | also `nvidia-prime` |

A battery, or a portable chassis, marks the machine as a laptop. The package list stays the same. Battery, brightness, and Wi-Fi entries appear only when that hardware exists. Sleep on idle runs only when a battery exists. The FA506NC panel kernel line is written only on that model.

## Profiles

Under 6 GB of RAM or under 4 cores, the suggestion is **minimal**. Otherwise it is **full**. You can take the other one.

Both profiles get the desktop, Firefox, the file manager, Neovim, Mullvad, snapshots, the firewall, and `linux-lts` as a second kernel in the boot menu. Bluetooth is installed only with an adapter, and stays off until you turn it on in Settings. **full** also gets Steam, the 32-bit drivers for the GPUs it found, gamemode, the compilers, `mpv`, and `imv`.

Mullvad is installed and left unconfigured: log in and connect in its app. The wallpaper file is not in this repo. Point `wallpaper.sh` at a picture after the first login.

## Daily keys

`Super` is the logo key. `Super` + `Shift` + `/` opens the full list.

| Keys | Action |
| --- | --- |
| `Super` + `Return` | Terminal |
| `Super` + `D` | Launcher |
| `Super` + `B` | Browser |
| `Super` + `F` | Files |
| `Super` + `Q` | Close window |
| `Super` + `1`–`9` | Workspace |
| `Ctrl` + `Alt` + `Delete` | System monitor |
| `Super` + `Shift` + `E` | Power menu |
| `Super` + `Shift` + `Esc` | Lock |

## Update

```bash
cd ~/hopparch && git pull && sudo ./setup.sh
```

A file you edited is kept as `<file>.bak-<date>`, then replaced with the repo copy.

## Tree

| Path | Role |
| --- | --- |
| `install.sh` | ISO only. Scan, questions, archinstall, then setup. |
| `setup.sh` | Packages, `config/` into `~/.config`, `system/` into `/`. |
| `config/` | The desktop: Hyprland, bar, terminal, menus. |
| `profiles/` | The **full** and **minimal** overlays. |
| `system/` | greetd, systemd, reflector, makepkg. |
| `dev/` | Checks and the test-VM helpers. Not installed. |

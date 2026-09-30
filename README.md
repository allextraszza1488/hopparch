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
   It scans the machine, asks a few questions, shows one summary and asks
   "Install now? [y/N]". After that it installs everything by itself
   (archinstall runs silently) and sets up the desktop.
   `bash install.sh --review` opens archinstall's menu before installing.

### Next to another system
hopparch needs free disk space for its partitions; the script never shrinks
or deletes anything, you do that first.
- **Windows:** in Windows' Disk Management, *Shrink Volume* on C:. In
  cfdisk make the root partition (+ a /home one if you want). Windows'
  EFI partition can be shared (it is kept, only mounted) if it has 400 MiB
  or more; Windows usually makes 100 MiB ones: then also make a new 1G
  "EFI System" partition and pick that one.
- **Another Linux:** it keeps its own EFI partition; hopparch needs a second
  one (two Linux systems can't share /boot). Shrinking a btrfs partition,
  from the Arch ISO (make a backup first; nothing here is undoable):
  ```
  mount /dev/<its partition> /mnt          # LUKS: cryptsetup open first, mount /dev/mapper/<name>
  btrfs filesystem resize -150G /mnt       # the filesystem gets 150G smaller
  btrfs filesystem show /mnt               # note its new size
  umount /mnt                              # LUKS: cryptsetup close <name>
  cfdisk /dev/<disk>                       # Resize the partition to the new size + 1G of
                                           # slack (LUKS: + another 16M for its header),
                                           # then New: 1G "EFI System" + a "Linux filesystem"
  ```
  The other system shows up in hopparch's
  boot menu as "Other system"; its own firmware entry named GRUB is replaced
  by hopparch's. (The other way round too: running `grub-install` in the
  other system later takes hopparch's firmware entry; its GRUB menu doesn't
  list hopparch, so use the firmware's boot menu then, or run hopparch's
  `grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB` again.)

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

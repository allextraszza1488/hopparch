# archinstall 4.4: config format notes (for hopparch)

Ground truth: the installed source on the Arch ISO, `archinstall 4.4-1`, at
`/usr/lib/python3.14/site-packages/archinstall/`. All `file:line` references below are relative to that directory.

Legend:
- **[dry-run]**: checked on the VM with `archinstall --config X --silent --dry-run --offline`. This parses the config, writes `/var/log/archinstall/user_configuration.json` and exits before any disk operation (`scripts/guided.py:228`).
- **[src]**: read from the source only, not run.
- **[NOT VERIFIED]**: inferred; not confirmed from the source or at runtime.

Not tested at all: a real install (partitioning, LUKS, GRUB boot) and the interactive TUI. Launching the TUI over SSH was blocked by the permission sandbox, so every TUI statement below comes from reading the source.

---

## Q1. Top-level structure

The loader is `ArchConfig.from_config()` (`lib/args.py:257-379`). How the input is read:
- `--config` and `--creds` are merged with `dict.update()`, and the creds file wins (`lib/args.py:682-707`). So any key can technically go in either file.
- `null` values inside nested **dicts** are removed before parsing. Lists are not touched, so partition entries keep their `null`s (`_cleanup_config`, `lib/args.py:793-802`).
- **Unknown keys are ignored** [dry-run]. Keys such as `debug`, `silent`, `offline` and `no_pkg_lookups` in the old `examples/config-sample.json` do nothing. They are CLI flags only.
- There is **no JSON schema**. Each sub-object has its own `parse_arg`. See Q9 for how errors surface.

| key | type / values | default if omitted | source |
|---|---|---|---|
| `version` | str | ignored on load, overwritten with `4.4` | args.py:480 |
| `script` | `"guided"` | `guided` | args.py:262, 493 |
| `archinstall-language` | `"English"` (Language.name_en). **Hyphen on read**; saved as `archinstall_language` (underscore), which is then not re-read | English | args.py:265 |
| `locale_config` | `{kb_layout, sys_lang, sys_enc, console_font}` (legacy: same keys at top level) | ISO keymap, `en_US.UTF-8`, `UTF-8`, `default8x16` | models/locale.py |
| `disk_config` | see Q2 | none (menu item is **mandatory**) | models/device.py:114 |
| `encryption_password` | plaintext str (normally in creds) | none | args.py:270 |
| `disk_encryption` (top level) | **DEPRECATED**. Without a password archinstall exits (Q3) | n/a | args.py:278 |
| `bootloader_config` | `{bootloader, uki, removable, plymouth?}` (legacy: `bootloader` + `uki` at top level) | TUI default: Systemd-boot, uki=true (UEFI) | models/bootloader.py |
| `kernels` | `["linux"]`, `"linux-lts"`, `"linux-zen"`, `"linux-hardened"` (not validated, passed to pacstrap as-is) | `["linux"]` | args.py:327 |
| `packages` | list[str] (**not validated** before install; `--no-pkg-lookups` is unused in 4.4) | [] | args.py:332 |
| `profile_config` | `{profile:{main,details,custom_settings?,path?}, gfx_driver, greeter}` | none | models/profile.py:52 |
| `app_config` | `{audio_config, bluetooth_config, power_management_config, print_service_config, firewall_config, fonts_config}` (legacy top-level `audio_config` also accepted) | none | models/application.py:215 |
| `network_config` | `{type: "iso"/"nm"/"nm_iwd"/"iwd"/"manual", nics?}` | none (TUI warns but does not block) | models/network.py:11 |
| `mirror_config` | `{mirror_regions:{Region:[urls]}, custom_servers:[{url}], optional_repositories:["multilib",...], custom_repositories:[...]}` | none: the ISO mirrorlist is used as-is | models/mirrors.py:327 |
| `pacman_config` | `{parallel_downloads:int, color:bool}` | 5 / true | models/pacman.py |
| `swap` | `true` / `false` or `{enabled, algorithm: zstd/lzo-rle/lzo/lz4/lz4hc}` (zram) | TUI default: enabled | models/application.py:177 |
| `hostname` | str | `archlinux` | args.py:324 |
| `timezone` | e.g. `"Europe/Kyiv"`; must exist in `/usr/share/zoneinfo` or it only warns | `UTC` | installer.py:685 |
| `ntp` | bool | true | args.py:330 |
| `services` | list of unit names (`systemctl --root=/mnt enable`) | [] | installer.py:719 |
| `custom_commands` | list[str] | [] | args.py:376 |
| `auth_config` | `{root_enc_password?, u2f_config?}` | none | models/authentication.py:67 |
| `users` | see Q4 (normally in creds) | none | args.py:368 |
| `root_enc_password` | crypt hash (normally in creds). Legacy: `!root-password` plaintext | none | args.py:352-361 |

---

## Q2. `disk_config` for pre-existing partitions

### Layout type
- Use **`"config_type": "manual_partitioning"`**. This is what the TUI produces when you pick "Manual Partitioning" and mark existing partitions for formatting (`lib/disk/disk_menu.py` `select_disk_config`).
- `"pre_mounted_config"` + `"mountpoint": "/mnt"` is the wrong choice here:
  - It uses whatever is already mounted, with status `existing` everywhere (`device_handler.detect_pre_mounted_mods`, device_handler.py:558).
  - It skips all formatting (`filesystem.py:39`), `mount_ordered_layout` and LUKS keyfile setup (`guided.py:86,95`).
  - `disk_encryption` is not even serialized for Pre_mount (device.py:70).
  - So archinstall would neither create LUKS nor add the `encrypt` hook or `cryptdevice=`.

### Partition status and what happens to the partition
Values come from `ModificationStatus` (device.py:858).

| status | meaning at install time |
|---|---|
| `"existing"` | Not touched: not recreated, not formatted, no subvolumes created. It **is mounted** at its `mountpoint` (installer.py:374). Use this for a Windows ESP you must keep. It cannot be selected for LUKS (encryption_menu.py:321). |
| `"modify"` | "Format this existing partition". Requires `dev_path` and `fs_type` (device.py:904-908). With `wipe:false` the partition-table entry is **deleted and re-added with the given start/size, fs type and flags** (`_setup_partition`, device_handler.py:345-402), then `wipefs --all`, then mkfs (or luksFormat + mkfs), then btrfs subvolumes are created (filesystem.py:73-74, 86). |
| `"create"` | New partition in free space. `dev_path: null`. Start must be ≥1 MiB, 1 MiB-aligned and not overlapping (device.py:199-223). |
| `"delete"` | Delete the entry. |

The TUI's "Mark/Unmark to be formatted" toggles `existing` ↔ `modify` and nothing else (partitioning_menu.py:391-397). There is no separate "format" flag.

Consequences of `modify`:
- **start/size must match the real partition exactly**, or it will be recreated elsewhere and may fail with "overlapping sectors".
- **flags must be listed**, because the recreated entry only gets the flags you give. The ESP needs `["boot","esp"]`.
- On GPT, a root partition gets the Linux-root-x86_64 type GUID (device_handler.py:394-398).
- [NOT VERIFIED] The PARTUUID changes, because libparted creates a new entry. The end may be snapped to 1 MiB alignment by `optimalAlignedConstraint`. Both are harmless for us because we reformat anyway.

### Device-level keys
Use `"wipe": false`. `true` wipes the **whole disk** and creates a fresh table (device_handler.py:524-528), which would destroy Windows.

If `device` is not found, that device entry is **silently dropped** [dry-run]. The TUI then fails validation with "Root partition not found".

### Partition object fields
Parsed at device.py:164-186. Fields marked "required" raise `KeyError` or `TypeError` if missing (a traceback, see Q9).

```jsonc
{
  "obj_id": "any-unique-string",      // required; referenced by disk_encryption.partitions
  "status": "modify",                 // required: existing | modify | create | delete
  "type": "primary",                  // required: primary | boot | unknown
  "dev_path": "/dev/vda2",            // required key (null only for "create")
  "start": {"value": 2099200, "unit": "sectors", "sector_size": {"value": 512, "unit": "B"}},  // required
  "size":  {"value": 41873833984, "unit": "B", "sector_size": {"value": 512, "unit": "B"}},    // required
  "fs_type": "btrfs",                 // btrfs ext2 ext3 ext4 f2fs fat12 fat16 fat32 ntfs xfs linux-swap
  "mountpoint": null,                 // required key; null for btrfs (subvolumes carry mountpoints)
  "mount_options": ["compress=zstd"], // required key (list)
  "flags": [],                        // optional: boot esp bls_boot(xbootldr) linux-home swap
  "btrfs": [ {"name": "@", "mountpoint": "/"} ]   // optional; entries without both name+mountpoint are skipped
}
```

**Sizes** (device.py:265-371):
- `unit` is a `Unit` enum **name**: `B`, `kB`, `MB`, `GB`, `KiB`, `MiB`, `GiB`, `TiB`, ..., or `sectors`.
- **`Percent` no longer exists.** The bundled `examples/config-sample.json` is stale on this point, and on `sector_size: null` (which gives a TypeError) [dry-run].
- `sector_size` must be an object `{value, unit:"B"}`. It only matters when `unit` is `sectors`, so it must equal the disk's **logical** block size.
- The TUI itself writes start in `sectors` and size in `B`.
- Using `"unit":"B"` for both start and size also works [dry-run]. It avoids the 512-vs-4Kn pitfall.

Recommended way to fill start/size from sysfs (sysfs is always in 512-byte units):
```sh
start_b=$(( $(cat /sys/class/block/vda2/start) * 512 ))
size_b=$((  $(cat /sys/class/block/vda2/size)  * 512 ))
lss=$(cat /sys/block/vda/queue/logical_block_size)
# -> "start": {"value": $start_b, "unit": "B", "sector_size": {"value": $lss, "unit": "B"}}
```

**Btrfs:**
- A partition with `fs_type: btrfs` gets `mountpoint: null`. Subvolumes are mounted with `mount_options + ["subvol=<name>"]` (installer.py:436-447), so `compress=zstd` ends up in fstab through genfstab.
- The TUI's "compressed" toggle uses exactly the string `compress=zstd` (`BtrfsMountOption`, device.py:512).
- Subvolumes are only created for `create`/`modify` partitions (filesystem.py:73).

Optional, only honoured if a `@`→`/` subvolume exists (device.py:232):
```json
"btrfs_options": {"snapshot_config": {"type": "Snapper"}}
```
Values are `Snapper` or `Timeshift`. **Do not combine Snapper with our `@snapshots`→`/.snapshots`.** archinstall runs `snapper create-config /` (installer.py:1006), which tries to create `/.snapshots` itself. [NOT VERIFIED at runtime] That fails, the DiskError aborts the install, and GRUB also gets grub-btrfs from this option.

**Root and boot detection** (used for TUI validation and the bootloader):
- Root is the partition whose `mountpoint` is `/`, or which has a subvolume mounted at `/` (device.py:981).
- The boot partition needs flag `boot` **and** a mountpoint (device.py:1420).
- The ESP needs flag `esp` **and** a mountpoint. Its fs must be FAT on UEFI (global_menu.py:485-490).

ESP snippet: format it (fresh ESP):
```json
{"obj_id":"efi-1","status":"modify","type":"primary","dev_path":"/dev/vda1",
 "start":{"value":2048,"unit":"sectors","sector_size":{"value":512,"unit":"B"}},
 "size":{"value":1073741824,"unit":"B","sector_size":{"value":512,"unit":"B"}},
 "fs_type":"fat32","mountpoint":"/boot","mount_options":[],"flags":["boot","esp"],"btrfs":[]}
```

ESP snippet: keep an existing Windows ESP (`"status":"existing"`, same fields otherwise; `fs_type` should still be `"fat32"` so validation passes) [dry-run parses].
- It is mounted with `fmask=0077,dmask=0077` (installer.py:385).
- Warning: a Windows ESP is often only 100 MB, and kernel + initramfs go there.
- Use `"removable": false` so GRUB does not overwrite `EFI/BOOT/BOOTX64.EFI`.

---

## Q3. `disk_encryption` (LUKS on root)

Keys go **inside `disk_config`** (device.py:1465-1565, 1439):
```json
"disk_encryption": {
  "encryption_type": "luks",
  "partitions": ["<obj_id of root partition>"],
  "lvm_volumes": [],
  "iter_time": 10000
}
```
- `encryption_type` is one of `no_encryption`, `luks`, `lvm_on_luks`, `luks_on_lvm`.
- `iter_time` is optional (default 10000 ms). `hsm_device` is optional (FIDO2).
- The password comes from the top-level `encryption_password` (plaintext) key, in the config or in `--creds`.

**No password means encryption is silently dropped.**
- `DiskEncryption.parse_arg` does `if not password: return None` (device.py:1537-1538).
- archinstall starts normally. The TUI shows the disk config **without encryption**. Install is **not** blocked (encryption is not a mandatory item). Confirmed [dry-run]: the saved config has no `disk_encryption`.
- The deprecated **top-level** `disk_encryption` without a password makes archinstall **exit 1** with `Either plaintext or enc_password must be provided` [dry-run] (args.py:278-283 → `Password('')` → ValueError).

So there is no way to pre-select "LUKS on vda2" and only have the TUI ask for the password. Options:
1. **Password in the TUI (3 steps).** Leave `disk_encryption` out. The user goes to *Disk configuration → Disk encryption → Encryption type: LUKS → Encryption password → Partitions: select vda2 → Back*.
   - The partition list offers only non-`existing` partitions and not `/boot` (encryption_menu.py:316-321), so the `modify` root is offered.
   - The submenu returns a config only if type + password + partitions are all set (encryption_menu.py:146).
   - Risk: if the user forgets, the install is unencrypted with no warning.
2. **Script asks for the password.** Use `read -rs` twice, then write a tmpfs creds file `{"encryption_password": "..."}`, run `archinstall --config cfg.json --creds /tmp/creds.json` [dry-run: encryption kept], and `shred`/`rm` the file afterwards.
   - The TUI then shows "Disk encryption: LUKS" pre-filled and can still be changed.
   - archinstall does not copy the creds file anywhere. `save()` only writes `user_configuration.json` (args.py:399-416).
   - Never use `--debug`: it writes credentials to the log (args.py:665-666).
   - An encrypted creds file is also supported: content starting with `$` makes archinstall prompt for its decryption password (args.py:709-750). It is a separate password, so it does not help here.

What the install does with LUKS [src]:
- `luksFormat` + mkfs on `/dev/mapper/root`. The mapper name is `root` because the partition is root (device.py:1018-1026).
- Adds the `encrypt` hook. HOOKS become `base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck` (installer.py:111-125, 850-857, 890-899).
- Kernel params: `cryptdevice=UUID=<luks-uuid>:root` (installer.py:1102-1138).

---

## Q4. Credentials

The keys below are read from the merged config+creds dict. archinstall writes them only to `user_credentials.json` (`unsafe_config`, args.py:177-192), and the main config never contains them. Putting them in the main file also works, but don't.

```json
{
  "users": [
    {"username": "user", "enc_password": "$y$j9T$....", "sudo": true, "groups": []}
  ],
  "root_enc_password": "$y$j9T$....",
  "encryption_password": "plaintext-luks-pass"
}
```

- `users[]` is parsed by `User.parse_arguments` (models/users.py:182-214).
  - It needs `username` and either `enc_password` (a crypt hash) or the deprecated plaintext `"!password"`.
  - Entries without a password are **silently skipped**.
  - `sudo: true` gives `useradd -G wheel` plus `/etc/sudoers.d/NN_user`.
- `root_enc_password` is a hash. The deprecated plaintext form is `"!root-password"` (args.py:351-361). `auth_config.root_enc_password` is also accepted.
- **Hash format.** archinstall itself makes yescrypt `$y$` hashes via libcrypt, with cost from `YESCRYPT_COST_FACTOR` (default 5) (crypt.py:49). The hash is applied with `chpasswd --encrypted` (installer.py:1991-2008), so any crypt(5) hash works, e.g. `openssl passwd -6 'pw'` (`$6$`).
- `encryption_password` is **plaintext** (args.py:190, 270).

**If users/root are omitted** [src]:
- The Authentication item shows as unset.
- Hovering **Install** shows `Missing configurations: - Either root-password or at least 1 user with sudo privileges must be specified`. Pressing Install does nothing until it is fixed (global_menu.py:205-247, abstract_menu.py `show()` → `is_config_valid`).
- Other than that there are no prompts, so the user just fills *Authentication → User account / Root password*.

---

## Q5. Bootloader

`"bootloader_config": {"bootloader": "Grub", "uki": false, "removable": false}` (models/bootloader.py:11-17, 119-125).

- **Values:** `"Systemd-boot"`, `"Grub"`, `"Efistub"`, `"Limine"`, `"Refind"`. The input is `.capitalize()`d, so `"grub"` works [dry-run]. `"No bootloader"` is only accepted with `--skip-boot`. Anything else exits: `Invalid bootloader value "X". Allowed values: ...` [dry-run].
- **Defaults** when a key is omitted: `uki` false, `removable` **true**. The TUI default (without a config) is Systemd-boot, uki=true on UEFI.
- **`uki`:** supported by every bootloader (`has_uki_support`). For GRUB it writes `/etc/grub.d/15_uki` and builds UKIs in `<ESP>/EFI/Linux`.
- **`removable`:** only GRUB and Limine support it. It passes `grub-install --removable`, which installs to `EFI/BOOT/BOOTX64.EFI` with no NVRAM entry. Use `false` for dual boot.
- Optional `"plymouth": "bgrt"`, or `fade-in`, `glow`, `script`, `solar`, `spinner`, `spinfinity`, `tribar`, `text`, `details`.
- **Validation** (bootloader/utils.py, global_menu.py:447-495): Systemd-boot, Efistub and Refind are UEFI-only. Efistub and Limine need a FAT `/boot`.

**GRUB + btrfs root + LUKS** [src, not runtime-tested]. `_add_grub_bootloader` (installer.py:1330-1443):
- Runs `grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB [--removable]`.
- Writes `GRUB_CMDLINE_LINUX="cryptdevice=UUID=<luks>:root [zswap.enabled=0] rootfstype=btrfs"` with `id_root=False`, then runs `grub-mkconfig`. grub-mkconfig adds `root=`/`rootflags=subvol=@` itself.
- **archinstall never sets `GRUB_ENABLE_CRYPTODISK`.** With LUKS root, `/boot` must be the unencrypted ESP (or a separate unencrypted /boot), as in our layout. With that, the code path is consistent.

---

## Q6. Profile, packages, GPU

- **No desktop:** `"profile_config": {"profile": {"main": "Minimal"}, "gfx_driver": null, "greeter": null}`. `Minimal.install()` installs nothing (default_profiles/minimal.py, profile.py:105). Omitting `profile_config` entirely is equivalent.
  - If you include `profile_config` with a non-null `gfx_driver`/`greeter`, then `"profile"` is required, or you get a KeyError (models/profile.py:56).
  - Other `main` values: `Desktop` (details e.g. `["Hyprland"]`), `Xorg`, `Server`.
- **`gfx_driver` values** (hardware.py:56-62):
  - `"All open-source"`
  - `"AMD / ATI (open-source)"`
  - `"Intel (open-source)"`
  - `"Nvidia (open kernel module for newer GPUs, Turing+)"`
  - `"Nvidia (open-source nouveau driver)"`
  - `"VirtualBox (open-source)"`
  - Note: `"All open-source (default)"` (from the bundled sample) and `"Nvidia (proprietary)"` make archinstall exit [dry-run].
  - **The GPU driver is only installed when the profile is Desktop or Xorg** (profiles_handler.py:247). With Minimal, `gfx_driver` is ignored, so put driver packages into `packages` instead. The package sets archinstall would use (hardware.py:93-137):
    - AMD: `mesa xf86-video-amdgpu xf86-video-ati vulkan-radeon`
    - Intel: `mesa libva-intel-driver intel-media-driver vulkan-intel`
    - NVIDIA Turing+: `nvidia-open libva-nvidia-driver` for plain `linux`, or `nvidia-open-dkms dkms <kernel>-headers` for other kernels
    - nouveau: `mesa xf86-video-nouveau vulkan-nouveau`
- **Extra packages:** `"packages": ["git", "base-devel"]`. They are installed after the profile via `pacstrap` (guided.py:145-146) and are not validated beforehand. A bad name fails the install at that point.
- **Audio:** `"app_config": {"audio_config": {"audio": "pipewire"}}`, or `"pulseaudio"` / `"No audio server"`. This installs `pipewire pipewire-alsa pipewire-jack pipewire-pulse gst-plugin-pipewire` and links the pipewire-pulse user units for each created user (applications/audio.py).
- **Other `app_config` keys:**
  - `bluetooth_config: {enabled}`
  - `print_service_config: {enabled}`
  - `power_management_config: {power_management: "power-profiles-daemon"|"tuned"}`
  - `firewall_config: {firewall: "ufw"|"firewalld"}`
  - `fonts_config: {fonts: ["noto-fonts","noto-fonts-emoji","noto-fonts-cjk","ttf-liberation","ttf-dejavu"]}`
- **Network:** `"network_config": {"type": "nm"}` installs `networkmanager wpa_supplicant` and enables `NetworkManager.service`. `nm_iwd` uses iwd as the backend (network/network_handler.py:18-35).

---

## Q7. `custom_commands`

`run_custom_user_commands` (installer.py:2132-2143):
- Each string is written to `/mnt/var/tmp/user-command.N.sh` and run as `arch-chroot -S /mnt bash /var/tmp/user-command.N.sh`, i.e. **as root inside the new system's chroot** (`-S` = via systemd-run on the ISO; the target's systemd is not running).
- Multi-line strings are fine.

Order in `perform_installation` (scripts/guided.py:52-184):
1. mount → pacstrap base → locale/hostname/mkinitcpio
2. zram → bootloader → network
3. **create users + passwords**
4. applications (audio) → profile → `packages`
5. timezone → ntp → root password
6. profile post_install → `services`
7. btrfs snapshots
8. **custom_commands**
9. **genfstab**

So users exist when custom_commands run, but **`/etc/fstab` has not been generated yet**.

**A non-zero exit raises `SysCallError` and aborts the install** (genfstab is skipped too). Guard commands with `|| true` where appropriate.

The username is chosen in the TUI, so a command should look it up, e.g. `u=$(getent passwd 1000 | cut -d: -f1); runuser -u "$u" -- ...`.

---

## Q8. `archinstall --config file.json` without `--silent`

Yes, it opens the main menu pre-filled [src]. `GlobalMenu` → `AbstractMenu._sync_from_config()` copies every `ArchConfig` attribute into its menu item (menu/abstract_menu.py). Nothing is asked up-front except the Wi-Fi/network check.

Startup sequence (main.py:110-173):
1. Root check.
2. Unless `--offline`:
   - `ping 1.1.1.1`. If "Network is unreachable", the Wi-Fi TUI opens; skip that with `--skip-wifi-check`.
   - `pacman -Sy`. On failure, archinstall exits 1.
   - Version check. Unless `--skip-version-check`, it only prints "New version available" and sleeps 3 s. `show_menu` still calls it for the title bar (guided.py:32).
3. There is **no mirror step** unless `mirror_config` is given. When it is omitted, the ISO's reflector-generated mirrorlist is used.

`--offline` would skip the network steps but also disables keyring/online checks. Not wanted, since pacstrap needs the network.

Flow after the menu:
1. **Install** is blocked while config is invalid (missing auth, no root/ESP, bootloader mismatch).
2. A confirm screen shows the JSON preview (Yes/No) (configuration.py:12).
3. A countdown "Starting device modifications in ..." runs (guided.py:245).
4. Then formatting starts.

Suggested command: `archinstall --config /tmp/hopparch/user_configuration.json [--creds /tmp/hopparch/creds.json] --skip-version-check`

---

## Q9. Validation and how errors show

- **Enum/ValueError errors:** archinstall prints one line and exits 1 before the TUI (`ArchConfigHandler.__init__`, args.py:478-483). All of these were seen [dry-run]:
  - `'format' is not a valid ModificationStatus`
  - `'PipeWire' is not a valid Audio`
  - `'NetworkManager' is not a valid NicType`
  - `'All open-source (default)' is not a valid GfxDriver`
  - `FS type must not be empty on modifications with status type modify`
  - `Either plaintext or enc_password must be provided`
  - `Invalid bootloader value ...`
  - Also, for `create` partitions: `Partitions overlap`, `Partition is misaligned`, `First partition must start at no less than 1 MiB`.
- **Missing required keys / wrong shapes:** a Python **traceback** is printed, followed by "Archinstall experienced the above error ... share-log", exit 1 (main.py:176-207). Examples [dry-run]:
  - `KeyError: 'dev_path'`
  - `KeyError: 'mount_options'`
  - `TypeError: 'NoneType' object is not subscriptable` (from `sector_size: null`)
- **Silently ignored:**
  - unknown keys [dry-run]
  - an unknown `device` [dry-run]
  - `disk_encryption` without a password [dry-run]
  - `users` entries without a password [src]
  - btrfs subvolume entries missing `name`/`mountpoint` [src]
  - unknown partition flags (debug log only) [src]
  - unknown profile `details` (info log) [src]
- **Semantic checks happen in the TUI**, not at load (global_menu.py:205-247, 447-495):
  - disk config and kernels set
  - root password or a sudo user present
  - root, boot (flag `boot` + mountpoint) and ESP (flag `esp` + mountpoint, FAT) found
  - bootloader/layout compatibility
  - Shown as a red "Missing configurations / Invalid configuration" preview on the Install item.
- **Not checked before Install** (they fail during the install):
  - package names
  - timezone (warning only)
  - whether `dev_path`/start/size match the real partitions
- **Safe local check:** `archinstall --config cfg.json [--creds c.json] --silent --dry-run --offline` parses everything, writes the normalised result to `/var/log/archinstall/user_configuration.json`, and stops before touching disks (guided.py:213-229). Diff that file against the input to spot dropped sections.

---

## Complete example `user_configuration.json`

Layout:
- Existing `/dev/vda1`: ESP, reformatted FAT32, `/boot`.
- Existing `/dev/vda2`: LUKS + btrfs with subvolumes.
- GRUB, linux, pipewire, NetworkManager, no desktop, Europe/Kyiv, en_US.UTF-8, us.

Before using it:
- The start/size values assume a 40 GiB GPT disk partitioned with 1 MiB alignment (vda1 = sectors 2048..2099199, vda2 = 2099200..83884031). **The script must replace them with the real values from sysfs** (see Q2).
- `disk_encryption` is included for the case where you also pass `encryption_password` via `--creds` (option 2 in Q3). **Without that password this block is dropped** and the user must enable LUKS in the TUI (option 1).
- Users and root password are left for the TUI.

Parsed OK [dry-run]. Installing it was not tested.

```json
{
    "archinstall-language": "English",
    "script": "guided",
    "disk_config": {
        "config_type": "manual_partitioning",
        "device_modifications": [
            {
                "device": "/dev/vda",
                "wipe": false,
                "partitions": [
                    {
                        "obj_id": "hopparch-efi",
                        "status": "modify",
                        "type": "primary",
                        "dev_path": "/dev/vda1",
                        "start": {"value": 2048, "unit": "sectors", "sector_size": {"value": 512, "unit": "B"}},
                        "size": {"value": 1073741824, "unit": "B", "sector_size": {"value": 512, "unit": "B"}},
                        "fs_type": "fat32",
                        "mountpoint": "/boot",
                        "mount_options": [],
                        "flags": ["boot", "esp"],
                        "btrfs": []
                    },
                    {
                        "obj_id": "hopparch-root",
                        "status": "modify",
                        "type": "primary",
                        "dev_path": "/dev/vda2",
                        "start": {"value": 2099200, "unit": "sectors", "sector_size": {"value": 512, "unit": "B"}},
                        "size": {"value": 41873833984, "unit": "B", "sector_size": {"value": 512, "unit": "B"}},
                        "fs_type": "btrfs",
                        "mountpoint": null,
                        "mount_options": ["compress=zstd"],
                        "flags": [],
                        "btrfs": [
                            {"name": "@", "mountpoint": "/"},
                            {"name": "@home", "mountpoint": "/home"},
                            {"name": "@log", "mountpoint": "/var/log"},
                            {"name": "@pkg", "mountpoint": "/var/cache/pacman/pkg"},
                            {"name": "@snapshots", "mountpoint": "/.snapshots"}
                        ]
                    }
                ]
            }
        ],
        "disk_encryption": {
            "encryption_type": "luks",
            "partitions": ["hopparch-root"],
            "lvm_volumes": []
        }
    },
    "bootloader_config": {"bootloader": "Grub", "uki": false, "removable": false},
    "kernels": ["linux"],
    "app_config": {"audio_config": {"audio": "pipewire"}},
    "network_config": {"type": "nm"},
    "profile_config": {"profile": {"main": "Minimal"}, "gfx_driver": null, "greeter": null},
    "locale_config": {"kb_layout": "us", "sys_lang": "en_US.UTF-8", "sys_enc": "UTF-8", "console_font": "default8x16"},
    "timezone": "Europe/Kyiv",
    "ntp": true,
    "hostname": "archlinux",
    "swap": {"enabled": true, "algorithm": "zstd"},
    "pacman_config": {"parallel_downloads": 5, "color": true},
    "packages": ["git", "base-devel"],
    "services": [],
    "custom_commands": []
}
```

Optional companion `creds.json` (only for option 2 in Q3; tmpfs, delete after):
```json
{"encryption_password": "<typed by the user in the hopparch script>"}
```

Windows-ESP variant: in partition 1 set `"status": "existing"` and keep `"fs_type": "fat32"`, `"flags": ["boot","esp"]`, `"mountpoint": "/boot"`. Keep `"removable": false`.

---

## Gotchas summary
1. `disk_encryption` without `encryption_password` is **silently dropped**, and the TUI does not warn.
2. `modify` = delete + recreate the partition entry + format. start/size/flags must match reality. **Never** use `"wipe": true` on a disk with Windows.
3. `sector_size` must be an object, not `null`. `Percent` is not a unit. `dev_path`, `mountpoint` and `mount_options` keys are mandatory in every partition.
4. `gfx_driver` does nothing with the Minimal profile, so put driver packages in `packages`.
5. `custom_commands` run as root in the chroot before genfstab. A failing command aborts the install.
6. `removable` defaults to **true** when a `bootloader_config` omits it.
7. Snapper (`btrfs_options`) conflicts with a user-made `@snapshots` at `/.snapshots` [NOT VERIFIED at runtime].
8. `archinstall-language` is read with a hyphen but saved with an underscore, so a saved config loses the language (cosmetic).

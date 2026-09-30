# hopparch test report 1 (2026-09-30)

Tested live in the test VM (Hyprland 0.56.2, 742x776 at scale 1, user `test`), with keys sent through QEMU,
grim screenshots and read-only hyprctl/ssh. The config deployed in the VM matched the repo byte for byte
(sha256 of all 8 `config/` files and `system/etc/greetd/config.toml`).
**Result: 20 pass, 2 fail, 6 not tested.**

Note: the VM was installed at 04:20 with an **older install.sh**. Its archinstall log has an `@snapshots`
subvolume and no Snapper. The current `install.sh` (Snapper option, creds file, etc.) has **not** been
run end to end. See issue 3.

---

## 1. Feature results

| # | Feature | Result | Evidence |
|---|---|---|---|
| 1 | Hyprland + Lua config load cleanly | PASS | `configerrors` empty, 40 binds, no Hyprland-level ERR/WARN in hyprland.log (only aquamarine VM noise) |
| 2 | Plain look (2px cream focus border, no anim/blur/shadow/rounding, black bg) | PASS | getoption: border_size 2, animations off, rounding 0, active border `ffe8e4dc`; screenshots show cream on the focused window, grey on the others, black gaps |
| 3 | SUPER+Return, kitty single instance | PASS | 3 windows, all pid 4080 (`kitty -1`) |
| 4 | SUPER+D fuzzel, launching works | PASS | fuzzel layer 414x436 centred; typing `neov`+Enter started nvim |
| 5 | Launcher hides the stashed entries | PASS | empty query lists only kitty, Thunar, btop++, Firefox, Neovim; `bulk`, `avahi` and `pref` match nothing |
| 6 | SUPER+B firefox | PASS | tiles into the dwindle split at 355x359, fullscreen 0 |
| 7 | SUPER+F thunar | PASS | opens tiled. It is light-themed, see issue 8 |
| 8 | CTRL+ALT+Del btop: float + pinned | PASS | `float True pin True`, centred at 148,129; still shown after SUPER+2 |
| 9 | btop fits ≥80x24 cells | **FAIL** | window 446x544 px → btop shows "Terminal size too small: Width = 43 Height = 24 / Needed 80x24" |
| 10 | SUPER+Q close | PASS | only the focused window closes, kitty process stays |
| 11 | SUPER+H/J/K/L focus | PASS | active window followed left/down/up/right correctly |
| 12 | SUPER+SHIFT+H/J/K/L move | PASS | the window swapped positions in all 4 directions |
| 13 | SUPER+CTRL+H/J/K/L resize, hold repeats | PASS | ±40 px per press; holding 2 s grew the width 355→682 (layout limit) |
| 14 | SUPER+1..9 | PASS | tested 1, 2, 9 |
| 15 | SUPER+SHIFT+1..9 | PASS | the window moves there. **The view also follows it** (active ws became 2/9), same as in Ysayrch. Say if you want "silent" instead |
| 16 | SUPER+SHIFT+R reload | PASS | runtime `border_size=6` (via `hyprctl eval`) went back to 2 after the key; waybar not duplicated |
| 17 | SUPER+SHIFT+E power menu | PASS | Sleep/Logout/Restart/Shutdown shown; Esc leaves no process; Logout → "Logout?" with No preselected → No does nothing |
| 18 | `no-self-maximize` | PASS | `kitty --start-as=maximized` tiled at 173x175; a kitty opened after Firefox tiled normally; no workspace had fullscreen |
| 19 | Waybar clock + power icon shown | PASS | top-right: `Wed 30-09-2026 08:12  ⏻`, bar 26 px, reserved area correct |
| 20 | fish `ls`/`ll`/`la` | **FAIL** | `ls /etc/greetd` → `error: invalid value '/etc/greetd' for '--icons [<WHEN>]'`. Without arguments they work |
| 21 | fish `cat`→bat, zoxide `cd`, fzf Ctrl+R/Ctrl+T | PASS | `type cat` = bat alias; `zoxide query share` → /usr/share; Ctrl+R opens the history list (cosmetic: raw epoch timestamps like `1790744374` in front of each line) |
| 22 | nvim base options | PASS | `:set` showed number, relativenumber, expandtab, ts/sw/sts=4, undolevels=10000, undofile, termguicolors |

**Not tested:**
- **Login screen** (greetd + tuigreet, username pre-filled) and **Logout → Yes → log back in**. Skipped on the wrap-up order.
- **Power icon click** on the bar. I couldn't send pointer events: HMP `mouse_move` is relative and went to the PS/2 mouse the guest ignores. The `on-click` config itself looks right.
- Mouse binds (SUPER+LMB/RMB drag) and the actual click-to-focus behaviour. `follow_mouse = 0` is set.
- Sleep/Restart/Shutdown, not selected by rule. Only the menu and the Logout confirm were tested.

The VM was left with one kitty on workspace 1 and no other apps. After that it was stopped from outside
(qemu is gone). I did not power it off.

---

## 2. Efficiency

Idle with 2 kitty windows: **655 MiB used / 3.9 GiB**, swap (zram) unused.

PSS per component (RSS double-counts shared libs):

| Component | PSS MiB | Note |
|---|---|---|
| Hyprland | 116 | |
| kitty (1 process for all windows) | 71 | |
| kitten `__watch_conf__` + `__atexit__` | 24 + 24 | **helpers kitty starts for every kitty process.** The single instance keeps this to one pair, but see issue 6 |
| waybar | 32 | clock has no seconds → 1 update/min, fine |
| Xwayland | 30 | running with **zero X clients** (every current app is Wayland-native). Keep it for Steam (full profile); for minimal it's 30 MB for nothing |
| xdg-desktop-portal-hyprland + portal + document/permission store | 14 + 5 + 3 | |
| pipewire + wireplumber | 3 + 9 | |
| at-spi bus + registry | ~3.5 | started by GTK apps, negligible |
| xfconfd | 1 | lingers after Thunar closes, negligible |
| Firefox (1 new tab) | ~370 system-wide | used memory went 655 → 1027 MiB |

- **System services running:** dbus, greetd, NetworkManager, sshd, journald, logind, timesyncd, udevd, userdbd. This is minimal. `sshd` comes from the VM rig, not from `setup.sh`, so real installs don't have it.
- **Timers:** only the Arch defaults (tmpfiles-clean, shadow daily, keyring weekly). No user timers. Nothing polls.
- **Idle wake-ups over 20 s:** Hyprland 58 (~3/s), kitten `__atexit__` 8, xdph 8. Everything else was kernel threads. The idle desktop is quiet.
- **What the *current* install.sh would add** (untested in VM, read from archinstall 4.4 source `lib/installer.py:992-1029`): `snapper-timeline.timer` (hourly snapshots of **both / and /home**), `snapper-cleanup.timer`, and `grub-btrfsd.service` (a daemon watching `/.snapshots` via inotify). This contradicts DESIGN §6. See issue 3.

---

## 3. Issues, most important first

### 1. `ls <path>` is broken (daily use)
`config/fish/config.fish:7-9`. eza 0.23 treats `--icons` as taking an optional value, so the next argument
is parsed as WHEN: `ls somedir` errors. `ls -l dir` only works by luck, because a flag follows `--icons`.
**Fix:** `--icons=auto` in all three aliases.

### 2. btop does not fit 80x24, and the fraction sizing is fragile everywhere
`config/hypr/hyprland.lua:79` `size = { "monitor_w*0.6", "monitor_h*0.7" }`. In the VM this gives 43x24 cells
(one kitty cell is ≈10.2 x 22.3 logical px at font 12). Estimated elsewhere, with the same cell size:
- 1080p at scale 1.25 (1536x864 logical): ≈89x26. Passes, just barely.
- 1080p at scale 1.5, which `scale = "auto"` may pick on a 14" panel: ≈74x22. **Fails.**
- 1366x768 at scale 1 (typical "weak laptop" for the minimal profile): ≈79x23. **Fails.**

The VM screen (742 px wide) can't fit 80 cells at font 12 at all.

This is the same approach that already broke on the 1080p laptop.
**Fix:** size the window in cells, not in % of the monitor:
- drop `size` from the rule, keep float + pin (+ center);
- launch btop in its own kitty: `kitty --class btop -o initial_window_width=82c -o initial_window_height=26c -o remember_window_size=no -e btop`;
- optionally add `-o font_size=10` so it also fits small screens.

A separate process costs about 100 MB while btop is open. `-o` overrides may be ignored with `-1`, so verify before combining them.

Minor: pressing CTRL+ALT+Del again opens a **second** btop instead of focusing or closing the first.

### 3. install.sh: the Snapper preset does the opposite of the design, and is untested
`install.sh:270` `"btrfs_options": {"snapshot_config": {"type": "Snapper"}}`. archinstall 4.4 then:
- creates snapper configs for **root and home**;
- enables the **hourly timeline** and cleanup timers;
- installs `grub-btrfs` and `inotify-tools` and enables the `grub-btrfsd` daemon;
- does **not** install `snap-pac`, so there are **no pre/post pacman snapshots**.

DESIGN §6 wants the reverse: only pacman snapshots, keep a few, no timeline. Hourly `/home` snapshots also
grow the disk with every download.

The VM never ran this path. It was installed with the older `@snapshots` config and has no snapper
(`pacman -Q snapper` → not found).

**Fix:** remove `btrfs_options` from the archinstall preset. In `setup.sh` instead:
- install `snapper snap-pac grub-btrfs`;
- `snapper -c root create-config /` for root only;
- set `TIMELINE_CREATE="no"` and `NUMBER_LIMIT="5"`;
- skip `grub-btrfsd` and regenerate the menu from a pacman hook, or accept the daemon.

### 4. The "any machine" parts are asked for but not used
- `install.sh:118-129`: the minimal/full **profile question has no effect**. `PROFILE` is never read, and both profiles get the same packages. The user is asked a question that does nothing. Either wire it or remove the prompt until full exists.
- `install.sh:203`: **every** NVIDIA GPU gets `nvidia-open`. Maxwell/Pascal cards (GTX 9xx/10xx) are not supported by it, so on those machines Hyprland gets no working driver. DESIGN §3 says to detect them and ask. Check the PCI device ID (or fall back to `nouveau`/mesa and warn).
- No NVIDIA environment is written anywhere. The Hyprland wiki's `LIBVA_DRIVER_NAME=nvidia` and `__GLX_VENDOR_LIBRARY_NAME=nvidia` are missing, and hybrid laptops must *not* get them. Nothing is broken today, but this is where a real NVIDIA desktop will need work.
- `LAPTOP` and `WIFI` are detected but unused: no brightness keys, battery or idle→sleep yet (planned, just listing it).

### 5. install.sh: archinstall failures are swallowed
`install.sh:318` runs `archinstall … || true`. The guard at `:326` checks `/mnt/home/$USERNAME`, but
archinstall creates users **before** it installs packages, the bootloader and snapper (notes Q7). A failure
after that point, such as a bad package name or the Snapper `DiskError`, still passes the check, and
`setup.sh` then runs on a half-installed system.
**Fix:** keep archinstall's exit code (`rc=0; archinstall … || rc=$?`). If it's non-zero, ask before continuing.
Also check for `/mnt/etc/fstab` and `/mnt/boot/grub/grub.cfg`.

Also, `install.sh:343` says "log in, type: start-hyprland". That's outdated: greetd starts Hyprland now.

### 6. Terminal apps from the launcher start a second kitty process
`config/fuzzel/fuzzel.ini:4` has `terminal=kitty`. Starting Neovim or btop++ from SUPER+D started
`kitty nvim` as a new process: pid 6818, about 97 MB RSS plus another 33 MB `__watch_conf__` kitten.
btop++ launched this way also lacks the `btop` class, so it tiles instead of floating.
**Fix:** `terminal=kitty -1`.

### 7. kitty: no keyboard scrollback
`config/kitty/kitty.conf:15`: `clear_all_shortcuts yes` also removes scrollback (ctrl+shift+up/down/page_up/page_down/home/end)
and the scrollback pager. That breaks the "keyboard must fully operate everything" rule: output that
scrolled away can only be reached with the mouse wheel.
**Fix:** add e.g.
```
map shift+page_up   scroll_page_up
map shift+page_down scroll_page_down
map ctrl+shift+h    show_scrollback
```

### 8. No dark-mode signal to apps: Firefox and Thunar are light, and the cream border vanishes on them
kitty logs `No such interface "org.freedesktop.portal.Settings"`. xdg-desktop-portal-hyprland doesn't
implement the Settings portal, and nothing else is installed to provide it. Firefox and Thunar therefore
render light (see the Firefox and Thunar screenshots). A cream `#e8e4dc` border on a light-grey Firefox is
almost invisible, which defeats "focused window = cream border".
**Fix:**
- add `xdg-desktop-portal-gtk` to `setup.sh:32`;
- set `color-scheme=prefer-dark` (dconf/gsettings for the user);
- add `gtk-application-prefer-dark-theme=1` in `~/.config/gtk-3.0/settings.ini`.

This gets closer to the "one fixed 0xyc look" and also gives Firefox a proper file-chooser portal.

The same log shows `Notify: … ServiceUnknown`, which just means no notification daemon yet (mako is planned).

### 9. setup.sh copies scripts executable only if git preserved the +x bit
`setup.sh:53-54`: `mode=644; [[ -x $src ]] && mode=755`. If the repo arrives without the +x bit (zip
download, `core.fileMode=false`, or edited on Windows), `power-menu.sh` is installed 644. Then SUPER+SHIFT+E
and the bar icon **silently do nothing**, because both exec it directly (`hyprland.lua:63`, `waybar/config.jsonc:17`).
**Fix:** force 755 for `config/scripts/*`, or call it as `bash …/power-menu.sh` in both places.

### 10. Thunar is missing its usual helpers (for real machines)
`setup.sh:32-36` installs `thunar` but not `gvfs` (Trash, USB and phone mounts in the sidebar), `udisks2`,
or a polkit agent. On a laptop a plugged-in USB stick won't appear in Thunar, and there is no Trash.
I could not verify this in the VM because it was stopped. Neither setup.sh nor the Minimal profile installs
these packages.
**Fix:** add `gvfs` (it pulls in udisks2) and a small polkit agent such as `hyprpolkitagent`, started in `hyprland.start`.

### 11. Power menu details
`config/scripts/power-menu.sh:9`:
- **Sleep is the preselected item.** One stray Enter suspends, and with no lock screen yet (planned) the laptop wakes **unlocked**.
- Put Logout/Lock first, or add Lock at the top once hyprlock exists.
- Add `--lines 4` (and `--lines 2` for the confirm) so the box isn't 436 px tall for 4 entries.

### 12. Smaller things
- `hyprland.lua`: empty workspaces show Hyprland's random splash text ("@vaxry how do i learn c++" - flicko). Set `misc.disable_splash_rendering = true` until the custom splash is decided (DESIGN §5).
- `hyprland.lua:55-107`: no bind has a description (`hyprctl binds` shows `__lua N`). The planned live cheatsheet (SUPER+SHIFT+/) reads descriptions, so adding them now saves a pass later.
- `hyprland.lua:13-15`: waybar is started once and never restarted if it crashes. A `while` loop or a user service would handle that. Low priority.
- `setup.sh:62` (`copy_config`): files deleted from `config/` in the repo are never removed from `~/.config` or the state dir. Stale config lingers. Low priority now, will matter once files get renamed.
- `setup.sh:74-75` (`stash_apps`): `tee` overwrites a user's *own* same-named override in `~/.local/share/applications`. Only files carrying the stash marker are cleaned, but any file gets overwritten. Skip the write if a non-marker file exists.
- `install.sh:45`: an ICMP `ping` is the internet check. Some networks (hotel or campus Wi-Fi) block ICMP and would get a false "no internet". `curl -sfI https://archlinux.org` is more reliable.
- `install.sh:302-312`: the `trap … shred` is set *after* `creds.json` is written. Set it before. (`shred` on the ISO's tmpfs is theatre but harmless.)
- `config/fish/config.fish:3`: `fish_add_path` writes the universal `fish_user_paths` on first run. `fish_add_path -g ~/.local/bin` keeps it in config only, which matches "config is copied, local state doesn't matter".
- fzf Ctrl+R shows raw epoch timestamps in front of each command. Cosmetic, probably a fzf/fish 4 version mismatch in the history widget.

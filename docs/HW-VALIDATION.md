# PowOS Hardware Validation Checklist

One-stop checklist of every feature that is **implemented but not yet
validated on real hardware**. Each item has exact steps, an expected
outcome, and a note on where to report the result.

> **Goal:** run through this once on the real machine, check boxes, then
> update the feature-status table in `CLAUDE.md` and remove the relevant
> `TODO(hw)` comments from the source.

When a check passes, open a PR that:
1. Checks the box (replace `[ ]` with `[x]`).
2. Removes the matching `TODO(hw)` comment in the source file.
3. Updates the feature-status row in `CLAUDE.md`.

---

## How to run

```bash
# Fast tier-1 (Docker, ~30 s) — run first
docker compose up --build -d
docker exec powos bash /var/lib/powos/src/test/tier1/test-self.sh
docker exec powos bash /var/lib/powos/src/test/tier1/test-hardware-detect.sh
# ... other tier-1 tests

# Staged hardware validator (needs real disk / VM)
./build/validate.sh
sudo ./build/validate.sh --all   # + image build + QEMU boot smoke
```

The items below are what `validate.sh --all` **cannot** cover.

---

## 1. Layer sync — `--delete` behaviour after a delete-after fix

**Files:** `lib/ramfs/layer-sync.py:14`, `lib/ramfs/overlay-mount.sh:189`

**Background:** an earlier version used `rsync --delete-after`, which
wiped the custom layer on the first sync. The fix removed `--delete` from
`layer-sync.py` entirely (the RAM upper is a fresh tmpfs each boot, so
deletions can't accumulate). `overlay-mount.sh` still uses `--delete` in
its two-stage sync (pending → final), which is correct there.

**Steps:**
1. Boot the real system with `rd.powos.ramboot=1` (USB overlay model).
2. Create a file: `echo hello > ~/test-hw-layer-sync.txt`
3. Wait 90 s (or run `python3 /usr/lib/powos/layer-sync.py --sync-now`).
4. `ls /var/lib/powos/layers/custom/home/powos/` — should contain
   `test-hw-layer-sync.txt`.
5. Delete the file: `rm ~/test-hw-layer-sync.txt` and wait another 90 s.
6. Reboot. After boot: `ls ~/test-hw-layer-sync.txt` should give
   "No such file". If it reappears, `--delete` is still missing.
7. Also verify the custom layer itself is **not** empty after step 4
   (the old bug: entire custom layer wiped on first sync).

**Expected:** file persists across sync (step 4 ✓), deletion propagates
across reboot (step 6 ✓), custom layer grows not shrinks.

- [ ] Two-way layer sync works (create + delete survive reboot)

---

## 2. RAM boot (USB overlay model) — `rd.powos.ramboot=1`

**Files:** `lib/dracut/90powos-ramboot/ramboot-setup.sh:76`,
`lib/dracut/90powos-ramboot/ramboot-setup.sh:152`

**Background:** the live-USB model was broken on real hardware (NEWROOT
no-op — the overlayfs root pivot never happened, leaving the box booting
from USB directly instead of RAM). `NEWROOT` handling was fixed; needs
validation.

**Steps (USB model — boot from the live USB):**
1. Flash `powos.raw` to a USB stick.
2. Boot from it on the target machine.
3. `cat /proc/cmdline | grep rd.powos.ramboot` — should show `1`.
4. `cat /run/powos/ramboot-state` — should confirm `RAMBOOT=1`.
5. Unplug the USB while the desktop is running.
6. The desktop must remain usable (it's running from RAM, not USB).
7. Plug the USB back in and run `powos sync` — must detect no conflict.

**Expected:** overlay stack active, USB removable mid-session.

- [ ] USB overlay model boots and runs from RAM
- [ ] USB can be unplugged without losing the desktop session

---

## 3. RAM boot (installed model) — `rd.powos.ramboot.installed=1`

**Files:** `lib/dracut/90powos-ramboot/ramboot-setup.sh:79`

**Background:** the installed OS-in-RAM model (`powos ramboot enable`)
was blocked separately from the USB overlay model to avoid a
composefs-on-composefs boot loop. Needs validation on a disk install.

**Steps:**
1. Install PowOS to disk (Anaconda ISO path, see §5).
2. After first boot: `sudo powos ramboot enable`.
3. Reboot: `cat /proc/cmdline | grep ramboot.installed` — must show `1`.
4. `cat /run/powos/ramboot-state` — verify OS-in-RAM mode.
5. Verify the self-heal counter works:
   - Manually set `<esp>/powos/ramboot-attempts` to 3.
   - Reboot: should fall back to normal disk boot automatically.
   - `sudo powos ramboot reset` then reboot normally.

**Expected:** OS copies to tmpfs on boot; self-heal kicks in after 3
failures and restores normal disk boot.

- [ ] `powos ramboot enable` on installed system survives a reboot
- [ ] Self-heal counter (3 failures → auto-fallback) works

---

## 4. Dual-boot alongside install (`--alongside`)

**Files:** `lib/install-system.sh:592`, `lib/install-system.sh:715`

**Background:** `bootc install to-filesystem` (reuse Windows ESP, carve
free space) is EXPERIMENTAL. The whole-disk path (`bootc install to-disk`)
is the tested path.

**Steps (VM with Windows pre-installed):**
1. Install Windows 11 to a VM disk (leave 80+ GB free after).
2. Boot PowOS live USB in the same VM.
3. `sudo powos install-system --alongside --dry-run` — review the plan;
   must show the free block and the existing ESP without touching Windows.
4. `sudo powos install-system --alongside` — confirm at each prompt.
5. Reboot: UEFI boot menu (F12) must list **both** OSes.
6. Boot Windows: C:/ data intact, RTC local time.
7. Boot PowOS: `powos status` shows the layered stack.
8. `timedatectl` on PowOS → local time (matches Windows clock).

**Expected:** both OSes boot; Windows data intact; clock sync.

- [ ] `--alongside` finds free block without touching Windows partitions
- [ ] UEFI boot menu lists both OSes after install
- [ ] Windows still boots with data intact
- [ ] RTC local time set correctly

---

## 5. Anaconda ISO — Anaconda installer end-to-end

**Files:** `build/build-iso.sh:422`

**Background:** this is the CANONICAL install path but it's only been
validated in CI (build + boot check). A real human needs to click through
the Anaconda GUI on physical hardware.

**Steps:**
1. Build: `./build/build-iso.sh` (or `just installer`).
2. Flash `install.iso` to a USB with Balena Etcher / Rufus.
3. Boot from USB on the target machine.
4. Anaconda GUI loads — select disk, set user/password, install.
5. Remove USB, reboot to the installed system.
6. `powos status` — layered stack present.
7. `powos backup pull` — config restores.

**Expected:** installer completes without errors; PowOS boots from disk.

- [ ] Anaconda ISO boots on real hardware
- [ ] Installation completes without errors
- [ ] System boots from disk after USB removed
- [ ] `powos backup pull` restores config

---

## 6. Games partition + Steam Deck sync (`powos games`)

**Files:** `lib/games.sh`, `test/e2e/INSTALL-VALIDATION.md`

**Steps:**
1. `powos games status` on a fresh install — should report POWOS-GAMES.
2. If missing: `powos games create --size 200 --dry-run` (prints plan,
   no changes), then `powos games create --size 200`.
3. `powos games mount` — mounts at `/var/mnt/games` via ntfs3.
4. `powos games steam-setup` — adds the library; verify Steam closed first.
5. Install one game to the POWOS-GAMES library.
6. **Steam Deck:** connect Deck to the same network, install PowOS there,
   point Steam to the same POWOS-GAMES partition (or NFS share), verify
   the game appears in Deck's library.
7. On Windows (dual-boot or VM): confirm POWOS-GAMES shows a drive letter
   and NO "format this disk?" dialog for other PowOS partitions.

**Expected:** game installed once is visible in Steam on both machines;
Windows sees POWOS-GAMES without GPT confusion.

- [ ] `powos games create` creates NTFS partition correctly
- [ ] `powos games mount` mounts via ntfs3
- [ ] `powos games steam-setup` wires up the library
- [ ] Game installed once visible on both PowOS and Steam Deck
- [ ] Windows sees the partition with no "format disk?" prompt

---

## 7. GPU hotswap (`powos gpu to-vm` / `to-host`)

**Files:** `lib/dev-commands.sh:1169`

**Prerequisites:** IOMMU on, desktop on iGPU, dGPU idle (not driving
the active display), a KVM guest running.

**Steps:**
1. `powos gpu status` — shows dGPU on host, readiness check.
2. Start a Windows VM (without GPU): `powos vm windows`.
3. `sudo powos gpu to-vm` — passes dGPU to the VM via vfio.
4. In the VM: Device Manager should list the dGPU.
5. `sudo powos gpu to-host` — reclaims the dGPU back to the host.
6. Verify CUDA / gaming on the host works again.

**Expected:** dGPU hot-migrates between host and VM without a reboot; no
GPU freeze on the host display (because desktop is on iGPU).

⚠️ Keep a TTY/SSH session open the first time — if the GPU driving the
display is hotswapped out, the session freezes.

- [ ] `powos gpu to-vm` passes dGPU to a running VM
- [ ] `powos gpu to-host` reclaims dGPU without reboot
- [ ] Host display (iGPU) unaffected during passthrough

---

## 8. Bare-metal Windows on VHDX (`powos windows`)

**Files:** `lib/windows.sh:48` (whole file is EXPERIMENTAL)

**Steps:**
1. `powos windows status` — clean state on a fresh install.
2. `powos windows create --size 100 --dry-run` — plan, no changes.
3. `powos windows create --size 100` — creates thin VHDX on POWOS-GAMES.
4. `powos windows install --iso <path-to-Win11.iso>` — EXPERIMENTAL:
   Windows Setup runs in QEMU into the VHDX. Monitor for completion.
5. `powos windows finalize` — host firmware entry created.
6. `powos boot windows` — reboots into bare-metal Windows from VHDX.
7. Windows desktop reaches: confirm cold-boot (no resume from VHD).
8. **Anti-cheat test (load-bearing):** launch an EAC/BattlEye title
   (e.g. Rust, Dead by Daylight) on the VHDX install — it MUST load.
   If it fails on a clean slim, the bare-metal path is broken.
9. `powos windows vm` — boots the same VHDX as a KVM guest (session
   resume OK in VM mode; no bare-metal resume by design).
10. Games installed on POWOS-GAMES appear on both OS boots.

**Expected:** cold native VHD boot reaches Windows desktop; anti-cheat
titles run; VM boot of same VHDX works.

- [ ] `powos windows create` creates thin VHDX on POWOS-GAMES
- [ ] `powos windows install` runs Windows Setup unattended
- [ ] `powos windows finalize` creates firmware entry
- [ ] Native VHD boot reaches Windows desktop (cold boot)
- [ ] EAC/BattlEye title runs on the VHD install (anti-cheat test)
- [ ] `powos windows vm` boots the same VHDX as KVM guest

---

## 9. Mods — verify on a real game (`steam -applaunch` + shim)

**Files:** `lib/mods/harness.sh`, `lib/mods/deploy.sh:195`

**Steps:**
1. Pick a moddable game that supports Nexus/manual mods (e.g. Skyrim SE,
   Stardew Valley, Baldur's Gate 3).
2. `powos mods install <game>` — install a known-good mod.
3. `powos mods verify setup <game>` — injects `powos-game-shim %command%`
   into Steam launch options.
4. `powos mods verify <game>` — runs `steam -applaunch <appid>` and
   waits for the game PID; shim sources the mod env.
5. Game launches: visually confirm the mod is active (changed texture /
   UI element / item in inventory).
6. `powos mods verify history <game>` — verdict JSON shows PASS.
7. `powos mods remove <game>` — uninstall the mod; verify it's gone
   in-game on next launch.

**Expected:** mod active in-game, verify harness detects game PID, verdict
recorded as PASS.

- [ ] `powos mods install` deploys a mod to POWOS-GAMES overlay path
- [ ] `powos mods verify setup` injects the shim into Steam
- [ ] `steam -applaunch` path works (shim intercepts game launch)
- [ ] Mod visible in-game (visual confirmation)
- [ ] `powos mods verify` records PASS verdict
- [ ] `powos mods remove` cleanly removes the mod

---

## 10. Mods overlay — deploy on a real game

**Files:** `lib/mods/deploy.sh`, `lib/mods/core.sh`

**Steps:**
1. After §9 passes, verify the overlay mechanism independently:
2. `powos mods status <game>` — shows overlay_mounted = true.
3. `ls <game-dir>/mods/` (mounted overlay) — mod files visible.
4. `powos mods disable <game>` — unmount overlay; `ls` shows clean game dir.
5. `powos mods enable <game>` — re-mount; files back.
6. Reboot: `powos mods status <game>` — overlay persists (auto-mounted).

**Expected:** overlay mounts/unmounts cleanly; survives reboot.

- [ ] `powos mods enable/disable` toggles overlay correctly
- [ ] Overlay auto-remounts after reboot

---

## 11. PowStream — `powos stream setup` (portal token) + connect

**Files:** `lib/stream.sh`

**Background:** `powos stream setup` opens the KDE screencast portal
consent dialog on the PHYSICAL monitor. This is invisible to a remote
user and must be done once locally. Needs a real desktop environment.

**Steps (on the machine with a physical display):**
1. `powos stream status` — shows portal token: missing.
2. `powos stream setup` — a KDE "Allow screen recording?" dialog appears
   on the physical monitor. **Approve it.**
3. `powos stream status` — portal token: present (`~/.config/powstream/
   portal-restore-token`).
4. `powos stream start` — WebRTC server starts on port 8080.
5. On the same LAN, open `http://<powos-ip>:8080/` in a browser.
6. Stream connects: latency < 200 ms, audio works (PipeWire).
7. `powos stream stop` — service stops cleanly.
8. Reboot: `powos stream start` — token reused, no consent dialog.

**Expected:** one-time consent dialog; subsequent streams silently reuse
the token; sub-200 ms latency on LAN.

- [ ] `powos stream setup` shows consent dialog on physical display
- [ ] Portal token saved to `~/.config/powstream/portal-restore-token`
- [ ] `powos stream start` starts the WebRTC server
- [ ] Browser on LAN connects and receives the stream
- [ ] After reboot: stream starts without consent dialog

---

## 12. PowCompanion — mixer / radar / frametime on desktop

**Project:** `~/Projects/PowCompanion` (separate repo)

**Background:** PowCompanion is a tablet/second-screen control surface
(Express + React/Astro) with a PipeWire per-app mixer, audio radar, and
performance time-series. Needs a running desktop + real game.

**Steps:**
1. `cd ~/Projects/PowCompanion && docker compose up -d`
2. Open `http://powcompanion.pow/` (or `http://localhost:PORT/`) on a
   tablet or browser.
3. **Mixer:** open a game + a music player. Mixer tab should list both
   with per-app volume sliders. Adjust; verify volume changes in-app.
4. **Radar:** audio radar tab shows real-time spatial audio activity.
   Play a sound; radar must react.
5. **Frametime:** start a game. Frametime graph updates every frame
   (60 fps game = ~16.6 ms average).
6. **Macro deck:** bind a key to an action (e.g. push-to-talk). Trigger
   it from the tablet; action fires on the desktop.

**Expected:** all four tabs functional with a real game + audio running.

- [ ] Per-app PipeWire mixer shows and controls running apps
- [ ] Audio radar reacts to sound events
- [ ] Frametime graph shows live game data
- [ ] Macro deck keys trigger desktop actions

---

## 13. KDE Plasma widgets — `com.powos.monitor` + `com.powos.overview`

**Files:** `desktop/plasmoid/`

**Background:** the monitor widget (GPU/CPU/RAM/network live graphs) and
overview widget are auto-added to the Plasma panel on first login.
Needs real hardware with a GPU.

**Steps:**
1. First login after install: panel should show both widgets (no manual
   add needed — `powos-widget-autoadd` handles it).
2. `com.powos.monitor`: GPU util / VRAM / temp / power should show live
   readings (not all zeros, not `N/A`).
3. Resize the widget; verify the graphs scale.
4. `com.powos.overview`: verify it opens and shows correct system state.

**Expected:** widgets auto-appear; GPU metrics live; no crashes on resize.

- [ ] Widgets auto-added to panel on first login
- [ ] Monitor widget shows live GPU/CPU/RAM metrics (not zeros)
- [ ] Overview widget opens without errors

---

## 14. Mobile mode — live remount (no reboot) — ⚠️ WIP

**Files:** `lib/mobile.sh:441`

**Background:** `powos mobile enable` copies OS files to a RAM layer but
the live overlayfs remount is NOT implemented — a reboot is required.
Validate the post-reboot state at minimum.

**Steps:**
1. `powos mobile enable` — copies files to RAM layer.
2. **Reboot** (live remount not implemented; reboot is the workaround).
3. `powos mobile status` — should show mobile mode active.
4. Unplug the USB; verify OS operations continue (web browser, terminal).
5. `powos mobile disable` → reboot; verify return to USB-backed mode.

**Expected:** OS functions with USB unplugged after reboot into mobile mode.

- [ ] `powos mobile enable` + reboot activates mobile mode
- [ ] OS operational with USB unplugged in mobile mode
- [ ] `powos mobile disable` returns to USB-backed mode

---

## 15. `powos ramboot` self-heal counter

**Files:** `docs/BOOT-ARCHITECTURE.md`, `lib/dracut/90powos-ramboot/`

**Steps:**
1. `sudo powos ramboot enable` on installed system.
2. Manually set `<esp>/powos/ramboot-attempts` to 3.
3. Reboot: initramfs should auto-skip ramboot, boot from disk normally.
4. `cat /proc/cmdline` — must NOT contain `rd.powos.ramboot.installed=1`.
5. `sudo powos ramboot reset` — clears the counter.
6. Reboot again: ramboot active (counter cleared).

- [ ] Counter at 3 → auto-fallback to disk boot
- [ ] `powos ramboot reset` clears counter and restores ramboot

---

## Summary table (copy to CLAUDE.md when done)

| Feature | TODO(hw) file(s) | Status |
|---------|-----------------|--------|
| Layer sync (delete fix) | `lib/ramfs/layer-sync.py:14` | [ ] |
| Ramboot USB overlay | `ramboot-setup.sh:76,152` | [ ] |
| Ramboot installed OS-in-RAM | `ramboot-setup.sh:79` | [ ] |
| Dual-boot `--alongside` | `install-system.sh:592,715` | [ ] |
| Anaconda ISO on real hardware | `build-iso.sh:422` | [ ] |
| Games partition + Steam Deck sync | `lib/games.sh` | [ ] |
| GPU hotswap | `lib/dev-commands.sh:1169` | [ ] |
| `powos windows` (VHDX) | `lib/windows.sh:48` | [ ] |
| Mods verify (steam -applaunch) | `lib/mods/harness.sh` | [ ] |
| Mods overlay deploy | `lib/mods/deploy.sh:195` | [ ] |
| PowStream setup + connect | `lib/stream.sh` | [ ] |
| PowCompanion mixer/radar/frametime | `~/Projects/PowCompanion` | [ ] |
| KDE Plasma widgets | `desktop/plasmoid/` | [ ] |
| Mobile mode (reboot path) | `lib/mobile.sh:441` | [ ] |
| Ramboot self-heal counter | `docs/BOOT-ARCHITECTURE.md` | [ ] |

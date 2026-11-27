# PS5 Remote Play on PowOS

Play the PS5 on a PowOS phone or desktop. The client is **chiaki-ng** (github.com/streetpea/chiaki-ng, AGPL-3.0),
used as upstream ships it; PowOS installs it, keeps it on upstream's latest stable, finds the PS5 and explains the
one-time pairing. Nothing of chiaki-ng's source is vendored into this repo.

The user's setup: the PS5's own DualSense stays paired to the PS5; the phone is only the screen ("screen only").
A controller connected to the phone works too. Streaming goes straight over the LAN or WireGuard; PSN is used once,
during registration, to read the account ID.

## Decisions (2026-11-27)

| question | decision | why |
|---|---|---|
| Desktop package | Flathub `io.github.streetpea.Chiaki4deck` (upstream's own Flatpak, 1.10.1 = the GitHub release) | No build on our side; Bazzite already has Flathub; `flatpak update` gives "latest", `--commit=` gives rollback |
| Phone package | chiaki-ng's **Android app** (`android/` in the upstream tree, built as applicationId `dev.powos.chiaki`, label "PS5", fileprovider `dev.powos.chiaki.fileprovider`) | Works on non-root phones (it's a plain APK); MediaCodec hardware decode; Android gamepad API. The Linux AppImage on the phone's Linux side was rejected: software decode, root-only Linux side, Android controllers don't reach it |
| Where the APK comes from | Upstream publishes **no APK** (releases have AppImage/Flatpak/Windows/macOS only, checked 11-27; no Android CI workflow). We build the upstream tag with android-app-dev: `make build PROJECT=chiaki-ng`, which publishes it to PowApps | The fleet's one APK pipeline; PowApps installs/updates it on every phone, including the S25 without adb |
| Launcher entry | Desktop: `desktop/apps/powos-ps5.desktop` "PS5" -> `powos ps5 open` (installs on first open). Phone: the installed APK is listed by the launcher (ShellBridge `apps.list`), labelled "PS5" by the build recipe | No new shell code; the launcher already lists every Android app |
| Discovery | chiaki-ng discovers on the LAN itself. `powos ps5 find [--host IP]` does the same SRCH (UDP 9302, protocol 00030010) for a quick check and for WireGuard, where broadcasts don't arrive | Same protocol as chiaki `lib/src/discovery.c` |
| Pin / latest | `lib/apps/upstream/chiaki-ng.json` records the last version verified by hand (1.10.1). `powos ps5 update` moves to upstream's latest stable, gated (it must start), rolls back to the previous commit if not; `powos ps5 rollback` goes back by hand. Weekly canaries are never picked (GitHub `releases/latest`) | always-latest-upstream; no timer added (needs the user's OK) |

## Pieces

- `lib/apps/powos-ps5` - `powos ps5 [open|status|find|guide|install|update|rollback]`.
- `lib/apps/upstream/chiaki-ng.json` - upstream, licence, verified version, Flatpak id, Android package + tag.
- `desktop/apps/powos-ps5.desktop` - the "PS5" launcher entry (Containerfile installs it).
- `test/tier1/test-ps5-cli.py` - parser, a stand-in PS5 on loopback, dispatch, entry.
- android-app-dev `projects/chiaki-ng/` - the APK recipe (to do, below).

## Pairing, in plain words (`powos ps5 guide`)

1. PS5: Settings > System > Remote Play > Enable Remote Play.
2. PS5: Settings > System > Power Saving > Features Available in Rest Mode: Stay Connected to the Internet, Enable
   Turning On PS5 from Network.
3. chiaki-ng finds the PS5 at home (away on WireGuard: add it by its LAN address).
4. Pick it, Register, sign in to PSN once (only for the account ID).
5. PS5: Settings > System > Remote Play > Link Device shows an 8-digit code; type it into chiaki-ng.

## Checklist

- [x] Packaging decided (Flathub desktop, upstream-tag APK for phones).
- [x] `powos ps5` CLI: install, gated update + rollback, find, guide, status (tier-1 test).
- [x] Desktop "PS5" launcher entry, installed by the image.
- [x] Pin record + latest path.
- [x] android-app-dev `projects/chiaki-ng` recipe (b4057e8/f2bc92e): fetches the pinned upstream tag with submodules
      at build time (no source in the repo), NDK 28.2.13676358 + CMake 3.22.1 + protoc/python3-protobuf (nanopb) in the
      job image, `assembleRelease` unsigned -> hub signs; applicationId `dev.powos.chiaki` + fileprovider
      `dev.powos.chiaki.fileprovider` (installs beside any F-Droid Chiaki, no uninstall), label "PS5"; `.ver` = our
      rising versionCode, upstream version in versionName (`1.10.1-powos.<date>`).
- [ ] First build on .58 + publish to PowApps (coordinator's build).
- [ ] Phone: install from PowApps.
- [ ] First session (needs the user): registration with the PS5's 8-digit Link Device code on each device.
- [ ] Check on device: DualSense paired to the PS5 drives the game while the phone shows the stream; on-screen controls
      off; a phone-side controller also works; wake from rest mode.
- [ ] WireGuard: away-from-home stream by manual host (LAN address of the PS5).
- [ ] Desktop: `powos ps5 open` on a PowOS desktop, then `powos ps5 update` gate run against a real update.

## Needs the user

- The PS5 registration (steps above): PSN sign-in once and the 8-digit Link Device code, per device.
- The PS5's settings in steps 1-2 if they're not on.

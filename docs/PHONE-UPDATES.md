# Phone updates: how a PowOS phone gets new code without a reinstall

A phone runs three things PowOS changes: the **app** (APK: launcher + engine), the **web shell** (`shell/`, the UI the
app's WebViews show) and the **Linux image** (Arch Linux ARM + PowOS's packages + PowOS's own code). Each updates on
its own, from the PowApps store at `http://android.pow/apk/` (android-app-dev's `output/`, LAN or the WireGuard VPN with
Pi-hole's DNS; no public route). A new base image is only for **fresh installs**.

| part | published by | the phone pulls | applied how |
|---|---|---|---|
| APK | `targets/android/build-app.sh` (`make build PROJECT=powos`): `powos.apk` + `powos.ver` | `powos.ver` newer than the installed version code | downloaded, package + version checked, PackageInstaller session; Android asks the person (a notification to tap) unless the app is installer of record and may update itself (Android 12+, `UPDATE_PACKAGES_WITHOUT_USER_ACTION`) |
| web shell | `targets/android/publish-shell.sh` (by build-app.sh and the ship service after a shell ship): `powos-shell.json` + `powos-shell/<sha12>.zip` | the bundle's commit time newer than the shell served now (`ShellSource`: APK's or layer's, the newer) **and** the installed APK at least the store's APK at publish time | sha256 + size checked, unpacked, the differing files moved into `files/shell` exactly like a `shell/push.sh` push: `.pushing` marker, `files/shell-prev`, `files/shell-push.json`, `files/shell-layer.txt` stamp. HotReload reloads the pages once; a page that won't boot is rolled back by `ShellErrors` as any push |
| Linux packages | `targets/android/publish-repo.sh` (`[powos]` repo: KWin, FEX, box64, ...) | `pacman -Syu` from `[powos]` only (its own config, `/etc/pacman.d/powos-repo.conf`: no partial upgrade of Arch) | `lib/phone-update.sh`, inside the image (the image's own loader; `sudo` = the non-root session's fake root) |
| PowOS's own code | `targets/android/build-powos-core.sh --publish` (by build-app.sh and the ship service after a rooted deploy): package `powos-core` in `[powos]` | `powos-core` newer than installed (`vercmp`), or not installed yet | pacman; the first install takes over the files the base image put there unowned (`--overwrite '*'`) |

`powos-core` holds `bin/` -> `/usr/bin` and `lib/` -> `/usr/lib/powos` (`lib/self-phone.sh self_phone_apply`: the CLI,
its libraries, the manager with `fleet_login.py`, claude-login) and the phone's session scripts, shims and `play/`
launchers at the paths `install-powos-android.sh` installs them (`targets/android/tools/phone-files.sh` reads that map
from the install script, so the image and the package can't disagree). Its version is `<commit count>.g<sha9>` of the
newest commit touching those files: it only grows along origin's history, and a ship without code changes publishes
nothing new. Only commits on `origin/main` are published (an agent's branch never reaches phones).

## Away from home: the PowOS VPN (issue #2)

The store has no public route (fleet rule: no new public routes). Off the LAN a phone updates **over the WireGuard
VPN** (`vpn.powback.com:51820`, PowStation's `wireguard` service; peer from `docker exec wireguard /app/show-peer <name>`,
imported into Android's WireGuard app). Every peer routes `192.168.50.0/24` and Traefik's `.pow` allowlist
(`pow-local-only.yml`) admits `10.13.13.0/24`, so the store answers exactly as at home.

| step | at home | away, VPN up, Pi-hole DNS | away, VPN up, other DNS | away, no VPN |
|---|---|---|---|---|
| name | `android.pow` -> Pi-hole -> `192.168.50.100` | same | doesn't resolve | - |
| app (`PowosUpdates`) | by name | by name | `UnknownHostException` -> `http://192.168.50.100/...` with `Host: android.pow` (`Store.connect`, the rest of that run too) | Settings/notification: "away from home, connect the PowOS VPN (WireGuard) to update" |
| image (`phone-update.sh`) | by name | by name if the image follows Android's DNS (`android-nm`) | `getent hosts android.pow` fails -> a pinned copy of the config with `XferCommand = curl --resolve android.pow:80:192.168.50.100` | "the repo isn't reachable ... home network or the PowOS VPN only" |

"Other DNS" is common: the non-root image's resolv.conf is a fixed `8.8.8.8` (`Bootstrap.configure`), Android's Private
DNS (strict) replaces the tunnel's, or a tunnel imported without `DNS = 172.30.0.100`. `UpdatePlan.HUB` and
`POWOS_UPDATE_HUB` hold the hub's address (HACK: fixed; real fix: the host directory's hub row, REMOTE-POWOS.md §2).

Phones that aren't VPN peers (a buyer's) have no update path for PowOS's parts yet: that is the public channel in #2's
plan (CI publishing `powos.apk` + `powos.ver`, the shell bundle and the `[powos]` repo, signed, for PowApps and the
launcher), which needs the owner's OK for a public route. The store's URLs here are the same ones that channel mirrors.

## When it runs

- **The app, no root** (`dev.omalauncher.upgrade.PowosUpdates`): on the launcher's start at most every 6 h (30 min after
  a run that couldn't reach the store), on opening Settings (same throttle), and at once from Settings > system updates
  > check. APK, then shell, then Linux; one "PowOS updates" notification with the progress and the result. Never while a
  game runs (a web-window game in front, or one launched in the last 2 min; `phone-update.sh` also refuses while a game
  process runs, `--force` overrides).
- **Each session start** (`SessionService` step 0b, `SessionPlan.packagesCommand`): the image's `phone-update.sh
  --session`; an image without it yet runs a bootstrap that clears a stale pacman lock, upgrades `[powos]` and installs
  `powos-core` (which brings the updater).
- **By hand, in the image**: `powos update check`, `powos update` / `powos update packages` (the default run),
  `powos update system` (full `-Syu` with Arch Linux ARM's repos, `[powos]` first; the image's IgnorePkg keeps Plasma at
  our KWin's version).
- **Rooted phones** (the OnePlus): the ship service (`tools/phone/ship.sh`) installs APKs, pushes the shell and deploys
  over adb; `PowosUpdates` doesn't run there. Each of those ships also publishes the pull updates above.
- **Dev shortcut**: `tools/phone/nonroot-sync.sh` pushes to an adb-paired non-root phone directly (no store round trip).

## Safety

- Never a downgrade: `-Su` without `-uu`; `powos-core` only when the repo's is newer; the shell only when newer than
  what's served; the store's shell never replaced by an older commit (`publish-shell.sh`).
- A pacman killed mid-run (its process ended with the session) left `db.lck` and every later update failed ("unable to
  lock database", razr 11-09): `phone-update.sh` holds its own lock and removes a `db.lck` no running pacman owns.
- The APK is checked by Android (same signer) and by package name + version code before install; the shell bundle by
  sha256. The pacman repo is unsigned (`SigLevel TrustAll`, HACK in docs/REMOTE-POWOS.md §4 / C12).

## Testing it on a phone

`tools/agents/tier1.sh test-phone-update` (the updater's decisions, pacman stubbed) and the JVM tests
`PowosUpdatesTest`, `SessionPlanTest`. On a device, against a test repo instead of the live one:

```sh
T=~/Projects/android-app-dev/output/test-<name>
PUBLISH_ANY_COMMIT=1 PUBLISH_STORE=$T targets/android/build-powos-core.sh --publish   # then POWOS_CORE_PKGREL=2 ... for a bump
# in the image: POWOS_UPDATE_CONF=<a pacman.conf with Server = http://android.pow/apk/test-<name>/repo> sh phone-update.sh
```

Verified 2026-11-09 on the razr (no root, adb only to start the run): stale lock removed, `powos-core 3517.gd1903078b-1`
installed over the base image's files, then the bumped `-2` picked up by the next run - no reinstall.

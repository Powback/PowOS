# PowOS devices: how a device joins, and how devices control each other

Every PowOS device (desktop, laptop, handheld, phone rooted or not, TV, server) runs one **device agent** and can
**enroll** in the realm. Design and map: `docs/research/device-ecosystem.md`. This page is the how-to.

## The pieces

| piece | where | what it does |
|---|---|---|
| device agent | `lib/devices/powos-deviced` (Linux: desktop, rooted phone's system tier); `DeviceAgentHost.kt` (phone without root, served by the PowOS app) | HTTPS :3416, its own pinned key; `GET /v1/info` (open), `/v1/status`, `/v1/action` (paired token only). Actions by capability: `lock`, `screen_off`, `screen_on`, `sleep` (refused while services/GPU jobs run unless forced), `wake` (Wake-on-LAN for another device), `ring` |
| pairing | the agent | the controller asks, the **target shows a 6-digit code** (notification / `powos devices codes`), the person types it on the controller; per-peer token, stored hashed; revoke from any paired device. Works offline, no hub needed |
| enrollment | `powos devices enroll` + PowStation `enroll/powos-enroll.py` (`enroll.pow` only, LAN/VPN; no public route) | the device's identity in the realm, approved by an already-enrolled approver device or by the owner on the server; returns the device's own realm token, its own AI token, the endpoints bundle |
| AI per device | claude-rate-limiter `src/enrolled-devices.ts` | the authority maps each enrolled device's own bearer to a tenant, so one device is revoked without rotating the tenant secret |
| registry | `~/.config/powos/units.d/powos-device.json` on the device (`powos units`), the realm's `registry.json` on PowStation (`powos devices registry`) | which devices exist, their caps and agent address, who approved them, what they hold |
| Devices app | `apps/devices` (bundled, every surface) | paired devices with live status and actions |

## How a new device joins

LAN/VPN only (owner 2026-11-07: "no public routes yet"): there is no `enroll.powback.com` and no web page. Approval
comes from a device the realm already trusts, never from a browser session.

1. On the new device: `powos devices enroll` (or `--name "Living room TV"`). It prints a code like `BCDF-GHJK`
   (and `powos://devices/approve?code=...`, a QR when `qrencode` is there).
2. Approve it, one of:
   - **The first device** (nothing enrolled yet): the owner on the server itself,
     `docker exec powos-enroll powos-enroll pending` then
     `docker exec powos-enroll powos-enroll approve BCDF-GHJK [--tenant default] [--no-approver]`. This talks to a
     loopback-only admin port inside the container (per-start secret), so only a shell on PowStation can use it.
   - **Any later device**: from an enrolled *approver* device (the Devices app; approvers are the default, a TV or
     test box can be enrolled `--no-approver`), with that device's own token on `enroll.pow`:
     `GET /v1/devices/pending`, then `POST /v1/devices/approve {code, decision: approve|deny, tenant?, approver?}`.
     Check the code matches the one on the new device, pick its AI subscription (or none). HACK: the Devices app's
     Approve button and a `powos devices approve` CLI are not built yet (PowOS side); until then use the server CLI.
     Real fix: that button over the API above.
   A device that is only *paired* (not enrolled) can't approve; enroll it first (the owner approves it on the server).
3. The new device finishes by itself: it stores its enrollment (`~/.local/state/powos/deviced/enrollment.json`, 0600),
   registers `powos-device` in its `units.d`, and prints `enrolled: <name>`. `--apply-ai` (or later
   `powos devices ai-apply`) points its AI at claude-auth with **its own** token (`/etc/powos/ai/endpoint.conf`).
4. To control it from another device, pair once (below). The enrollment says *who* the device is; pairing grants
   control. (Realm certificates replacing per-pair tokens: device-ecosystem.md P4.)

The service re-checks the presented device token (hash, not revoked, approver flag) on every request; nothing is cached.

Leave: `powos devices unenroll` (its realm and AI tokens stop at once). Revoke a lost device: from an approver device
`POST /v1/devices/revoke {id}`, or on the server `docker exec powos-enroll powos-enroll revoke <id>` (`forget <id>`
then drops the revoked row); and on each device it was paired with, `powos devices revoke <id>` or the Devices app's
Forget.

**No hub (offline, a new LAN):** pairing alone still works - two devices on one LAN pair with the code on the target's
screen and stay "paired, not enrolled".

## Pair and control

```sh
powos devices pair https://192.168.50.239:3416     # the code appears on the phone
powos devices call Phone status
powos devices call Phone screen_on                 # lock / screen_off / ring, as the device advertises
powos devices devices                              # what this CLI paired with
powos devices peers                                # who may control THIS device
```

The Devices app does the same from any PowOS device (pair from mDNS `_powos._tcp` or an address).

## Per device

| device | agent | caps |
|---|---|---|
| Desk (.58, KDE) | `powos-deviced` systemd --user unit (`lib/devices/deploy.sh`, `units/gpu-58/powos-deviced.json`) | status, lock, screen_off, screen_on, sleep (guarded), wake |
| Phone, rooted | `powos-deviced` in the system tier (`lib/apps/services/powos-deviced.json`, `units/phone/powos-deviced.json`; deployed by `rooted.sh deploy`). Android through the session's adb to itself (a hack row in REMOTE-POWOS §4) | status (battery, screen, locked), lock, screen_off, screen_on, ring, wake |
| Phone, no root | the PowOS app (`devices/DeviceAgentHost.kt`, key in Android Keystore) | status, screen_on, ring; lock and screen_off once the owner allows them (below) |
| Server (gpu-195, PowStation) | `powos-deviced` (server backend), not deployed yet | status, sleep (guarded), wake |

## Phone without root: lock

A phone without root locks the Android-sanctioned way: PowOS's own **device admin with only the force-lock policy**
(`devices/LockAccess.kt`, `res/xml/powos_lock_admin.xml`) and `DevicePolicyManager.lockNow()`. Never taken silently:

1. On the phone, the Devices app shows **This phone** (only on a no-root phone with an APK that has it). Tap
   **Allow lock**: a sheet says exactly what it allows - Lock and Screen off for the paired devices, nothing else; no
   PIN access, wipe or password rules; after a remote lock Android asks for the PIN/pattern once (strong auth, not the
   fingerprint); off here or in Settings > Security > Device admin apps; uninstalling PowOS asks to turn it off first.
2. **Continue** opens Android's own "Activate device admin app?" screen. The card shows it on at once (optimistic,
   "Android is asking - tap Activate there"); Activate keeps it (the receiver's `onEnabled` -> `devices.lock` event);
   coming back without Activate rolls it back with why and a Try again.
3. **Turn off** (or Settings) removes the admin; a refusal rolls the card back with Android's words.

What the agent advertises follows the grant live: `caps` (`/v1/info`, `/v1/status`) gain `lock` and `screen_off`
the moment the admin is active and lose them the moment it isn't - read on every request, nothing cached
(`LockActions` + `WithLock`). `screen_off` is a lock here (there is no screen-off without root that leaves the phone
unlocked); the answer says `"as": "lock"`. Asked while not allowed, both are refused with `unsupported` and how to
allow it. The controlling Devices app takes each device's caps from its status, so its buttons follow too.

A rooted phone doesn't show the card: its system-tier `powos-deviced` locks without the admin.

Bridge (`shell/types.ts` `devices`, all `// detect`): `devices.lock` (state `{available, rooted, allowed}`),
`devices.lockAllow` (Android's screen), `devices.lockStop`, event `devices.lock`. App host: `host.thisDevice`
(`shell/apps/thisdevice.ts`). Tests: `LockActionsTest` (advertising, grant/revoke, lock path, no lock unpaired or
unallowed), the gate's `app local.devices` (`dvThisPhone`: sheet first, optimistic on, decline rollback, grant, failed
turn-off rollback).

## The realm side (PowStation) - deployed 2026-11-07, LAN/VPN only

Runs as its own compose project `powos-enroll` (PowStation branch `agent/devices-enroll`, `enroll/`) until it is
folded into PowStation's main compose; state is the named volume `powos-enroll-data`, the authority's map is
`~/.claude-tenants/enrolled/devices.json`.

```sh
mkdir -p ~/.claude-tenants/enrolled
docker compose -p powos-enroll -f enroll/docker-compose.yml up -d --build     # from the PowStation checkout
curl -H 'Host: enroll.pow' http://192.168.50.100/healthz                       # {"ok": true}
```

- One route: `enroll.pow` (`/v1/*`, `/healthz`) on `local-only@docker`; the fleet-wide `pow-local-only` router
  (priority 1000000000) answers 403 to any non-LAN/VPN source before it. `enroll.powback.com` has no router (404).
- Then add `../../PowStation/enroll/docker-compose.yml` to `config/platform-fleet.json` and run the fleet check.
- Per-device AI needs the claude-rate-limiter authority with `src/enrolled-devices.ts` (branch
  `agent/devices-enroll`). Until that is deployed a device token is an unknown bearer to the authority (the host
  subscription by fallback, or a 401 with `AUTH_REQUIRE_TENANT`), so don't `ai-apply` before it is.

Tests: `test/tier1/test-deviced.py` (agent + enroll client), `DeviceAgentCoreTest` + `LockActionsTest` (the no-root agent),
PowStation `enroll/test_powos_enroll.py` (the realm side), claude-rate-limiter `npm run test:enrolled`.

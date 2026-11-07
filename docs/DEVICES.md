# PowOS devices: how a device joins, and how devices control each other

Every PowOS device (desktop, laptop, handheld, phone rooted or not, TV, server) runs one **device agent** and can
**enroll** in the realm. Design and map: `docs/research/device-ecosystem.md`. This page is the how-to.

## The pieces

| piece | where | what it does |
|---|---|---|
| device agent | `lib/devices/powos-deviced` (Linux: desktop, rooted phone's system tier); `DeviceAgentHost.kt` (phone without root, served by the PowOS app) | HTTPS :3416, its own pinned key; `GET /v1/info` (open), `/v1/status`, `/v1/action` (paired token only). Actions by capability: `lock`, `screen_off`, `screen_on`, `sleep` (refused while services/GPU jobs run unless forced), `wake` (Wake-on-LAN for another device), `ring` |
| pairing | the agent | the controller asks, the **target shows a 6-digit code** (notification / `powos devices codes`), the person types it on the controller; per-peer token, stored hashed; revoke from any paired device. Works offline, no hub needed |
| enrollment | `powos devices enroll` + PowStation `enroll/powos-enroll.py` (`enroll.pow` for devices, `enroll.powback.com` for people, behind PowAuth) | the device's identity in the realm, approved by a PowAuth user; returns the device's own realm token, its own AI token, the endpoints bundle |
| AI per device | claude-rate-limiter `src/enrolled-devices.ts` | the authority maps each enrolled device's own bearer to a tenant, so one device is revoked without rotating the tenant secret |
| registry | `~/.config/powos/units.d/powos-device.json` on the device (`powos units`), the realm's `registry.json` on PowStation (`powos devices registry`) | which devices exist, their caps and agent address, who approved them, what they hold |
| Devices app | `apps/devices` (bundled, every surface) | paired devices with live status and actions |

## How a new device joins

1. On the new device: `powos devices enroll` (or `--name "Living room TV"`). It prints a link and a code like
   `BCDF-GHJK`, and a QR when `qrencode` is there.
2. On a device already signed in to PowAuth (your phone): open the link (`https://enroll.powback.com/approve?code=...`,
   PowAuth asks you to sign in if needed). The page shows the device's name, kind, platform, capabilities and the address
   it asked from. Check the code matches the one on the new device, pick its AI subscription (or none), **Approve**.
3. The new device finishes by itself: it stores its enrollment (`~/.local/state/powos/deviced/enrollment.json`, 0600),
   registers `powos-device` in its `units.d`, and prints `enrolled: <name>`. `--apply-ai` (or later
   `powos devices ai-apply`) points its AI at claude-auth with **its own** token (`/etc/powos/ai/endpoint.conf`).
4. To control it from another device, pair once (below). The enrollment says *who* the device is; pairing grants
   control. (Realm certificates replacing per-pair tokens: device-ecosystem.md P4.)

Leave: `powos devices unenroll` (its realm and AI tokens stop at once). Revoke a lost device: the people page
(`https://enroll.powback.com/`) -> Revoke; and on each device it was paired with, `powos devices revoke <id>` or the
Devices app's Forget.

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

## Deploying the realm side (PowStation) - a decision, not done yet

```sh
mkdir -p ~/.claude-tenants/enrolled ~/Projects/PowStation/data/powos-enroll
cd ~/Projects && PowStation/bin/pow-compose --project-directory PowStation/enroll -f PowStation/enroll/docker-compose.yml check
PowStation/bin/pow-compose --project-directory PowStation/enroll -f PowStation/enroll/docker-compose.yml up -d
```

- Adds the public route `enroll.powback.com` (behind `authelia@docker`; the service also re-checks every request's
  PowAuth session itself) and `enroll.pow` (device API, LAN/VPN only). No PowAuth bypass rule.
- Then add `../../PowStation/enroll/docker-compose.yml` to `config/platform-fleet.json` and run the fleet check.
- Per-device AI needs the claude-rate-limiter authority with `src/enrolled-devices.ts` (branch
  `agent/devices-enroll`). Until that is deployed a device token is an unknown bearer to the authority (the host
  subscription by fallback, or a 401 with `AUTH_REQUIRE_TENANT`), so don't `ai-apply` before it is.

Tests: `test/tier1/test-deviced.py` (agent + enroll client), `DeviceAgentCoreTest` + `LockActionsTest` (the no-root agent),
PowStation `enroll/test_powos_enroll.py` (the realm side), claude-rate-limiter `npm run test:enrolled`.

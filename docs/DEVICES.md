# PowOS devices: how a device joins, and how devices control each other

Every PowOS device (desktop, laptop, handheld, phone rooted or not, TV, server) runs one **device agent** and can
**enroll** in the realm. Design and map: `docs/research/device-ecosystem.md`. This page is the how-to.

## The pieces

| piece | where | what it does |
|---|---|---|
| device agent | `lib/devices/powos-deviced` (Linux: desktop, rooted phone's system tier); `DeviceAgentHost.kt` (phone without root, served by the PowOS app) | HTTPS :3416, its own pinned key; `GET /v1/info` (open), `/v1/status`, `/v1/action` (paired token only). Actions by capability: `lock`, `screen_off`, `screen_on`, `sleep` (refused while services/GPU jobs run unless forced), `wake` (Wake-on-LAN for another device), `ring` |
| pairing | the agent | the controller asks, the **target shows a 6-digit code** (notification / `powos devices codes`), the person types it on the controller; per-peer token, stored hashed; revoke from any paired device. Works offline, no hub needed |
| enrollment | `powos devices enroll` + PowStation `enroll/powos-enroll.py` (`enroll.pow` only, LAN/VPN; no public route) | the device-code flow, approved by an already-enrolled approver device or by the owner on the server; on approval it has PowAuth create the device's principal and hands the device its PowAuth key once, plus the endpoints bundle. Keeps only non-secret metadata |
| identity + credentials | **PowAuth** (branch `agent/device-principals`) | each enrolled device is PowAuth user `dev-<id>` in group `devices` (+ `devices-approvers`, `ai-<tenant>`) with one API key (`pk_...`, stored hashed by PowAuth). Revoke = PowAuth deletes it; every service asking PowAuth refuses it on the next request. Design: device-ecosystem.md D7 |
| AI per device | claude-rate-limiter (branch `agent/powauth-identity`) | the device presents its PowAuth key; the proxy asks PowAuth who it is and maps group `ai-<tenant>` to the tenant (`POWAUTH_TENANT_MAP`). No device concepts in the proxy |
| registry | `~/.config/powos/units.d/powos-device.json` on the device (`powos units`), the realm's `registry.json` on PowStation (`powos devices registry`) | which devices exist, their caps and agent address, who approved them, what they hold |
| Devices app | `apps/devices` (bundled, every surface) | paired devices with live status and actions; on an approver, new devices asking to join (Approve / Deny) and Revoke per device |

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
   - **Any later device**: from an enrolled *approver* device (approvers are the default; a TV or test box can be
     enrolled `--no-approver`; PowAuth group `devices-approvers`), using that device's own PowAuth key - never one
     typed anywhere:
     - **The Devices app** on the approver shows **New device wants to join**: each waiting device with its code shown
       big, its kind and platform, and "paired with this device" when it already was; **Approve** / **Deny**. Match
       the code with the one on the new device's screen first. Live (polled every 3 s while shown) and optimistic: the
       result shows at once, a refusal rolls back with the realm's words and a Try again. The app approves without an
       AI subscription; the CLI below picks one.
     - **The CLI** on the approver: `powos devices pending`, then `powos devices approve BCDF-GHJK [--tenant default]
       [--no-approver] [--deny]` (no code: the only device waiting, after a yes).
     Both go through the approver's own agent (`powos-deviced`: `/v1/enroll/pending|approve|devices|revoke`), which
     calls `enroll.pow`'s `GET /v1/devices/pending` / `POST /v1/devices/approve {code, decision, tenant?, approver?}`
     with its enrollment token. The agent answers `/v1/enroll/*` only to a caller on the same device (loopback or its
     own address): pairing grants control of a device, never the right to approve others through it. `/v1/status`
     says `realm: {enrolled, approver, here}` (no token), which is how the app knows to show the card - only on a
     device whose enrollment is an approver, and only to the app running on it (the app pairs with its own device's
     agent once, like any other device: Add a device, this device's address, the code shown here).
   **A device that is only paired** upgrades the same way: `powos devices enroll` on it, approved by the owner on the
   server or by any approver (the card and `pending` mark it "paired with this device"). Pairings stay as they were;
   once it is enrolled it can approve others too (unless approved `--no-approver`).
3. The new device finishes by itself: it stores its enrollment (`~/.local/state/powos/deviced/enrollment.json`, 0600),
   registers `powos-device` in its `units.d`, and prints `enrolled: <name>`. Its `device_token` is its PowAuth API
   key: the one credential it holds, for the realm, claude-auth and any `powauth-key@file` route. `--apply-ai` (or
   later `powos devices ai-apply`) points its AI at claude-auth with that key (`/etc/powos/ai/endpoint.conf`).
4. To control it from another device, pair once (below). The enrollment says *who* the device is; pairing grants
   control. (Realm certificates replacing per-pair tokens: device-ecosystem.md P4.)

powos-enroll asks PowAuth (`GET /api/authz/apikey`) about the presented key on every request (live key, existing
user, `devices` group; `devices-approvers` to approve or revoke); nothing is cached and it stores no secret.

Leave: `powos devices unenroll` (PowAuth deletes its principal: its key stops everywhere at once). Revoke a lost device: on an approver,
`powos devices revoke <id|name>` (drops its pairing with this device and revokes it in the realm; `--local` only the
pairing) or the Devices app's **Revoke** on its card (asked once, shown revoked at once, rolled back if the realm
refuses; the card then goes); on the server `docker exec powos-enroll powos-enroll revoke <id>` (`forget <id>` then
drops the revoked row). On each other device it was paired with, `powos devices revoke <id> --local` or Forget.
A paired card on an approver that isn't enrolled says how it joins.

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

## The realm side (PowStation + PowAuth)

Owner 2026-11-07: PowAuth owns device identity, credentials and revocation (device-ecosystem.md D7); the first slice
(powos-enroll's own token hashes + a claude-rate-limiter device map) is replaced. Built and pushed, **not deployed**:

| repo | branch | what |
|---|---|---|
| PowAuth | `agent/device-principals` | device principals API (`/api/admin/devices/{id}`, `device-enrollers` only), `GET /api/authz/apikey`, `authelia storage user apikey create --file` |
| PowStation | `agent/powauth-devices` | `enroll/`: powos-enroll on PowAuth principals; Authelia `group:devices` denied on `*.powback.com`; `powauth-key@file` |
| claude-rate-limiter | `agent/powauth-identity` | PowAuth-verified user/group -> tenant (`POWAUTH_VERIFY_URL`, `POWAUTH_TENANT_MAP`) |

Deploy order (checkboxes: device-ecosystem.md P10.1-P10.6): PowAuth image -> PowStation config merge -> the enrollment
service's PowAuth account and key (`enroll/README.md`, Bootstrap) -> redeploy `powos-enroll` -> re-enroll the devices
the first slice enrolled (marked `reenroll`; their old tokens work nowhere) -> claude-auth with the two env vars ->
`powos devices ai-apply`. Until claude-auth has it, don't `ai-apply`: a pk_ key is an unknown bearer to it.

- One route: `enroll.pow` (`/v1/*`, `/healthz`) on `local-only@docker`; the fleet-wide `pow-local-only` router
  (priority 1000000000) answers 403 to any non-LAN/VPN source before it. `enroll.powback.com` has no router (404).
- In the fleet manifest `config/platform-fleet.json` (`../../PowStation/enroll/docker-compose.yml`, project
  `powos-enroll`); `pow-compose fleet --manifest PowOS/config/platform-fleet.json --json` checks it with the others.
- Secret values services need (TURN_SECRET, tenant secrets, WireGuard keys, `.env` files) move to a fleet secret
  store with PowAuth as its auth method in phase 2 (device-ecosystem.md D8, P11); a device's PowAuth identity is what
  it will present there.

Tests: `test/tier1/test-deviced.py` (agent + enroll client), `test/tier1/test-deviced-approve.py` (pending/approve/
revoke CLI and `/v1/enroll/*`, approver-only, same-device-only), the gate's `app local.devices` (`dvJoin`,
`dvJoinDeny`, `dvMember`), `DeviceAgentCoreTest` + `LockActionsTest` (the no-root agent),
PowStation `enroll/test_powos_enroll.py` (the realm side against a fake PowAuth), PowAuth
`go test ./internal/handlers -run TestDevice`, claude-rate-limiter `npm run test:powauth`.

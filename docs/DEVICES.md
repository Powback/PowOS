# PowOS devices: how a device joins, and how devices control each other

Every PowOS device (desktop, laptop, handheld, phone rooted or not, TV, server) runs one **device agent** and can
**enroll** in the realm. Design and map: `docs/research/device-ecosystem.md`. This page is the how-to, and it
describes what is deployed (owner 2026-11-07: keep the current setup, don't extend it).

## Quick start

1. **To control a device, pair it in the Devices app**: Add a device, pick it (mDNS or its address), type the 6-digit
   code the target shows. Then lock, unlock (desktop, owner-marked peers only), screen on/off, sleep, wake, ring.
2. **Enroll only if you want it to approve other devices**: `powos devices enroll` on it (LAN/VPN, `enroll.pow`);
   the first device is approved on the server, later ones from an approver (below). Enrolling gives no AI access.

## The pieces

| piece | where | what it does |
|---|---|---|
| device agent | `lib/devices/powos-deviced` (Linux: desktop, rooted phone's system tier); `DeviceAgentHost.kt` (phone without root, served by the PowOS app) | HTTPS :3416, its own pinned key; `GET /v1/info` (open), `/v1/status`, `/v1/action` (paired token only). Actions by capability: `lock`, `screen_off`, `screen_on`, `sleep` (refused while services/GPU jobs run unless forced), `wake` (Wake-on-LAN for another device), `ring` |
| pairing | the agent | the controller asks, the **target shows a 6-digit code** (notification / `powos devices codes`), the person types it on the controller; per-peer token, stored hashed; revoke from any paired device. Works offline, no hub needed |
| enrollment | `powos devices enroll` + PowStation `enroll/powos-enroll.py` (`enroll.pow` only, LAN/VPN; no public route) | the device's identity in the realm, approved by an already-enrolled approver device or by the owner on the server; returns the device's own realm token and the endpoints bundle |
| AI per device | not deployed, not planned now | AI stays on the existing subscription secret (claude-auth); `src/enrolled-devices.ts` is not in the deployed claude-rate-limiter, so the authority knows no device tokens |
| registry | `~/.config/powos/units.d/powos-device.json` on the device (`powos units`), the realm's `registry.json` on PowStation (`powos devices registry`) | which devices exist, their caps and agent address, who approved them, what they hold |
| Devices app | `apps/devices` (bundled, every surface) | paired devices with live status and actions; on an approver, new devices asking to join (Approve / Deny) and Revoke per device |

## The owner config: standalone until enrolled (issue #1)

A fresh device names none of the owner's hosts: its board is its own (`powos agents`, a local file store where no
powos-agents module runs), mail to a role nobody runs here says "no agent for this role here", and the terminals'
links, the ship gate, the root channel and the speech servers are "not configured". Enrolling hands it the realm's
owner bundle (`ENROLL_ENDPOINTS` -> `endpoints.owner`, `{POWOS_*: value}`; the owner's values: `tools/phone/owner.json`),
which `powos-deviced` writes to the one file every reader uses, `~/.config/powos/owner.conf` (`POWOS_OWNER_CONF`
overrides; a phone also gets the launcher's copy in the app's `files/run/owner.conf`); `unenroll` removes it, and
`powos devices owner-apply [FILE|-]` writes it again. Keys: `POWOS_BOARD_REMOTE` (the board host's command line,
`{cmd}` = the powos command), `POWOS_ROOTSH_SHELL`, `POWOS_TERMS_LINKS` (`host=user@address,...`),
`POWOS_SHIP_GATE_URL`, `POWOS_STT_URL`, `POWOS_VOICE_URL`. The realm must carry `owner` in `ENROLL_ENDPOINTS` for this.

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
     enrolled `--no-approver`), using that device's own enrollment token - never one typed anywhere:
     - **The Devices app** on the approver shows **New device wants to join**: each waiting device with its code shown
       big, its kind and platform, and "paired with this device" when it already was; **Approve** / **Deny**. Match
       the code with the one on the new device's screen first. Live (polled every 3 s while shown) and optimistic: the
       result shows at once, a refusal rolls back with the realm's words and a Try again. `--tenant` (CLI and
       server) only records a name; nothing uses it while per-device AI isn't deployed.
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
   registers `powos-device` in its `units.d`, and prints `enrolled: <name>`. `--apply-ai` and
   `powos devices ai-apply` are **not available**: per-device AI isn't deployed, so don't use them; AI keeps using
   the existing subscription secret.
4. To control it from another device, pair once (below). The enrollment says *who* the device is; pairing grants
   control. (Realm certificates replacing per-pair tokens: device-ecosystem.md P4.)

The service re-checks the presented device token (hash, not revoked, approver flag) on every request; nothing is cached.

Leave: `powos devices unenroll` (its realm token stops at once). Revoke a lost device: on an approver,
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

### Unlock (a desktop, its owner only)

A locked desktop is unlocked remotely the owner's way: `unlock` is logind's `UnlockSession` on this user's seat0
session (`loginctl unlock-session <id>`), which KDE's screen locker honours. No password is typed, sent or stored, and
the lock screen stays on for everything else. Only the owner may: a paired device marked owner ON the desktop
(`powos devices owner <device>` there, `--off` to take it back; `powos devices peers` shows it), or an approver device
enrolled in the desktop's realm (asked at most once a minute). Any other paired device gets 403; every unlock and
refusal is logged with the peer id (`journalctl --user -u powos-deviced`). `/v1/status` says `you: {owner}`.
Phones never advertise unlock - Android can't be unlocked remotely without the PIN, and PowOS doesn't try.

```sh
powos devices owner Mac              # on Desk (or ssh to it): the Mac may unlock Desk
powos devices call Desk unlock       # on the Mac; then `call Desk status` -> "locked": false
```

## Per device

| device | agent | caps |
|---|---|---|
| Desk (.58, KDE) | `powos-deviced` systemd --user unit (`lib/devices/deploy.sh`, `units/gpu-58/powos-deviced.json`) | status, lock, unlock (owner only), screen_off, screen_on, sleep (guarded), wake |
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
folded into PowStation's main compose; state is the named volume `powos-enroll-data` (it also writes
`~/.claude-tenants/enrolled/devices.json`, which the deployed authority doesn't read).

```sh
mkdir -p ~/.claude-tenants/enrolled
docker compose -p powos-enroll -f enroll/docker-compose.yml up -d --build     # from the PowStation checkout
curl -H 'Host: enroll.pow' http://192.168.50.100/healthz                       # {"ok": true}
```

- One route: `enroll.pow` (`/v1/*`, `/healthz`) on `local-only@docker`; the fleet-wide `pow-local-only` router
  (priority 1000000000) answers 403 to any non-LAN/VPN source before it. `enroll.powback.com` has no router (404).
- In the fleet manifest `config/platform-fleet.json` (`../../PowStation/enroll/docker-compose.yml`, project
  `powos-enroll`); `pow-compose fleet --manifest PowOS/config/platform-fleet.json --json` checks it with the others
  (ok 2026-11-07; the path resolves once PowStation `agent/devices-enroll` is merged into its main checkout).
- Not deployed and not planned now: per-device AI (claude-rate-limiter `src/enrolled-devices.ts` is not in the
  deployed authority; `--apply-ai` / `ai-apply` are not available), PowAuth device principals / forwardAuth (those
  branches are superseded, unmerged) and OpenBao.

Tests: `test/tier1/test-deviced.py` (agent + enroll client), `test/tier1/test-deviced-unlock.py` (unlock: desktop
only, owner/approver only, fake loginctl), `test/tier1/test-deviced-approve.py` (pending/approve/
revoke CLI and `/v1/enroll/*`, approver-only, same-device-only), the gate's `app local.devices` (`dvUnlock`, `dvJoin`,
`dvJoinDeny`, `dvMember`), `DeviceAgentCoreTest` + `LockActionsTest` (the no-root agent),
PowStation `enroll/test_powos_enroll.py` (the realm side).

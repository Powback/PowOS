# PowOS device ecosystem: how devices are hooked up, and how they should join

Status: **research + design + first slice** (2026-11-07). Board task
`powos-device-ecosystem-enrollment-via-powauth-de`. Builds on `docs/REMOTE-POWOS.md` (channels C1-C16, realm
identity, M0-M8) and `docs/PLATFORM.md` (unit/fleet registry). This doc adds what those don't cover: the
**device** view (what every machine is, how it got its secrets, how it is controlled), enrollment through PowAuth,
and the Devices app.

The user's ask (11-07): *"a devices app where I can lock the pc or sleep it or turn off the monitors so I don't have
to get out of bed ... we didn't use powauth or anything to register for this cluster or get the ai key ... macback
connecting on ai page"*, and *"it's not just for the phone but all powos devices"*. So: one enrollment, one registry,
one control agent and one Devices app on **every** PowOS device (desktop, laptop, handheld, phone rooted or not, TV,
later web/iOS), with actions by capability, never by device type.

---

## 1. Map: every device and every link today

Read on 2026-11-07 from the machines themselves (ssh, `systemctl`, `ss`, file listings; no secret printed) and the
tree.

### 1.1 Devices

| device | address | runs | its PowOS identity today |
|---|---|---|---|
| **Phone** (OnePlus Open, rooted) | LAN `192.168.50.239`, VPN `10.13.13.7` | PowOS app + Linux session (rootfs), SpacetimeDB `127.0.0.1:3410` (the work board, the AI page), sshd `:2222`, adbd TCP `:5555` | none: a hostname `phone` in scripts, an adb key, a WireGuard peer named `phone` |
| **macback** (Mac Studio) | `192.168.50.99` | Claude sessions, agents reporter (hooks), units-publish, ship/verify runners, `powos-vadb`, Colima | none: `POWOS_AGENTS_HOST=mac` hard-coded in each hook; `units/mac/` |
| **PowStation** (Colima VM) | `192.168.50.100` | Traefik, Pi-hole, WireGuard server, PowAuth (Authelia fork), claude-auth authority, android.pow store | `POW_PLATFORM_HOST=powstation`; it is the hub |
| **Desk** (`.58`, Bazzite/KDE, RTX 5090) | LAN `192.168.50.58` only (not a VPN peer) | llama-swap `:9292`, PowStream WebRTC `:8090`, PowLens `:8791`, PowMap scan, its own Traefik `:80`, the shell gate's remote browser, KDE Connect `:1716`, avahi | `POW_PLATFORM_HOST=desktop` in `pow-compose.conf`; `units/gpu-58/`; **since this slice: a device id + TLS key (powos-deviced)** |
| **gpu-195** (2x RTX 3090) | `192.168.50.195` | voice agent, LLM pool, models store (podman quadlets) | `units/gpu-195/`; a git checkout shim for `powos units` (HACK row) |
| **NAS** (Synology, PowCache) | `192.168.50.231` | NFS `volume1/PowCache` (+ `/cdn`) | none: an IP in NFS export rules |
| laptop, tablet, phone2, "oneplus" | VPN only | — | WireGuard peer folders on PowStation, nothing else |

### 1.2 Links (what connects what, and how it was set up)

| # | link | what it carries | how it's configured | by hand / automatic | the secret, and where it lives |
|---|---|---|---|---|---|
| L1 | **WireGuard** peers → PowStation | every remote device's LAN access, Pi-hole DNS | `PowStation/data/wireguard/peer_<name>/` (7 peers: laptop, macback, oneplus, phone, phone2, tablet + server), shown as a QR with `docker exec wireguard /app/show-peer <name>` | **by hand**, one folder per device | each peer's **private key is generated and kept on the hub** (linuxserver image), then scanned into the device's WireGuard app. The hub holds every device's private key |
| L2 | Phone VPN keep-alive | the phone staying on L1 while it rests | `units/phone-android/vpn-keep.json` (deviceidle allowlist, always-on VPN), applied by `powos-start.sh` | automatic once deployed | none |
| L3 | **AI: claude-auth** (fleet OAuth authority) | every Claude call | `/etc/powos/ai/endpoint.conf` = `ANTHROPIC_BASE_URL=http://claude-auth.pow` + `ANTHROPIC_AUTH_TOKEN=<tenant secret>`, written by `powos config claude-endpoint` / `claude-token` (`lib/config.sh:227`) | **by hand on each device** (phone; `.58`'s file dates from 08-12, root-owned, world-readable) | the **tenant routing secret**, in clear in `endpoint.conf`; it is not authentication (an unknown secret falls back to the host subscription unless `AUTH_REQUIRE_TENANT=1`). Same secret on every device of a tenant: no per-device revocation |
| L4 | Claude sign-in | re-login when a tenant's grant dies | `lib/ai/manager/fleet_login.py`, the AI page's Login button | user-driven | the tenant secret (L3) authorizes `/oauth` on the authority |
| L5 | **Mac → phone agents mirror** ("macback on the AI page") | the Mac's agents/tasks/asks as one JSON | hooks in `~/.claude/settings.json` → `powos-agentsd --mirror phone` → `powos-rootsh` → `powos-vadb` (container in WireGuard's netns) → `adb shell su` | automatic, **over a root debug bridge** (REMOTE-POWOS C1/C5/C7) | the Mac's adb private key (`~/.android`), Magisk's grant to `shell` |
| L6 | Mac → phone board, mail, units | `powos agents task ...`, `powos comms`, `tools/units/publish.sh phone` | adb + `su` from the Mac (C4) | automatic (launchd every 15 min) / per command | same adb key |
| L7 | Phone → Mac | the phone's manager reads the Mac's tmux | `~/.ssh/authorized_keys` entry `powos-phone` on the Mac, **no `restrict`/`from=`/`command=`** (C8) | by hand | the phone's ssh private key |
| L8 | Mac → `.58`, `.195` | the shell gate's remote runs, deploys, `powos units` reads | plain ssh as `powos@` with the Mac's key | by hand | the Mac's ssh key in each box's `authorized_keys`; `.58` also has a correctly restricted PowDash key (`restrict,from=...,command=powdash-report.sh`) |
| L9 | Devices → `android.pow` | APKs, rootfs, pacman repo | plain HTTP, Pi-hole name | automatic | none (rootfs sha256 pinned in the APK; pacman `TrustAll` HACK) |
| L10 | Devices → `llm.pow` / `.58:9292` / gpu-195 | local LLMs | LiteLLM router config on PowStation | by hand (router config) | LiteLLM keys where set |
| L11 | Mac/containers → **NAS** | `/mnt/nas/cdn`, PowCache | NFS by IP (`192.168.50.231:/volume1/PowCache`), autofs on the Mac | by hand (NAS export rules) | none: trust = source IP |
| L12 | Browsers → public routes | `*.powback.com` | Traefik + `authelia@docker` (PowAuth, `one_factor`), explicit bypasses | by hand per route | PowAuth users file, session cookie |
| L13 | **PowStream** | game stream `.58 → any browser` | `powstream-webrtc-server.service` (user unit, `:8090`, self-signed TLS), `powos stream` (`lib/stream.sh`) | started at login on `.58` | **no per-device auth found** in the signalling server (no Authorization handling in `bins/powstream-webrtc-server`): reachability is the only gate |
| L14 | KDE Connect on `.58` | phone ↔ PC (notifications, lock, ring) in KDE's own protocol | Plasma autostart, `:1716` | automatic, KDE-paired | KDE's own pairing keys; **no PowOS phone is paired** - an unused parallel ecosystem |
| L15 | Units registry | every host's units on the AI page | `tools/units/publish.sh` (Mac launchd) → `powos-agents-cli units sync` into the phone's STDB | automatic for mac/colima/phone; `.58` and gpu-195 publish only through their checkouts | the CLI owner token (`~/.config/spacetime/cli.toml`) |

### 1.3 The gaps

1. **No device identity.** A device is an IP, a hostname in a script, an adb key or a WireGuard folder name. Nothing
   says "this is Desk, enrolled on 11-07, owned by Mats, can lock/sleep/stream".
2. **No enrollment.** Every secret was placed by hand: WireGuard QR (L1), `endpoint.conf` (L3), ssh keys (L7, L8),
   adb keys (L5). A new device (a laptop, a TV, a second phone) repeats all of it; none of it goes through PowAuth,
   which exists exactly to manage accounts.
3. **Shared, unrevocable secrets.** The claude-auth tenant secret is the same on every device of a tenant and is a
   routing tag, not a credential (L3). The hub holds every WireGuard private key (L1). A lost phone means rotating
   things by hand and guessing what else had them.
4. **No revocation path at all.** No list of which device holds what, so nothing can be revoked as a unit.
5. **Root debug channels as runtime transport** (L5, L6, L7): the reason "macback is on the AI page" is a container
   borrowing WireGuard's netns to run `adb shell su` (REMOTE-POWOS C1-C8). Nothing works on a non-rooted install.
6. **No remote control of a device.** Locking `.58`, turning its monitors off or putting it to sleep needed someone at
   the keyboard. (KDE Connect could do some of it on `.58`, but it's KDE-only, not PowOS, and unpaired.)
7. **`.58` is not a VPN peer** and has no Wake-on-LAN armed (`/sys/class/net/enp10s0/device/power/wakeup` =
   `disabled`; `ethtool` needs root there), so it can't be reached away from home or woken once asleep.
8. **PowStream has no device auth** (L13) and no notion of which devices are stream sources/targets.

---

## 2. Design

Principles kept from REMOTE-POWOS §2.1: a device is authoritative for itself and works offline; keys are identity,
names are for people; every cross-device call is authenticated as a device; no root channel; actions are executed
by the owning device's own daemon. Added here: **capabilities, not device types**; **PowAuth approves, the realm
issues**; **one registry** (the existing unit/fleet registry), not a new store.

### D1. Device identity

- Each device makes a key pair once and never exports it: Android Keystore (the PowOS app; root not needed),
  `~/.local/state/powos/deviced/` (0700) on Linux/macOS, TPM-backed where available later.
- Its **device id** is derived from the public key (first 16 hex of its SHA-256). Names are labels.
- After enrollment (D2) the realm signs a **device certificate** (realm CA on PowStation; 30 days, renewed by the
  device with its own key while it is enrolled). It is the device's TLS client and server certificate for D4.
- Slice v0 (built): a random device id + a self-signed P-256 TLS key per device, pinned by each client at pairing.
  D2 replaces "pinned on first use" with "signed by the realm".

### D2. Enrollment through PowAuth (once per device, then automatic)

PowAuth (Authelia fork) already runs an OIDC provider and its validator accepts the **device authorization grant**
(RFC 8628, `oidc.GrantTypeDeviceCode`, `PowAuth/internal/configuration/validator/const.go:597`) - the flow made for a
device with no keyboard. Flow:

1. On the new device - first-run screen, the Devices app's "Join this device", or `powos devices enroll` - the device
   asks PowAuth for a device code (client `powos-device`, scope `powos.enroll`). It shows a **QR + the user code** on
   its own screen.
2. The user scans it with a device that is already signed in to PowAuth (the phone) and approves on PowAuth's
   consent page, which names the new device and its kind. Policy for this client: `two_factor`.
3. The new device polls the token endpoint, gets a short-lived access token, and calls the realm's enrollment
   service (`enroll.pow`, a small PowStation service, LAN/VPN only) with that token and: its public key, name, kind,
   platform, capabilities, and its **own** WireGuard public key.
4. The enrollment service (one writer, like the claude-auth authority) checks the token with PowAuth (introspection),
   then in one transaction: writes the device into the registry (D3), signs its device certificate (D1), adds its
   WireGuard peer with a fixed address (the private key never leaves the device - fixes gap 3), and returns the
   **endpoints bundle**: claude-auth URL + this device's AI credential (below), `android.pow`/store, git remotes,
   `llm.pow`, TURN, PowStream signalling, the hub's address, the realm CA.
5. The device applies the bundle itself: `endpoint.conf`, its WireGuard config (Linux: NetworkManager; Android:
   the PowOS app as `VpnService` or the WireGuard app via its import intent), trust roots. Nothing typed by hand.

**AI access per device.** The authority gains device credentials: the enrollment service registers
`device-id -> tenant` with claude-rate-limiter and hands the device a per-device bearer (or the device presents its
certificate), so revoking one device doesn't rotate the tenant for everyone. Until the authority has that, the bundle
carries the tenant secret and the registry records which devices hold it (revocation then rotates it, deliberately).

**Revocation** (gap 4): from the Devices app on any enrolled device (step-up: a fresh PowAuth login) or
`powos devices revoke <id>`. The enrollment service marks the device revoked in the registry, removes its WireGuard
peer, drops its claude-auth credential and its PowAuth sessions, and every device's agent refuses its certificate
(revocation list from the registry, cached for offline). The slice already revokes per pairing: `DELETE /v1/peers/<id>`
from any paired device, or `powos devices revoke` on the device itself.

**Offline fallback.** Two devices on one LAN without the hub can still pair directly with the code shown on the
target's screen (the slice's flow, D4). Those pairings stay local and are listed as "paired, not enrolled".

### D3. Registry: the existing unit/fleet registry, one more record kind

No new store. A device is a **host** the registry already knows (`units/<host>/`, `powos units`, the powos-agents
`unit` table the AI page reads; `PLATFORM.md`'s `POW_PLATFORM_HOST`). Enrollment adds one record per device:

```json
{"id": "device", "kind": "system", "host": "desktop", "owner": "system:devices",
 "device": {"id": "c46227ead3c53d80", "name": "Desk", "class": "desktop", "platform": "bazzite",
            "caps": ["status", "lock", "screen_off", "screen_on", "sleep", "wake", "stream_source"],
            "agent": "https://192.168.50.58:3416", "wg": "10.13.13.20", "wol": "30:c5:99:5b:ea:a2",
            "enrolled": "2026-11-07", "revoked": null, "holds": ["claude-auth:tenant-mats", "wg:peer"]},
 "purpose": "this device's enrollment", "files": ["~/.local/state/powos/deviced"]}
```

`holds` is what revocation undoes. The hub's copy is the truth (REMOTE-POWOS M1's `powos-hub` STDB, `agents.pow`);
every device caches it for offline. The Devices app reads it instead of its own list (the slice keeps the paired
list in the app's storage, secret-free, until then).

### D4. Control channel: one small agent per device, actions by capability

`powos-deviced` (built, `lib/devices/powos-deviced`) on every device:

- `GET /v1/info` (open): id, name, kind, `caps`. `GET /v1/status` (authenticated): online, power source + battery,
  accessories' batteries, screen on/off, locked, what keeps it busy, its NICs and Wake-on-LAN state.
- `POST /v1/action {action, force?, args?}` (authenticated): only advertised caps; unknown = 400, not advertised =
  404. Actions so far: `lock`, `screen_off`, `screen_on`, `sleep` (refused with the list of what would stop while a
  configured service or a GPU job runs; `force` is the user's explicit "Sleep anyway"), `wake` (this device sends a
  Wake-on-LAN packet for another one on its LAN), `ring` (reserved).
- Backends pick the mechanism, the protocol stays the same: KDE Plasma (logind `lock-session`, `kscreen-doctor
  --dpms`), the rooted phone (the session's adb to itself - a HACK, D5), a headless server (status, sleep, wake).
  New device classes add a backend, never a new protocol.
- Auth: HTTPS with the device's own certificate; every status/action call carries the caller's token (per pairing,
  stored as its SHA-256 only); no unauthenticated action, no bypass. After D2: mutual TLS with realm certificates
  plus a policy (an owner's device may act; a guest device may only read status).
- Discovery: mDNS `_powos._tcp` with TXT `id`, `v`, `dev=<port>`, `kind` (REMOTE-POWOS §2.2's service type); over the
  VPN, the registry's `agent` address.
- Relation to REMOTE-POWOS §2.6 (actions as reducer rows): the agent is the "owning host's daemon" that executes;
  the HTTPS call is today's transport because device STDBs are loopback-only (C16) until M4. Each action maps 1:1 to
  a future `device_action` row (id, by, ts, state, result, 60 s expiry); moving transports doesn't change the app.
- Existing daemons reused, not duplicated: logind and KScreen on the desktop, the units registry for what runs, the
  PowStream units for streaming. KDE Connect stays KDE's; it isn't a PowOS identity and isn't extended.

### D5. Non-root parity

The same enrollment and the same protocol on a non-rooted phone (memory: non-root parity is high priority):

- Enrollment is HTTP + a Keystore key: the PowOS app does it, no root.
- VPN: the PowOS app's own `VpnService` (WireGuard's userspace backend) or the WireGuard app via its import intent.
- The agent: the PowOS app serves `/v1/*` itself (a foreground-service socket): status from `BatteryManager` /
  `PowerManager`, `lock` = `DevicePolicyManager.lockNow()` (device admin, granted once), `ring` = a full-volume
  notification sound, `screen_on` = a full-screen wake intent. Today's rooted backend (adb to itself) is the HACK row
  in REMOTE-POWOS §4 until then.
- The Devices app itself is a plain PowOS app (`apps/devices`, in `apps/bundled.list`), so it ships inside the APK
  for non-rooted installs and uses `host.net` (the app's network grant, pinning, secrets) - no root anywhere.

### D6. PowStream

- Devices advertise `stream_source` (a PowStream server + GPU: Desk) and `stream_target` (a display and a
  client: phone, TV/PowFrame, laptop). The Devices app shows "Stream from Desk" on a target; the device list *is*
  the stream target picker.
- Signalling gets device auth: the target asks the source's agent for a stream ticket
  (`POST /v1/action {action: "stream_offer"}` - authenticated like every action), gets the signalling URL and a
  one-time ticket; `powstream-webrtc-server` validates the ticket with the agent on its own host (loopback). This
  closes gap 8 without PowStream growing its own accounts.
- A sleeping source is woken first (`wake` through an awake device on its LAN), then streamed.

---

## 3. First slice (built 2026-11-07)

- `lib/devices/powos-deviced` - the agent and its CLI (`powos devices ...`): v1 protocol, pairing with a code shown
  on the target (notification on a desktop; `powos devices codes`), per-peer tokens stored hashed, revoke, KDE /
  rooted-Android / server backends, guarded sleep, Wake-on-LAN sender, mDNS advert. Unit test
  `test/tier1/test-deviced.py` (real HTTPS: info-only when unpaired, wrong code, 5-try limit, 3 pending max, caps
  enforced, sleep refused while busy, revoke stops the token at once, CLI certificate pin).
- Deployed on Desk (`.58`) as a registered unit: `units/gpu-58/powos-deviced.json`, systemd `--user`
  (`lib/devices/powos-deviced.service`: 64M, 20% CPU, 32 tasks), `lib/devices/deploy.sh`. Sleep blockers there:
  llama-swap, powmap-scan, powstream-webrtc-server, powlens-sidecar, plus any GPU compute job.
- **Real test against `.58`** (from the Mac's CLI over the same protocol the app uses, paired with the code read
  from `.58`): status (mains, screen on, mouse 77% / keyboard 76%, busy list), `screen_off` -> status `screen off` ->
  `screen_on` -> `screen on`; `lock` -> `locked: true`; `sleep` -> refused, naming the four services and the GPU
  jobs; `ring` -> 404 (not advertised). Sleep was never forced; nothing was tested on macback, PowStation or gpu-195.
- `apps/devices` - the Devices app (PowOS app, every surface): paired devices with live status (polled every 5 s while
  shown), actions from each device's caps, optimistic (the result shows at once; a refusal rolls back with the
  device's words and Try again; busy sleep offers Sleep anyway), pairing from mDNS or an address, Forget (revokes
  this device there, drops the secret). Gate scene `app local.devices` (mock agent: pairing, token only as
  `${secret:dev-<id>}`, optimistic screen off, rolled-back lock, busy sleep).
- Not yet: the app shipped to the phone and paired from its UI (needs the coordinator's ship); deviced on the phone
  (desktop -> phone direction); Wake-on-LAN armed on `.58` (needs root there).

---

## 4. Plan

- [x] P0 Map of every device and link, gaps, design (this doc)
- [x] P0 `powos-deviced` v1 + unit test; deployed on Desk as a registered unit; real lock / screens off-on / guarded sleep
- [x] P0 Devices app (`apps/devices`, bundled) + gate scene
- [ ] P1 Ship the Devices app; pair the phone with Desk from the app (code on Desk's screen); check from bed
- [ ] P1 `powos-deviced` on the rooted phone (unit `units/phone/`, started by the session) so Desk's CLI/app sees the
      phone's battery and screen and can lock it
- [ ] P1 Arm Wake-on-LAN on Desk (`nmcli connection modify <eth> 802-3-ethernet.wake-on-lan magic` + firmware
      setting, needs root there) and run deviced on an always-on device (PowStation/Mac) as the waker
- [ ] P1 Make Desk a WireGuard peer (its own key) so the Devices app reaches it away from home
- [ ] P2 PowAuth OIDC client `powos-device` (device_code, two_factor) + `enroll.pow` enrollment service on PowStation
- [ ] P2 Endpoints bundle: `endpoint.conf`, WireGuard, trust roots applied by the device; `powos devices enroll`
- [ ] P3 Device records in the registry (D3) on the hub STDB; the Devices app reads them; units publish per device
- [ ] P4 Realm CA + device certificates; mutual TLS replaces per-pair tokens; revocation list cached offline
- [ ] P5 Non-root: the PowOS app serves the agent protocol (D5) and does enrollment + VPN; remove the adb HACK
- [ ] P6 PowStream: `stream_source`/`stream_target` caps, stream tickets through the agent, "Stream from" in the app
- [ ] P7 claude-auth per-device credentials (`device -> tenant`), revocation without rotating the tenant
- [ ] P8 Retire the runtime dev channels (vadb mirror, unrestricted `powos-phone` key) - REMOTE-POWOS M1/M2/M8
- [ ] P9 Enroll the rest: macback, gpu-195 (status + guarded sleep only), laptop/tablet, TV (PowFrame)

## 5. Open questions

- PowAuth's device flow is accepted by its validator; whether the deployed `powauth:latest` exposes the device
  authorization endpoint with the current `configuration.yml` needs a check before P2.
- Who may sleep a shared box: today `force` is any paired device of the owner; with guests (P4 policy) only owners.
- KDE Connect on Desk: leave alone (KDE's own), or turn it off once the Devices app covers it - the user decides.

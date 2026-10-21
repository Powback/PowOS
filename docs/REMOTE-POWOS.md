# Remote PowOS — PowOS hosts talking to each other

Status: **design** (2026-10-20). Nothing in §2 is built. §1 is the state of the tree and the Mac on that date, every
file:line read back from the code. §4 is the tree-wide `HACK:` registry, enforced by
`test/tier1/test-hack-registry.sh`.

Problem: PowOS runs on more than one machine (the phone today; the Mac's agents report as a PowOS host; desktops and
PowOS Web later), and those hosts already exchange data: agent state, mail, installs, approvals. Every one of those
exchanges goes through a developer channel (adb with root, an SSH login, a shell command in a container) that was
added for one feature. There is no shared design for discovery, identity, transport, sync or remote actions. This
doc lists what exists, designs the replacement, and orders the work.

Related: `docs/AGENTS-VIEW-DESIGN.md` (§4 cross-host, §6 actions, §7 who may do what, §10 phases),
`docs/POWOS-APPS-FEASIBILITY.md` (§3 identity, §4 cross-device sync), `docs/SYNC-ARCHITECTURE.md` (code and config
through git), `~/Projects/CLAUDE.md` (PowStation, Pi-hole, WireGuard, claude-auth).
Built on this: `docs/POWOS-COMPUTE-MESH.md` (resource sharing and moving containers between hosts).

Terms used here:

| term | meaning |
|---|---|
| host | one PowOS installation with its own SpacetimeDB and comms spool: `phone`, `mac`, later `desk`, `web` |
| hub | PowStation on the Mac (Colima VM at `192.168.50.100`): always on, holds the WireGuard server and Pi-hole |
| realm | the set of hosts one user owns; one identity issuer per realm |
| dev channel | a tool for a developer at a keyboard (adb, ssh, `rooted.sh`); acceptable for deploys, never as a runtime transport |

---

## 1. Inventory: every cross-device channel today

### 1.1 Topology

```
            Mac (192.168.50.99)                          Colima VM / PowStation (192.168.50.100)
  Claude sessions (role "coder")                         traefik, pihole (+ dns-sync), wireguard (10.13.13.0/24),
   └ ~/.claude/settings.json hooks                       claude-auth (:3128), android-app-dev store (android.pow)
       └ ~/.claude/hooks/powos-agents/powos-agentsd ──┐
                                                      │ docker exec -i powos-vadb adb shell "su -c '…'"
                                                      ▼
                                   powos-vadb container (network = wireguard container's netns)
                                                      │ adb over TCP 5555
                                                      ▼
            Phone (LAN 192.168.50.239, VPN 10.13.13.7) adbd :5555 ─► su (Magisk) ─► files in com.powos.app's data
              PowOS session: comms spool, SpacetimeDB 127.0.0.1:3410 (uid-locked), sshd :2222
              PowOS manager ──ssh (key "powos-phone")──► Mac login shell (tmux reads)
```

### 1.2 Channels

Kind: **R** = used at run time by a daemon or the app (a hack to replace); **D** = dev/deploy tool (fine at a
keyboard, must not be a runtime path); **I** = infrastructure the hosts depend on.

| # | kind | channel | where (file:line) | what it carries | why it's a hack | replaced in |
|---|---|---|---|---|---|---|
| C1 | R | **Agents mirror, Mac → phone** | `lib/ai/agents/powos-agentsd:22-24` (doc + `HACK:`), `:52-53` (throttle), `:699-718` (`Mirror`, `default_cmd`), `:821`/`:845` (`--mirror`); `~/.claude/settings.json` (14 hook events, each with `POWOS_AGENTS_HOST=mac POWOS_AGENTS_ROLE=coder POWOS_AGENTS_MIRROR=phone`); reader `targets/android/app/.../AgentsSpool.kt:24`, `:91-103`, `:233-242` | The Mac's whole folded state (agents, tasks, asks), the last 20 events per agent and the last 50 comms messages, as one JSON file `files/run/agents/mirror/mac.json`, at most every 15 s and only on change | Transport is `docker exec powos-vadb adb shell su -c 'cat > … && mv …'`: a root write into another app's data dir over a debug bridge. One-way. The `target` argument is ignored (always the phone's path). Silent when the container, adb authorization or VPN is down. Every push is one `su` (C5) | M2 |
| C2 | R (missing) | **Reverse `actions/` spool, phone → Mac** | designed only: `docs/AGENTS-VIEW-DESIGN.md:273` ("an `actions/` spool … carried by the same adb channel: HACK"), status note `:5-6` | Stop / end / pause / approve for the Mac's agents | Not built, so: `AgentsSpool.interrupt` is local only (`AgentsSpool.kt:187-198`, a pid means nothing on another host); a reply from the phone to a Mac agent goes into the *phone's* comms spool (`AgentsSpool.kt:176-185`); the Mac's hooks don't register `PermissionRequest` (not among its 14 events), so Mac agents never raise asks the phone could answer | M3 |
| C3 | R | **Ask answers as files** | `lib/ai/agents/powos-agent-ask:12-14`, `AgentsSpool.kt:154-170` | allow/deny for a PermissionRequest | §7 wants answers writable by the user only; on the phone the agents' uid *is* the app's, so an agent can write its own answer. Host-local today, but it is the trust model remote actions would inherit | M3 |
| C4 | R + D | **Mac → phone `adb shell su` commands** | `apps/install.sh:5,20-25` (push + `su -c … powos-run.sh "powos app …"`); `shell/push.sh:14-18,34-35` (su as the app's uid); `targets/android/rooted/rooted.sh:21-23` (`asu`, `in_powos`); `targets/android/install-app.sh:23-37`; `targets/android/system-module/build-module.sh:33` (default serial `192.168.50.239:5555`); `targets/android/kernel/phone-test.sh:12-15`; the pattern itself: `config/ai/context/capabilities.md:262` | Installs (APK, apps, shell overrides, system module, rootfs), test runs, and, from the Mac's Claude sessions (not in the tree): mail to the phone's `manager` (`powos comms send manager …` through `powos-run.sh`) and **inbox polls** of the phone's `coder` inbox | The deploy scripts are legitimate dev tools (D). Mail and inbox polling through them are a runtime transport (R): root on the phone for every message, polling instead of delivery, and each call one `su` (C5). Commit 12d41ca names "a runaway adb loop" among tonight's `su` sources | M6 (mail), M8 (deploys) |
| C5 | cost | **Magisk toast / 60 Hz flicker** (2026-10-19/20) | `powos-agentsd:52-53`; commits 92b41fc, 12d41ca; `targets/android/app/engine/src/main/java/andro/marchy/RootShell.java:13-22` | — | Every `su` is a Magisk superuser request that logs and shows a toast; on ColorOS each toast window caps the panel at 60 Hz while it shows. About 6 `su` per second (tiles, agent mail, widget checks, fold moves, the mirror at 1/s, an adb loop) made the display flicker between 60 and 120 Hz. Fixes so far: the mirror throttled to 15 s (92b41fc); the app's short root commands moved into one long-lived `RootShell` (12d41ca: 8 distinct `su` processes a minute afterwards, all but one long-lived). **RootShell does not cover C1/C4**: those `su` calls come from adbd's shell, not the app, so each Mac-side call is still one request and one toast. **Since 2026-10-20** the Mac side has its own equivalent, `lib/ai/agents/powos-rootsh`: one daemon per Mac user holding one `adb shell -T su` (framed, timed out, reopened on demand, idle exit after 30 min); the mirror and `powos-rootsh send`/`inbox` (the Mac's mail and inbox polls) go through it, so the phone sees one `su` per daemon lifetime. Deploy scripts (C4, D) still use `adb shell su -c` per call | M2, M6 |
| C6 | R + D | **adb endpoints** | adbd TCP kept on across reboots: `targets/android/rooted/powos-deploy.sh:104` (`persist.adb.tcp.port 5555`), `rooted.sh:13` (`wifi`). LAN `192.168.50.239:5555` (`build-module.sh:33`, `targets/native/PLAN.md:66`); VPN `10.13.13.7:5555` (`capabilities.md:269`); phone-local `127.0.0.1:5555`, whose key PowOS authorizes itself (`powos-deploy.sh:91-102`) and uses for Android apps as PowOS windows (`lib/android.sh:7-11`, `lib/phone.sh:27`, `targets/android/session/powos-android-app:18`, `powos-android-tasks:24`) | Shell, file push/pull, `su` | adbd listens on every interface: any holder of an authorized key on the LAN or VPN gets a shell, and with Magisk's grant to `shell`, root. Hard-coded IPs in scripts and docs. The phone-local use is on-device only, but keeps the same port open to the network | M5 (names), M8 (TCP off by default) |
| C7 | R | **`powos-vadb` container on the Mac** | referenced at `powos-agentsd:712-718`, `apps/install.sh:5,20-23`, `kernel/phone-test.sh:12`, `capabilities.md:331`, `AGENTS-VIEW-DESIGN.md:217`; not defined anywhere in the tree | Every C1/C4 call that must cross the VPN | An ad-hoc `docker run` (created 2026-10-19, restart policy `no`), image `android-app-dev-android-builder`, network `container:wireguard` (it borrows the WireGuard container's netns because the Mac itself is not a WireGuard peer), mounting the Mac's `~/.android` (the adb private key), one worktree's `shell/`, one Claude job's tmp dir (`/t`) and the store output. It does not survive a reboot or Colima restart, and the mirror then stops silently. **Since 2026-10-20** defined as a compose service, `targets/android/vadb/compose.yaml` (`restart: unless-stopped`; a stable state dir `~/.local/state/powos/vadb` at `/state`, its `xfer/` at `/t` instead of a job's tmp; a keepalive that reconnects adb; a health check, `vadb-health.sh`, that goes unhealthy and mails the phone's manager `--from vadb` when the mirror's pushes stop landing for 10 min). Still borrows wireguard's netns (`HACK:` in the compose file) | M2, M8 |
| C8 | R | **SSH key `powos-phone` on the Mac** | `~/.ssh/authorized_keys` line 2 (comment `powos-phone`; key not reproduced here); not in the tree. Phone side: the PowOS manager. Related: the phone's own sshd on 2222 (`targets/android/rooted/powos-start.sh:60-64`) | The phone's manager reads the Mac's tmux sessions (what the Mac's agents are doing) | The entry has **no options**: no `restrict`, no `command=`, no `from=`. Whoever holds the phone's private key has a full login shell as the Mac's user, from anywhere that reaches port 22. Compare the restricted pattern PowOS already uses for pihole-sync (`lib/containers-sync.sh:102-104`: `command="socat …",restrict`). Reading another host's tmux is what the agents rows (C1) are for | M2 (reads unnecessary), M8 (remove or restrict) |
| C9 | R | **Comms spools, one per host, not connected** | `lib/ai/comms/comms-mcp.py:49` (spool root is local), `:112`/`:255-264` (`agent-wake/`), `:210-244` (`agent-mail/`); `lib/ai/comms/comms.sh:20`; unread counts read the local spool only (`powos-agentsd:509-522`) | Agent ↔ agent and agent ↔ user mail | The phone has a spool (`~powos/.local/state/powos/comms`, plus `agent-mail/`/`agent-wake/` in `/run/powos-app`). **The Mac has none** (`~/.local/state/powos/comms` does not exist). The Mac's sessions report as role `coder`, and the `coder` inbox lives in the *phone's* spool. Mail crosses only through C4: Mac → phone by `adb su` + `powos comms send`, phone → Mac only when the Mac polls the phone's `coder` inbox over adb. A Mac agent's `unread` is always 0 | M6 |
| C10 | I | **`claude-auth.pow`** (fleet OAuth proxy) | `config/ai/context/capabilities.md:307`, `lib/config.sh:40`, `targets/android/docs/powos-ai-android.md:37`; `~/Projects/CLAUDE.md` (Claude Auth) | Every Claude API call from every host; the proxy injects the subscription's access token | Plain HTTP, resolved by Pi-hole/dns-sync, reachable from anything on the LAN or VPN; tenant secrets are routing tags, not authentication. Not a PowOS hack, but a dependency: away from LAN/VPN no PowOS host has AI. Pi-hole names are not identities | M4 (host tokens can gate it), §2.8 |
| C11 | I | **`robotsupremacy.pow`** | `apps/stickman/assets.sh:10` (build-time fetch), `apps/stickman/ui/widgets/parkour.tsx:15` (runtime link), `apps/stickman/ui/workers/sim.ts:10` (`HACK:` copy) | The stickman export and its full page | LAN-only HTTP name; the widget's link is dead off the LAN/VPN | — (fine as a link; see registry for the copy) |
| C12 | I | **`android.pow` store** (APK, rootfs, pacman repo) | `targets/android/build-app.sh:5`, `targets/android/publish-repo.sh:2-5`, `targets/android/app/engine/.../InstallActivity.java:36`, `SessionService.java:216-220` (`HACK:` `SigLevel TrustAll`) | Software for the phone, pulled over plain HTTP | Pacman packages unsigned and trusted. The APK carries its own signature. **Since 2026-10-20** the rootfs is checked: `InstallActivity` downloads it to a file, compares its sha256 with the one pinned in the APK (`engine/src/main/assets/powos-rootfs.sha256`, written by `build-rootfs.sh` when it publishes) and refuses on mismatch before unpacking anything; a local copy is checked the same way. The pin is a checksum, not a signature: it trusts whoever built the APK | M8 |
| C13 | D | **PowStation over SSH** | `lib/containers-sync.sh:80-122` (pihole-sync key, `REMOTE_DOCKER_HOSTS`), `:154` (`turn.env` copied over ssh); `bin/pow-compose:105` (DNS lookup over ssh) | DNS registration and the Docker API of a PowOS box, for PowStation | Restricted key (good). Its example target `macback@192.168.50.100` (`containers-sync.sh:52`) is stale: since 2026-08-21 `.100` is the Colima VM, not the Mac | §2.2 (directory), doc fix |
| C14 | R | **Deployed copies on the Mac** | `~/.claude/hooks/powos-agents/` (powos-agentsd, -hook, -ask, install-hooks.py; identical to the tree's on 2026-10-20), hooks in `~/.claude/settings.json` | The Mac's agent reporting | Copies outside any package: they drift as soon as the tree changes, and the host name `mac` is hard-coded per hook | M1 |
| C15 | R | **SpacetimeDB identities** | `shell/apps/stdb.ts:11-13` (`HACK:` anonymous server tokens); `powos-agentsd:779-788` (agentsd authenticates with the CLI owner token from `~/.config/spacetime/cli.toml`) | Who a client is to a database | No realm issuer: an identity on one host means nothing on another, and the reporter runs as the database owner | M4 |
| C16 | constraint | **SpacetimeDB is loopback + uid-locked** | `targets/android/rooted/powos-start.sh:66-76` (iptables chain `powos-local`, port 3410: PowOS's uid and root only) | — | Correct for today, and the reason nothing remote can subscribe yet. Remote access must be opened deliberately (§2.4), not by widening this rule | M2 |

Count: 16 channels (C1–C16). Of the `HACK:` markers in §4, 11 belong to these channels: `powos-agentsd` ×3,
`powos-rootsh`, `targets/android/vadb/compose.yaml`, `AGENTS-VIEW-DESIGN.md`, `powos-agent-ask`, `AgentsSpool.kt` ×2,
`stdb.ts`, `SessionService.java`. The rest are
Android/platform workarounds unrelated to remote PowOS.

### 1.3 What the hacks cost

- **Display quality.** C5: user-visible flicker from root calls that only existed to move data between hosts.
- **Root as a transport.** C1, C4, C6, C8: every cross-host write is root on the phone or a login shell on the Mac.
  One stolen key (the Mac's `~/.android/adbkey`, the phone's `powos-phone` key) gives root on the other machine.
- **Fragility.** C7: the whole Mac → phone path depends on one hand-made container with a session's tmp dir mounted.
- **One direction only.** C2, C9: the phone sees the Mac's agents but can't act on them; mail to the Mac is polled.
- **Hard-coded addresses.** C4, C6, C13: `192.168.50.239`, `10.13.13.7`, `192.168.50.100` in scripts and docs.

---

## 2. Target design

### 2.1 Principles

1. **One server per host, authoritative for its own data.** A host works alone (offline is normal). This is the rule
   both `AGENTS-VIEW-DESIGN.md` and `POWOS-APPS-FEASIBILITY.md` already follow.
2. **Rows cross hosts, never shell commands.** Data moves as SpacetimeDB subscriptions and reducer calls. No host ever
   runs a command on another host. adb and ssh stay dev channels.
3. **Every cross-host call is authenticated as a host and a principal** (user or agent), by tokens from one realm
   issuer, and authorized by the receiving module.
4. **Encrypted on every network**, LAN included: WireGuard between all hosts.
5. **Names are for people, keys are identity.** `.pow` names and mDNS names help find a host; a host is trusted only
   by its enrolled key.

### 2.2 Discovery

| where | mechanism | details |
|---|---|---|
| LAN | **mDNS/DNS-SD** `_powos._tcp` | Each host advertises `<host>._powos._tcp.local` with TXT `id=<host key fingerprint>`, `v=<protocol version>`, `wg=<WireGuard public key>`, `stdb=<port>`. Linux PowOS: avahi. Phone: the PowOS session's avahi, or the app's `NsdManager`; browse only while a remote view is open (Android's multicast lock costs battery), resolve from the directory's cache otherwise. Mac/hub: the hub container on the bridged Colima VM advertises for `mac` |
| VPN / away | **WireGuard + the host directory** | mDNS does not cross WireGuard. The hub keeps a `powos-hosts` module: `host(id, name, key, wg_pubkey, wg_ip, lan_addr, last_seen, version)`. Every host subscribes to it while it can reach the hub, and keeps the last copy. A host's WireGuard IP is fixed at enrollment (today's `10.13.13.7` becomes the phone's directory row, not a constant in scripts) |
| names | Pi-hole/dns-sync `*.pow` | Kept for people and for web routes (`agents.pow`). Never used to decide trust |

Order when a host wants peer *P*: a fresh mDNS answer whose `id` matches *P*'s enrolled key → *P*'s LAN address as
the WireGuard endpoint; else the directory's `wg_ip` through the hub; else *P* is offline (§2.8). `powos hosts`
lists the directory with reachability; scripts take `--host phone` instead of an IP.

### 2.3 Identity and authorization

One issuer per realm, per-host keys, per-app tokens (extends FEASIBILITY §3, "one issuer per device set").

- **Host keys.** Each host generates a P-256 key pair once: the phone in the Android Keystore (non-exportable), Linux
  hosts in `/var/lib/powos/identity/` (root, 0600), the hub in its container volume. The key never leaves the host.
- **Enrollment (pairing).** A new host shows a pairing code (QR + 6 digits); an enrolled host with the user present
  scans or types it; both show the other's fingerprint; the user confirms on both. The enrolling host writes the new
  host's row into `powos-hosts` and adds its WireGuard peer. First host = realm founder.
- **Realm JWKS.** The realm's verification keys are the enrolled hosts' public keys, published as one JWKS that
  every host serves locally and caches from the directory. A token is valid on any host if its `kid` is an enrolled,
  unrevoked host key.
- **Tokens** (JWT, ES256). `iss` is the same realm URL on every host, so SpacetimeDB's `identity = hash(iss, sub)`
  gives one user the same identity everywhere (what §2.5 depends on).

  | sub | minted by | aud | lifetime | used for |
  |---|---|---|---|---|
  | `user:<u>` | the trusted shell on the user's host, after device unlock | `<appid>` | 1 h, refreshed | apps, viewers, actions, answers |
  | `agent:<role>@<host>` | the host's agent launcher | `powos-agents`, `powos-comms` | 1 h | reporting, sending mail |
  | `host:<id>` | the host's identity service | the peer host | 10 min | sync agents, comms delivery, directory |

  Tokens carry `host` and `kid`; a module checks that a token's `host` claim matches the key that signed it, so a host
  can mint only for itself. Pages get tokens through `apps.token()` and never choose their own (FEASIBILITY §3).
- **Authorization** stays in the modules: each reducer checks `ctx.sender`'s kind (`user`/`agent`/`host`) and host.
  The existing `powos-agents` reporter table (`apps/agents/module/src/lib.rs:243-257`, `allow_reporter`) is the model:
  a writer may write only its own host's rows.
- **Revocation.** Removing a host deletes its row and key from `powos-hosts` (the directory replicates the deletion,
  §2.5) and its WireGuard peer. Every host then rejects its `kid`. SpacetimeDB checks tokens when a connection opens,
  so each host's identity service also drops open connections from revoked senders, and short lifetimes bound the
  window. A lost phone is revoked from any other enrolled host with the user present.

**To verify before M4:** that SpacetimeDB 2.12 standalone accepts tokens from an issuer whose JWKS is served by a
local endpoint (its OIDC path), or else the smallest change that does (a patch, as for the idle wakeups). Today it is
started with a single `--jwt-pub-key-path` (`lib/apps/services/spacetimedb.json:14`, FEASIBILITY §1.1).

### 2.4 Transport

- **Network.** WireGuard between every pair of hosts, on the LAN too (endpoint = the LAN address from mDNS: direct,
  same crypto). The hub is the always-on peer and relays when two hosts can't reach each other. The Mac itself
  is not a peer today (C7); the hub container joins the WireGuard network instead, and the Mac's agents talk to the hub
  over the Docker network.
- **Protocol.** SpacetimeDB's own WebSocket subscriptions and HTTP reducer calls, host to host, with `host:` or
  `user:` tokens. No adb, no ssh, no custom daemon protocol.
- **Listener.** Each host's SpacetimeDB gets a second listener on its WireGuard address only (C16's loopback rule
  stays as it is). The firewall accepts that port only on the WireGuard interface, and only from enrolled peers'
  `wg_ip`s. Defence in depth: WireGuard peer list, then the token, then the reducer's check.
- **Where the Mac's agents live.** On the hub: a `powos-hub` SpacetimeDB container on PowStation (`agents.pow`, LAN
  and WireGuard only, never on powback.com: `AGENTS-VIEW-DESIGN.md:219,287`). The Mac's `powos-agentsd` writes there
  with `--sink stdb`, as a `host:mac` reporter.

### 2.5 Data sync model

Three kinds of data, three rules:

| kind | examples | rule |
|---|---|---|
| **Host-owned, read remotely** | agents, tasks, events, asks, host status | No replication. The owning host's module is the truth. A remote viewer subscribes to it directly and keeps the last snapshot for display while offline, marked stale with its age. This is AGENTS-VIEW-DESIGN Phase 2 ("viewers subscribe to several servers") |
| **User data that must work offline everywhere** | an app's notes, lists, settings an app syncs | **FEASIBILITY §4 option B**, per table, opt-in: below |
| **Code and bundles** | apps, modules, the shell, config | Not through SpacetimeDB: git (`SYNC-ARCHITECTURE.md`) or the store, published locally on each host |

**Option B, made concrete.**

1. **Opt-in.** The manifest lists synced tables: `"sync": { "tables": ["note", "tag"], "peers": "realm" }`. A
   module helper adds the bookkeeping; unsynced tables are untouched.
2. **Rows.** Each synced row has `id: uuidv7`, `origin: host id`, `hlc: u64`, `deleted: bool` (a tombstone).
3. **HLC.** 48 bits of wall-clock milliseconds and a 16-bit counter. A host takes `max(local clock, highest hlc seen)`
   on every write and receive, so causality holds under clock skew. A received `hlc` more than 1 h ahead of the local
   clock is refused and logged (a broken clock, not a newer write).
4. **Outbox.** Every reducer that writes a synced row also appends `(table, id, hlc, payload)` to `_outbox`, in the
   same transaction.
5. **Sync agent.** One per host, identity `host:<id>` (a token, §2.3). For each peer it subscribes to the peer's
   `_outbox` after its stored cursor and calls `_sync_apply(batch)` on its own server; the peer does the same in the
   other direction. Cursors per peer in `_sync_state`. Hosts form a mesh (each pair that can reach each other syncs;
   the hub reaches all), and applying a row is idempotent, so a row that arrives twice by two routes is harmless.
6. **Merge.** Last-writer-wins per row by `(hlc, origin)`; an app may declare per-field merge for a table; text and
   lists that people edit concurrently go in a CRDT column (Automerge/Yjs bytes, merged in the module: option E inside
   B). `_sync_apply` never writes to `_outbox`, so nothing echoes.
7. **Schema.** Each synced table has a schema version. The sync agent refuses to apply across incompatible versions
   and reports it (`powos app sync status`); additive changes are compatible.
8. **Garbage.** An outbox entry goes once every peer's cursor is past it; a tombstone after that plus 30 days. A peer
   offline longer than that gets a full resync of the table.

### 2.6 Remote actions: reducers, not signals or adb

Every action on another host is a row written by a reducer on the **owning** host, executed by that host's own
daemon.

| action | reducer (owning host's module) | executed by | checks |
|---|---|---|---|
| stop / end session | `act(agent, "stop" \| "end")` | that host's `powos-agentsd` (SIGINT / SIGTERM to the local pid) | sender is `user:*` from an enrolled host |
| pause / resume | `act(agent, "pause" \| "resume")` | agentsd (the `paused/` gate) | same |
| approve / deny an ask | `answer(ask, behavior, reason)` | `powos-agent-ask` waiting on the ask's row | same; **an agent identity can never call it** (removes C3) |
| mail | `deliver(msg)` (§2.7) | the host's comms bridge | sender's token decides `from` |
| install an app | `request_install(app, version)` in `powos-registry` | the host's `powos app` (fetches the signed bundle from the store) | `user:*`, and the user confirms on the target host if it's not the one they're holding |

Rules: an action row has `id: uuidv7`, `state` (`pending → done | failed | expired`), `by`, `ts` and a result. A
pending action older than 60 s is marked `expired` instead of run, so a host coming back online never stops an
agent hours late. Action rows are the audit log.

### 2.7 Comms federation

- **Namespace.** One mailbox namespace for the realm: `role@host` (`manager@phone`, `coder@mac`, `user@*`). A bare
  `role` means the local host, so every existing `powos comms send <role>` keeps working.
- **Delivery.** The local spool stays the delivery mechanism (agents block on it with `wait_for_message`; nothing in
  the agents changes). Sending to another host writes an outbox row in the host's `powos-comms` module; the comms
  bridge calls `deliver(msg)` on the target host as `host:<id>`; the target's bridge writes the message into its spool
  (one file, as today) and wakes the role (`agent-wake/` on the phone).
- **Store and forward.** Undelivered mail waits in the sender's outbox until the peer is reachable; ids are uuidv7,
  and `deliver` is idempotent. Mail is the one action type that is queued, not expired.
- **Sender.** `from` comes from the token (`agent:coder@mac`), not from a command-line argument. `--from user` is
  accepted only from a `user:` identity.
- **The user's mailbox.** `user@*` delivers to every host where the user is present; notifications appear on the
  device that shows them (the phone's `agent-mail/`), and read marks sync like any other row.
- **The Mac.** Gets its own spool and `coder@mac` inbox on the hub's side; the phone's stray `coder` inbox is drained
  into it once (M6).

### 2.8 Offline behaviour

| situation | behaviour |
|---|---|
| Host alone (no LAN, no VPN) | Everything local works: apps, agents, comms, tokens (minted locally), the cached directory and JWKS. AI needs `claude-auth.pow` (C10), so it is unavailable, and says so |
| A peer unreachable | Its panels show the last snapshot and "last seen <age>". Actions to it fail at once ("mac is offline"); mail queues; sync cursors wait |
| Coming back | Subscriptions reopen, sync agents resume from their cursors, outboxes drain, expired actions stay expired |
| Hub down, two hosts on one LAN | mDNS finds the peer; WireGuard direct; everything but the directory's updates keeps working |
| Clock wrong | HLC keeps order; a far-future `hlc` is refused (§2.5) |

### 2.9 Security

- **No root channel across hosts.** No runtime path uses adb, `su` on behalf of another host, or ssh. A compromised
  host can do only what its tokens allow in other hosts' modules, and is revoked from any other host.
- **adb TCP off by default.** `persist.adb.tcp.port` is set only by an explicit `powos dev adb on`, bound to the
  WireGuard interface, and turned off again by `powos dev adb off` (or a timeout). The phone-local `127.0.0.1:5555`
  use (Android apps as PowOS windows) moves to a loopback-only listener or a local socket.
- **SSH.** No unrestricted cross-host keys. The `powos-phone` entry on the Mac is removed once the agents rows replace
  tmux reads, or restricted (`restrict,command=…,from=<phone wg ip>`) if a read-only tmux view is still wanted.
- **Rows carry no secrets** (AGENTS-VIEW-DESIGN §3 already scrubs them); tokens are never stored in rows or logs.
- **Signed software.** The pacman repo is signed (removes the `SessionService.java` `HACK:`); the rootfs and app
  bundles carry a checksum signed by the realm or the build key, checked before install.
- **The shell's native bridge is top-frame-only** (2026-10-21): PowosHost/PowosNative/PowosBoot are web message
  listeners limited to https://shell.powos's top frame (ShellOrigin.kt), no longer JavaScript interfaces injected into
  every iframe - so a presentation, web content or a third-party app's frame can't reach host.net.fetch's secrets,
  app launch/uninstall or settings. No workaround left (no `HACK:` row); check: `tools/phone/bridge-check.sh`.
- **Step-up for remote approval.** `answer` and `act` from a host other than the agent's own require a `user:` token
  minted within the last 5 minutes after an unlock, so a phone left unlocked on a table can't approve tool calls for
  long.

### 2.10 What stays a dev channel

`rooted.sh`, `install-app.sh`, `build-module.sh`, `phone-test.sh`, `shell/push.sh` keep using adb: they are run by a
developer at a keyboard and need root on purpose (flashing, system module, rootfs). They take `--host` names from the
directory (M5) and work through `powos dev adb on`. Nothing that runs unattended may call them.

---

## 3. Migration plan

Each step is shippable alone and removes a hack. Order matters: identity (M4) gates exposing anything beyond the hub.

| step | do | removes | unlocks |
|---|---|---|---|
| **M0** | This doc; the `HACK:` registry and `test-hack-registry.sh` | — | One list of every hack; new ones can't go unrecorded |
| **M1** | `powos-hub` SpacetimeDB container on PowStation (`agents.pow`, LAN/WireGuard only, joins the WireGuard network), `powos-agents` published there. The Mac's agentsd gets `--sink stdb` to it as `host:mac`. Install the Mac's hooks from a package/`powos self` instead of copies | C14 (copies) | The Mac's agents in a real database, queryable by any viewer |
| **M2** | Phone: `StdbSource` subscribes to the hub's `powos-agents` over WireGuard (an interim per-device viewer identity until M4). Delete `Mirror`, `--mirror`, the `mirror/` folder reader and the hooks' `POWOS_AGENTS_MIRROR` | C1, C5 (Mac side), C7 for agents, C8's reason; `HACK:`s at `powos-agentsd` ×3, `AgentsSpool.kt:24`, `AGENTS-VIEW-DESIGN.md:218` | Mac agents on the phone with no adb, no root and no toasts; on any other PowOS host too; survives Mac and Colima restarts |
| **M3** | `act` and `answer` reducers; agentsd executes its own host's actions; `powos-agent-ask` waits on the ask row. Enable `PermissionRequest` in the Mac's hooks | C2, C3; `HACK:`s at `powos-agent-ask:12`, `AgentsSpool.kt:154` | Stop, pause and approve the Mac's agents from the phone; approvals that agents can't forge |
| **M4** | Realm issuer: host keys, pairing, realm JWKS, token minting in the shell and launchers; SpacetimeDB trusts the realm (verify §2.3 first); host listeners on WireGuard only | C15; `HACK:` at `shell/apps/stdb.ts:11` | One identity per user across hosts; per-app tokens; the interim M2 identity goes; a second hub-independent pair of hosts can talk |
| **M5** | Discovery: `_powos._tcp` mDNS, the `powos-hosts` directory, `powos hosts`; scripts take `--host` | Hard-coded IPs (C4, C6, C13) | Hosts found by name on any network; LAN-direct paths when the hub is down |
| **M6** | Comms federation: `powos-comms` module + bridge per host, `role@host`, `deliver`; the Mac gets `coder@mac` | C9; the mail and inbox-poll half of C4; the rest of C5 | Mail both ways without root or polling; store-and-forward while a host is away |
| **M7** | Per-table sync (§2.5) in the module helper; first adopter: one small app (e.g. `apps/counter`) | — | User data on every host, offline-first |
| **M8** | Dev-channel cleanup: adb TCP off by default (`powos dev adb on/off`), remove or restrict the `powos-phone` key, `powos-vadb` as a compose service (or gone), signed pacman repo, signed/checksummed rootfs and bundles, installs via `request_install` | C6, C7, C8, C12; `HACK:` at `SessionService.java:216` | No root path between hosts at all; integrity of everything a host installs |

---

## 4. HACK registry

**Rule:** every `HACK:` comment in the tree is listed here, and a commit that adds, moves to another file or removes
one updates this table in the same commit. `test/tier1/test-hack-registry.sh` fails when a file's number of `HACK:`
markers differs from its number of rows here (a missing row or a stale one). Line numbers are as of the last edit of
this table; the test compares per-file counts, not lines, because other edits move them. A mention of the
convention itself written as `` `HACK:` `` (in backticks) is not a marker. Vendored code (`targets/web/third_party/`)
is not scanned. A marker in the code says *why* and *the real fix* where it stands; the row here is the one-line index.

108 markers on 2026-10-21.

<!-- hack-registry:start -->
| marker | why | real fix |
|---|---|---|
| `apps/stickman/ui/workers/sim.ts:10` | The stickman sim and brain are copied from robotsupremacy's stickman.ts: there is no browser core library to import. | robotsupremacy's stickman/web/PLAN.md step 1 (sim + brain as a library); import it. |
| `docs/AGENTS-VIEW-DESIGN.md:218` | The design's own copy of the mirror's marker: adb used as the cross-host transport (C1). | REMOTE-POWOS.md M2: the phone subscribes to the hub's powos-agents module; delete the mirror. |
| `docs/AGENTS-VIEW-DESIGN.md:333` | The work board's note of the CLI's own marker: `powos agents task` off the phone runs on the phone over powos-vadb (C4/C7). | Each host's own powos-agents module and the M2 subscription; the hub merges the hosts' boards. |
| `hosts/gpu-195/bin/powos:4` | gpu-195's image (powos 0.3.0, built from master) has no `powos units`, an image update needs rpm-ostree + a reboot, and the box's desktop was in use: `/usr/local/bin/powos` routes `units` to a git checkout of worktree-powos-multiplatform, the rest to the image's CLI. | An image with powos-units on the branch the box tracks; `rpm-ostree upgrade` + reboot at a quiet time; `sudo rm /usr/local/bin/powos` (unit `powos-units-shim`). |
| `lib/ai/agents/powos-agents-cli:222` | `powos agents task ...` off the phone (no local powos-agents module) runs itself on the phone through `docker exec powos-vadb adb shell su` (C4/C7): one `su` per call. | Each host's own powos-agents module and the M2 subscription; the hub merges the hosts' boards. |
| `lib/ai/agents/powos-agent-ask:12` | On the phone the agents' uid is the app's, so an answer file's owner can't prove the user wrote it (C3). | REMOTE-POWOS.md M3: an `answer` reducer that checks ctx.sender is a user identity. |
| `lib/ai/agents/powos-agentsd:24` | The Mac's agents reach the phone through `adb shell su -c` via powos-vadb (C1). | REMOTE-POWOS.md M2: the phone subscribes to the hub's powos-agents; the mirror is deleted. |
| `lib/ai/agents/powos-agentsd:53` | Mirror throttled to 15 s because every push is an `su` (Magisk toast, panel capped at 60 Hz) (C5). | REMOTE-POWOS.md M2: no push at all; rows over a subscription. |
| `lib/ai/agents/powos-agentsd:699` | The Mirror class itself: a shell command (docker exec powos-vadb adb shell su) as transport (C1). | REMOTE-POWOS.md M2. |
| `lib/ai/agents/powos-rootsh:4` | One long-lived `adb shell su` on the phone for the Mac's tools (mirror, mail): a dev channel as runtime transport (C1, C4, C5). | REMOTE-POWOS.md M2 (mirror) and M6 (mail): nothing on the Mac needs root on the phone; delete it. |
| `lib/apps/powos-app:672` | `powos app dev` polls source files (stat, 4x/s) because Python's stdlib has no inotify. | inotify through ctypes, or inotifywait when the image ships inotify-tools. |
| `lib/apps/powos-autosleep:269` | Android's battery saver has no sysfs file or property: the autosleep watcher asks `cmd settings get global low_power` through Android's mount namespace (pid 1's), ~30 ms a scan. | The PowOS app publishes the power state (saver, screen, battery) to PowOS, e.g. a SpacetimeDB table the watcher subscribes to. |
| `lib/apps/powos-autosleep:342` | A sleeping container is frozen with PowOS's own cgroup v2 group (`/sys/fs/cgroup/powos/<name>/cgroup.freeze`), not `podman pause`: podman runs with `--cgroups=disabled` on the phone and refuses to pause a container without a cgroup. | Memory/cpu on cgroup v2 (PHONE-KERNEL-CONTAINERS §9.3), then podman's own cgroup and `podman pause`. |
| `lib/apps/powos-container:305` | On the phone an OCI hook is each container's cgroup manager (podman `--cgroups=disabled`): Android keeps memory/cpu on cgroup v1 at `/dev/memcg` / `/dev/cpuctl`, which crun's manager can't drive. | Memory and cpu on cgroup v2 beside Android's own use (PHONE-KERNEL-CONTAINERS §9.3), then podman's own limits; delete the hook. |
| `lib/apps/powos-container:423` | vfs storage (a full copy per container) when the ext4 image can't be made: overlayfs refuses f2fs as its upper layer. | The ext4 image (the overlay path), or an f2fs overlayfs accepts. |
| `lib/apps/powos-container:437` | The container storage image carries vold's SELinux label (`vold_data_file`): the loop driver does its I/O as the kernel domain, which may only read/write a few types. | A type of our own in the system module's sepolicy (`allow kernel powos_container_image:file { read write }`). |
| `lib/apps/powos-container:463` | Overlay storage on an ext4 filesystem in a file (`/var/lib/containers/powos.img`, loop): overlayfs refuses f2fs as its upper layer. | An f2fs/overlayfs combination that works, or an ext4 partition of our own. |
| `lib/apps/powos-container:665` | `powos containers exec` stops the exec'd shell, moves it into the container's groups and continues it: crun exec joins no cgroup with `--cgroups=disabled`. | Memory/cpu on cgroup v2 (§9.3), so crun's exec joins the container's cgroup itself. |
| `lib/apps/powos-container:704` | `--rootfs /` (the runtime's container mode without an image) becomes a read-only non-recursive bind of / at `/run/powos-containers/hostroot`: crun can't pivot_root onto its own root (EBUSY). | crun binding such a rootfs itself before pivot_root (upstream). |
| `lib/apps/powos-glasses:94` | `powos glasses` waits for the app's answer by re-reading status.json every 100 ms (5 s at most): a bounded poll. | A reply to block on: an inotify watch on status.json, or the app answering on a socket. |
| `lib/apps/powos-sleep-gui:161` | GUI sleep's "is PowOS on screen" signal (Steam's instant resume) is parsed from the display daemon's log (`andromarchy.log`: "surface N: consumer connected/disconnected"), watched with inotify: nothing publishes the visible surfaces as state. | The display daemon (or SessionService) writes the connected surfaces to a state file in the run dir, or KWin's anland backend exposes them (D-Bus / a KWin script property). |
| `lib/apps/powos-sleepd:358` | Stop-mode sleep hands a service's port back by closing powos-sleepd's listener once the backend restarts: a connection in that gap is refused, a fast backend may fail to bind once. | Socket activation proper: the listening socket passed to the backend (LISTEN_FDS); backends take one. |
| `targets/android/install-app.sh:66` | The app is compiled at install (`speed`) by flipping `pm.dexopt.install` around our own `adb install` and putting it back: the APK has no profile, so the default filter compiled nothing and the app ran interpreted after every install. | A baseline profile in the APK (`src/main/baseline-prof.txt`, a `.dm` installed with it) so speed-profile compiles the hot code. |
| `lib/apps/powos-supervisor:19` | Own supervisor with soft budgets: systemd --user limits need a delegated cgroup v2 subtree Android doesn't give. | The cgroup v2 move (FEASIBILITY §2.4), then one unit per manifest; delete the supervisor. |
| `shell/apps/pages.ts:98` | The recent strip places PowOS apps by when the host's front app changed: `usage.recent` comes without times. | `usage.recent` with each app's last time (ShellBridge.kt) and PowOS apps' opens recorded there, one list ordered by time. |
| `shell/apps/stdb.ts:11` | Apps use the server's anonymous per-database tokens: there is no PowOS issuer yet (C15). | REMOTE-POWOS.md M4: the shell mints per-app JWTs from the realm issuer. |
| `shell/index.html:28` | The boot guard names a failed module's blob: URL through es-module-shims' private registry (`importShim._r`): there is no public lookup. | es-module-shims naming the source URL in its link errors (upstream), or a loader of our own. |
| `shell/ui/apps.tsx:137` | An icon 404 can't tell "not drawn yet" from "no icon", so a lasting failure is taken as "no icon". | The host sends icon: null for failed lookups (ShellBridge.apps(), Runtime.refreshApps). |
| `shell/ui/dockdrop.ts:86` | The Android host's home (ShellHome.add) refuses a PowOS app's p: key, so a PowOS app dragged off the dock (or swapped out of it) is only unpinned, not put on home. | ShellHome.add stores p: apps as shortcuts the page launches (openApp), as it does Android's and Linux's. |
| `shell/ui/pet.tsx:35` | The pet's stylesheet (ui/pet.css) is linked from the module, not index.html, so the pet ships as files of its own while other agents edit index.html. | A `<link ... data-hot>` in index.html next to the others; drop the module's own link. |
| `shell/ui/terminal.tsx:240` | xterm's fit addon always reserves a 14 px scrollbar strip; the holder is widened past the view to fill it. | An addon option for the reserve, or fit from the renderer's cell size. |
| `sources/powos-shell/src/main.cpp:33` | Every window of powos-shell is a layer surface via `QT_WAYLAND_SHELL_INTEGRATION=layer-shell` (unset again after the panels exist): QWidget re-creates a QWebEngineView's window at first show and the re-created one loses LayerShellQt's per-window integration (it came up as a decorated xdg_toplevel). | The views as QtWebEngineQuick WebEngineViews in QQuickWindows (OpenGL from creation), or LayerShellQt re-applying its integration on re-create. |
| `sources/powos-shell/src/bridge.cpp:42` | KWin 6.7's blur capability (ext_background_effect_v1) reaches KWindowSystem ~0.5 s after the first window and KWindowEffects has no change signal: the glass hello is answered again at 500 ms / 3 s. | A change signal in KWindowSystem, or binding ext_background_effect_manager_v1 in powos-shell and following its capabilities event. |
| `targets/android/app/app/src/main/aidl/dev/omalauncher/shell/tiles/IQSService.aidl:30` | Copy of a hidden framework interface (IQSService) under its own name, to host quick-settings tiles. | None for an app (only SystemUI hosts tiles); a public tile-host API. |
| `targets/android/app/app/src/main/aidl/dev/omalauncher/shell/tiles/IQSTileService.aidl:25` | Copy of the hidden IQSTileService interface (as IQSService.aidl). | Same as IQSService.aidl. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/AgentMail.kt:340` | Deprecated ACQUIRE_CAUSES_WAKEUP / SCREEN_BRIGHT_WAKE_LOCK turn the screen on for urgent mail (works at targetSdk 28 only). | A full-screen intent to PowOS's lock face once targetSdk moves up. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/AgentsSpool.kt:24` | Reads agents/mirror/<host>.json, written by the adb mirror (C1). | REMOTE-POWOS.md M2: StdbSource subscriptions per host replace the mirror folder. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/AgentsSpool.kt:154` | Ask answers are files the agents' uid could also write (C3). | REMOTE-POWOS.md M3: the `answer` reducer. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/Runtime.kt:373` | Rooted: the server socket can't be created (priv_app may not create sock_files in its data); start continues without it. | priv_app sock_file rules in the system module's sepolicy, or an abstract socket. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/glasses/G2Glasses.kt:269` | No clear/exit command is known for the G2: blanking sends an empty teleprompter page (a whole ~2.5 s text sequence). | Capture the Even app closing its display (HCI log) - the module's EvenHub shutdown (0x14-20) is an unverified guess - and send that. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/linux/Proot.kt:76` | Root clears the app's own dir (sock_files a priv_app can't remove). | Same sepolicy rule, or no sockets in app data (abstract sockets). |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/AppWidgets.kt:566` | Widget clicks would launch on the private virtual display; the hidden interaction handler is set by reflection. | None for a launcher; a public "launch on this display" option for AppWidgetHostView. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/HighRefresh.kt:14` | ColorOS caps unlisted packages at 60 Hz; the window asks for the fastest mode while touched. | None in PowOS; ColorOS listing the package or honouring AOSP frame-rate votes. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/PowosDozeService.kt:32` | canDoze/startDozing are hidden DreamService API, reflected. | None public: the doze component is a system role. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/QuickSettings.kt:39` | Quick-settings switches go through root (svc/cmd/settings in a su shell). | The privileged permissions SystemUI's tiles hold, on the system app's allowlist (mostly signature-only). |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/QuickSettings.kt:251` | Hotspot state via hidden WifiManager.isWifiApEnabled. | TetheringManager's callback (TETHER_PRIVILEGED, signature). |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/QuickSettings.kt:318` | WRITE_SETTINGS app-op granted through root on the user's behalf. | The user grants it on the Settings page. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/ShellBridge.kt:333` | StatusBarManager expand/collapse panels are not public API (as every third-party launcher does). | An accessibility GLOBAL_ACTION_NOTIFICATIONS (user opt-in, open only) or SystemUI's motion proxy. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/ShellNet.kt:55` | host.net takes the app id the island gives: islands share the shell page's one origin, so one could name another app's id and use its "net" grants and secrets. | Per-app origins (islands in `<id>.app.powos` frames, FEASIBILITY §6.1) and the id taken from the calling frame's origin. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/ShellMedia.kt:43` | Media output switch through SystemUI's internal MediaOutputDialogReceiver. | None public (switching another app's output takes MEDIA_CONTENT_CONTROL). |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/TileHost.kt:46` | Hosting tiles at all uses hidden framework interfaces copied into aidl/. | None for an app; only SystemUI hosts tiles. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/TileHost.kt:69` | Hidden BIND_FOREGROUND_SERVICE_WHILE_AWAKE bind flag (SystemUI's). | None public; BIND_IMPORTANT is close but keeps the process up with the screen off. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/TileHost.kt:368` | Hidden TileService extra names and Intent.putExtra(String, IBinder); binders passed in a Bundle. | None public. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/TileHost.kt:444` | Tile's constructors are hidden; built from a Parcel in Tile.writeToParcel's layout. | None public; a layout change shows as a garbled tile. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/GlassBlur.kt:36` | The shell's live glass: hidden Transaction.setBlurRegions on the window's surface (ViewRootImpl.getSurfaceControl), each region encoded by the framework's own BackgroundBlurDrawable.BlurRegion.toFloatArray (the OEM's layout - 31 floats on OxygenOS 16 - never hand-built), reflected. | A public blur-region API (none: Window.setBackgroundBlurRadius blurs the whole window), or the regions set from the platform-signed side - a SystemUI-side hook shipped by the PowOS system module, fed the page's rects over a binder. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/WallpaperBackdrop.kt:25` | The live wallpaper behind home for the liquid glass: hidden IWindowManager.mirrorWallpaperSurface + ScreenCapture.captureLayers (fallback IWindowManager.captureDisplay excluding home's window) (READ_FRAME_BUFFER, held via the recents role), reflected. | A public wallpaper-backdrop API (none), or the frames handed over by PowOS's platform-signed system-module hook as a HardwareBuffer. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/WindowBlur.kt:14` | Hidden ViewRootImpl.getSurfaceControl / Transaction.setBackgroundBlurRadius, reflected. | None for an app (the public blur relayouts the window). |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/ShellWallpaper.kt:121` | Another app's live wallpaper has no picture an app can ask for: OxygenOS's own screenshot of it (`/data/system/users/<u>/wallpaper_screenshot.png`) read as root, for the shell's glass. | None in the platform API; elsewhere the wallpaper's thumbnail. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/HiddenApi.kt:13` | Lifts hidden-API checks for the listed classes (org.lsposed.hiddenapibypass). | None for an app: the calls are the platform-signed system UI's. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/ShadeHost.kt:231` | Hidden StatusBarManager.expandSettingsPanel / expandNotificationsPanel. | PowOS's own quick-settings page (notifications.tsx grown into the control center). |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/ShadeHost.kt:300` | Hidden StatusBarManager.disable/disable2, reflected. | None public (kiosk/setup flows use them the same way). |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/gesture/EdgeGestures.kt:48` | Edge gestures' Back through SystemUI's ISystemUiProxy.onBackEvent(null) (the recents provider's binder). | None without INJECT_EVENTS; Quickstep's taskbar back calls the same. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/Switcher.kt:178` | `preloadRecentsActivity` is a hidden API, reached by reflection past the hidden-API checks, to create home invisibly before the first swipe. | A system-side preload hook (the recents provider owning home's lifecycle) instead of reflection. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/RecentsWatchdog.kt:29` | SystemUI's LauncherProxyService gives up re-binding the recents service after the app dies several times in a row (low-memory kills), which drops PowOS's gesture input; a no-op ENABLED/DEFAULT flip of the service component (DONT_KILL_APP) sends the PACKAGE_CHANGED that makes it bind again. | LauncherProxyService re-binding without giving up (a SystemUI patch via the system module), or PowOS's own system UI owning the binding. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/Switcher.kt:326` | A timeout releases the card if the page never answers. | None needed while the page answers; a safety net. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/Tasks.kt:87` | WM Shell's hidden ISplitScreen called by hand (transaction codes of this SystemUI). | None for an app. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/Tasks.kt:118` | Hidden ActivityOptions.setLaunchWindowingMode, reflected. | None for an app. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/Tasks.kt:245` | IActivityTaskManager hidden binder calls, reflected. | None for an app (see HiddenApi.kt). |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/gesture/GestureMonitor.kt:24` | Hidden InputManager.monitorGestureInput / InputMonitor / InputEventReceiver. | None for an app; system gesture providers are platform-signed. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/gesture/RecentsTransition.kt:50` | WM Shell's hidden recents interfaces written by hand, with compile-time stand-ins. | None for an app; Quickstep compiles against the platform's copies. |
| `targets/android/app/app/src/main/kotlin/dev/omalauncher/system/gesture/RecentsTransition.kt:424` | Hidden Transaction.setCornerRadius, reflected. | None for an app. |
| `targets/android/app/engine/src/main/java/andro/marchy/SessionService.java:216` | The [powos] pacman repo is unsigned, served over plain HTTP from android.pow; SigLevel TrustAll (C12). | Sign packages in build-pkgs.sh with a PowOS key and ship its public key in the rootfs keyring. |
| `targets/android/app/hidden-stubs/build.gradle.kts:5` | Hand-written stubs of the platform's hidden API, matched to the device's signatures. | None for an app; only a platform build sees them. |
| `targets/android/build-app.sh:19` | android-app-dev's `make build` exits 0 when Gradle fails; the APK's mtime is checked instead. | Propagate the builder's exit status in android-app-dev's Makefile. |
| `targets/android/build-oplus-hook.sh:15` | Same `make build` exit-status bug as build-app.sh. | Same as build-app.sh. |
| `targets/android/build-pkgs.sh:57` | pacman 7's Landlock download sandbox is not permitted in Docker: DisableSandbox. | A container runtime that allows Landlock. |
| `targets/android/build-rootfs.sh:11` | The rootfs is named lotfix-rootfs.tar.gz because Andromarchy's app looks for that file. | Our own app's download name. |
| `targets/android/install-powos-android.sh:57` | kwin is held with IgnorePkg; Plasma updates need a matching rebuild. | The Anland backend upstream in KWin. |
| `targets/android/install-powos-android.sh:105` | bun is fetched by curl (outside any package) for aarch64; the manifest can't carry it. | The manifest lists unpackaged binaries too. |
| `targets/android/install-powos-android.sh:134` | Installs the session launcher as /usr/bin/Hyprland (see session/Hyprland). | See session/Hyprland #1. |
| `targets/android/install-powos-android.sh:163` | Installs Omarchy command names the engine calls (shims). | Neutral command names in the engine. |
| `targets/android/pkgs/breeze/PKGBUILD:3` | Same pkgname as Arch's (pkgrel 1.1) so it replaces the distro package. | Upstream the patch, drop the package. |
| `targets/android/pkgs/kwin/PKGBUILD:15` | Same pkgname as Arch's kwin (pkgrel 3.1) so Plasma's depends=(kwin) resolve to ours. | The Anland backend upstream in KWin. |
| `targets/android/pkgs/kwin/PKGBUILD:77` | `setcap ... \|\| true`: the build container's filesystem may lack xattrs. | Build where xattrs work (irrelevant on Android). |
| `targets/android/pkgs/plasma-desktop/PKGBUILD:3` | Same pkgname as Arch's (pkgrel 1.1) to carry a kicker fix. | Upstream the patch (KDE bug), drop the package. |
| `targets/android/pkgs/steam/steam:63` | -cef-disable-gpu-sandbox: Chromium's GPU sandbox only opens /dev/dri, the Adreno is KGSL. | A GPU sandbox policy that allows /dev/kgsl-3d0 (upstream). |
| `targets/android/pkgs/steamos-manager-powerstation/PKGBUILD:20` | gamescope-session-ogui-steam comes from the image bundle, invisible to pacman. | The content step registers bundled RPMs as file-less pacman packages. |
| `targets/android/pkgs/xwayland-kgsl/0007-xwayland-kgsl-window-buffers-come-back.patch:72` | Xwayland on KGSL commits past a frame callback that never came (lfdevs's recovery); capped at 4 window buffers held by the compositor so a window KWin doesn't paint can't pin more dma-bufs. | KWin's Anland backend sends a frame callback for every frame it paints on the KGSL surfaceless path; drop the recovery and its cap. |
| `targets/android/recipes/mangohud.sh:1` | Arch's mangohud recipe needs libxnvctrl, which has no aarch64 build. | Arch Linux ARM packaging mangohud. |
| `targets/android/rooted/powos-start.sh:142` | Boot-time `powos units enforce` waits a fixed 20 s for the supervisor and the app-data watcher, then puts them in their units' cgroups in one pass. | Each places itself in its unit's cgroup as it starts (as powos-runtime does for services); the pass goes. |
| `targets/android/rooted/powos-rooted-session:41` | FD_MESA_DEBUG=noubwc: UBWC on KGSL corrupts Plasma's SVG textures. | Find and report the UBWC bug in Mesa's KGSL path. |
| `targets/android/rootfs-in-container.sh:15` | Same pacman Landlock-sandbox workaround as the build container. | Same as build-pkgs.sh. |
| `targets/android/session/Hyprland:4` | The session launcher is named Hyprland because Andromarchy's app hardcodes it. | The app reads the session command from the rootfs (our own app). |
| `targets/android/session/Hyprland:33` | FD_MESA_DEBUG=noubwc (as powos-rooted-session), for the no-root app. | Same Mesa fix. |
| `targets/android/session/Hyprland:37` | Touches desktop-ready itself: the app ends its splash only on seeing Omarchy's quickshell. | The app waits for $XDG_RUNTIME_DIR/desktop-ready alone. |
| `targets/android/session/first-boot.sh:5` | Lives at Andromarchy's /opt/lotfix/first-boot.sh path, which their app calls. | Our own app calls /opt/powos/first-boot.sh. |
| `targets/android/session/powos-android-app:61` | Fixed-size scrcpy display: --flex-display showed an over-zoomed, half-black app. | Find the cause (scrcpy or our Wayland scaling), then use --flex-display. |
| `targets/android/session/powos-android-tasks:11` | One small process per stand-in, because Qt sets the Wayland app_id per process. | A native helper setting app_id per toplevel. |
| `targets/android/shims/omarchy-lock-screen:4` | Omarchy command name kept for Andromarchy's logind stand-in; it does nothing (KDE's locker needs a password). | A lock that hands off to Android's keyguard via the two-way bridge. |
| `targets/android/shims/omarchy-toggle-idle:4` | Omarchy command name kept because Andromarchy's engine calls it. | The engine calls a neutral name. |
| `targets/android/steam/fex-compat-tool/build.sh:13` | Same pacman Landlock-sandbox workaround in Docker. | Same as build-pkgs.sh. |
| `targets/android/steam/fex-compat-tool/install.sh:5` | Overwrites files Steam manages in its FEX-Emu tool; a Steam update reverts them. | The probe upstream in FEX and Valve's tool; delete this directory. |
| `targets/android/vadb/compose.yaml:32` | powos-vadb borrows the wireguard container's netns: the Mac is not a WireGuard peer (C7). | REMOTE-POWOS.md M2/M8: no adb at run time; the hub is a VPN peer of its own. |
| `targets/native/dts/sm8550-oneplus-xueying.dts:44` | The Fold5's RPMh regulator table, verbatim, in the Open's DT. | The Open's own table from its downstream DT, before anything beyond USB. |
| `targets/native/make-bootimg.sh:5` | boot.img base/offsets are the common Qualcomm values, unchecked. | Compare against the stock boot.img header (phone.sh dump) and set them. |
| `targets/web/build-qemu.sh:13` | zlib 1.3.1 moved to /fossils/; qemu-wasm's Dockerfile URL is rewritten. | Upstream the fossils URL to qemu-wasm. |
| `targets/web/linux-wasm/build-deps.sh:33` | Sysroot-only search mode re-roots absolute hints; a symlink maps the prefix back. | Install the prefix inside the sysroot. |
| `targets/web/linux-wasm/build-kde.sh:52` | Same sysroot re-rooting symlink as build-deps.sh. | Same as build-deps.sh. |
| `targets/web/linux-wasm/build-kde.sh:64` | No translations: compiling catalogs needs Qt Linguist's lrelease, not built. | Build qttools' linguist tools in build-qt.sh. |
| `targets/web/linux-wasm/patch-qtbase.py:19` | musl's sigaction() can lock a mutex for SIGABRT in the vfork child; skipped. | A vfork-safe sigaction in our musl, or Qt resetting SIGABRT by raw syscall. |
| `targets/web/linux-wasm/support/powos-wasm-support.c:20` | C++ exception entry points stubbed as fatal (libc++abi built without exceptions). | Wasm exception handling (-fwasm-exceptions) in libc++abi and the runtime. |
| `targets/web/rootfs-in-container.sh:9` | Same pacman Landlock-sandbox workaround in Docker. | Same as build-pkgs.sh. |
| `units/gpu-195/powos-units-shim.json:8` | The unit for that shim (its purpose names the hack). | Same; then `powos units unregister powos-units-shim`. |
<!-- hack-registry:end -->

---

## 5. Open questions

1. SpacetimeDB 2.12's issuer handling (§2.3): local JWKS through its OIDC path, or a patch.
2. Android allows one VPN at a time: the phone's WireGuard (today the WireGuard app) must stay the PowOS peer, or
   PowOS brings its own `VpnService`. Which one owns the tunnel?
3. Whether the Mac becomes a WireGuard peer itself (then `powos-agentsd` talks to the hub directly) or stays behind
   the hub's Docker network as in §2.4.
4. Whether `claude-auth.pow` should require a `host:` token (C10). That is a change to `claude-rate-limiter`, outside
   this tree, and needs the user's OK.

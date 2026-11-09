# App API

The App API turns any app on the device into one local, typed capability surface: read what the app
knows and act through the app, as PowOS widgets, the `powos app` CLI, AI tools and SDK calls. It runs
entirely on-device: the runtime `tools/app-api/appcap_serve.py` listens on `127.0.0.1:3411` (loopback,
uid-locked), holds the per-app specs, the encrypted token store and the audit log. Design background:
`docs/APP-API-CAPTURE.md`. This file is the **provider contract** every app integration must obey.

## The contract (what is and isn't allowed)

The whole point is to work *as the official app*, never as a second client of the service.

**ALLOWED — through the official app's own process:**
- Keep the official app running in the background; trigger its own sync.
- Call the app's **internal methods** via an App API in-app hook (Frida into the app's own code).
- Read the app's own **state** on the device: its local DB/cache, its live UI, the notification stream
  it already posts.
- Send through the app's **own code path** (the method the app itself calls to send) or the app's own
  **RemoteInput reply action / deep link / intent**.
- The traffic that leaves the device is then the real app's own traffic. Reads and sync may be
  automated, **at the app's normal cadence** — no aggressive polling, no bursts, no scraping loops.

**NOT ALLOWED — our own separate client:**
- No PowOS process hitting Discord / WhatsApp / Gmail / any service's servers with the user's captured
  session or token.
- No replaying captured requests, no crafted/forged requests, no second client of the service.
- Capturing an app's traffic (CA + in-app hook) is only to **learn the app's own code path**; the
  captured token is never replayed through a PowOS HTTP client.

**Sending:** every outgoing message/action is one **explicit user action** (a tap). Reads/sync may be
automatic; sends are never automatic.

Official first-party or LAN APIs with the user's own key (Philips Hue, Open-Meteo) are the app's own
normal use and are unaffected by the above — that is the device's own API key on the device's own LAN.

## 5-line state (as of 2026-10-31, from code + a live read-only check)

1. **Runtime is UP:** `appcap_serve.py` on `127.0.0.1:3411`, 6 specs enabled — hue (official LAN API),
   open-meteo (public), chatgpt/gemini/gmail (drafted: only `open <deep-link>` actions, `auth: null`),
   ir-remote (off). Reachable by apps via `GET/POST /call?app=&action=` with a consumer tag.
2. **What it can read/act per app today:** YouTube/Discord/WhatsApp/X/Steam — **nothing app-specific
   yet**; no spec exists for them. What it *can* read for any app today, ban-safely, is that app's
   **notifications** (PowOS notification listener, granted) — title/text/actions incl. reply actions.
   Gmail today: `open` deep-links only (compose, labels), no reads. No message is sent for any of them.
3. **The two "missing" pieces are the capture path, not the runtime:** `app-frida` (on-demand in-app
   hook) and `app-ca` (local CA for HTTPS capture). Both are `NOT YET INSTALLED` by their own manifests
   and were never installed (the `rooted.sh app-ca`/`app-frida` subcommands they name don't exist). The
   runtime never depended on them.
4. **How a PowOS app/widget consumes it:** `host.net.fetch(app, "http://127.0.0.1:3411/call?app=<a>&action=<x>", {method,body})`
   with `consumer: "widget"|"app"` (the only host the App API app declares in `net`). The CLI mirrors it:
   `powos app` for authoring; action calls go through the runtime. Example (live):
   `host.net.fetch("hue","http://127.0.0.1:3411/call?app=hue&action=list_rooms",{method:"POST",body:{consumer:"widget"}})`.
5. **Safety gates in the runtime:** `read` may send; `reversible-write` needs `--send`; `spend` is
   refused from the app surface and confirmed in chat; default is **dry-run**; every call appends one
   audit line with secret-pattern args redacted (`appcap_run.py`).

## Per-provider: read path, reply path, detection risk

| Provider | Read (ban-safe, on-device, passive) | Reply (user tap only) | Detection risk |
|---|---|---|---|
| **Discord** | Its notification stream (mentions/DMs post `MessagingStyle` notifications with the sender, text, conversation flag); optionally its local cache/DB read in-process via an App API hook. **Never** a Discord API call with the user's token. | The notification's own **RemoteInput reply action** (`Notifications.action(key,index,text)`), or deep link to the channel. Each reply = the app's own request, fired once by a tap. | Low on the notification/RemoteInput path (it is the OS's own inline-reply, indistinguishable from the shade). **Self-bot = ban:** any token-bearing HTTP of ours to Discord is NOT ALLOWED. |
| **WhatsApp** | Its notification stream (unread messages post reply-capable notifications); in-process read of its state via a hook if needed. No WhatsApp client of ours. | Notification **RemoteInput** reply action, or `whatsapp://`/intent to the chat. Tap-triggered only. | Low on RemoteInput (WhatsApp ships the reply action itself). A separate client with the user's creds is a ban; NOT ALLOWED. |
| **Gmail** | Primary-unread via its notification stream, or Google's **official OAuth Gmail API** (that *is* a sanctioned first-party client, user-consented) — not a scraped/captured session. | Notification reply/archive actions, `mailto:`/compose deep link (present in the live spec), or the official API with the user's OAuth grant. | Low: OAuth Gmail API or notifications are both first-party. Captured-cookie Gmail scraping is NOT ALLOWED. |

Anything that would read or send by replaying a captured consumer-app token through a PowOS client is
**API emulation** and is not allowed for any provider.

## Existing code reviewed against this contract

No **live** violation: every enabled spec is a deep-link `open` (chatgpt/gemini/gmail/ir-remote), an
official LAN API with the user's own key (hue), or a public API (open-meteo). Nothing sends a
consumer-service token from a PowOS client today.

Mechanisms that **must stay fenced** (capability exists; would violate the contract if pointed at a
consumer service with a captured token):
- `tools/app-api/appcap_run.py:123-131` — the runtime's own `http.client.HTTPSConnection` send path with
  auth injected by handle. Legitimate for official/LAN keys (Hue). **Must never** carry a captured
  Discord/WhatsApp/Gmail session token; specs for those must use the notification/RemoteInput/official-OAuth
  path, not a bearer-token endpoint.
- `tools/app-api/appcap_proxy.py` + `powstation-frida/modules/universal-ssl.js` /
  `network-analyzer.js (generateApiDocs)` — TLS capture + in-app hooks. Allowed only to **learn the app's
  own code path / drive the app's own send method**; the captured token must not be replayed through a
  PowOS HTTP client. The replay-via-our-client path is the forbidden one.

## Keeping it from going missing again (AA1 health + AA4 survivability)

**Cause of the regression (2026-10-31):** the runtime itself survived (it lives persistently in the
PowOS chroot at `/usr/lib/powos/app-api`, deployed 2026-10-30). What vanished was (a) the
`/data/local/tmp/powos-app-api` **staging** copy, cleared by a reboot (that path is volatile on Android),
and (b) the two capture units, which were **never installed** — their `installedBy` names `rooted.sh`
subcommands that do not exist. The unit list reads them as MISSING because their declared files are
absent, which was accurate.

- **AA1 (built):** `tools/app-api/health-check.sh` + unit `units/phone/app-api-health.json`. Read-only;
  reports runtime / read-path / capture-units as green / warn, exits non-zero only when the runtime
  service is down. Wire it to fire a PowOS notification + a board task on a down runtime, and schedule it
  at session start + every 10 min (next-agent step; the hook points are `powos-start.sh` and the agents
  board).
- **AA4 (built 2026-11-10):** runtime survivability is already correct (chroot-persistent + the health
  check restarts the service). The two capture units now have real install targets so they stop reading
  MISSING — see "The capture path, on-device" below. The health unit survives APK/module updates because
  it lives in the chroot, not `/data/local/tmp`. After any LSPosed/Zygisk change, re-run the health check
  to confirm notification access and the hook path.

## The capture path, on-device (AA4 — `app-ca` + `app-frida`, owner's device only)

Both are the owner's deliberate, reversible acts on the owner's own phone and apps; neither runs from the
Mac and neither is a silent side effect. They exist only to let the **on-device** capture proxy learn an
app's own API (for widgets and tracker-blocking) from apps the owner **explicitly enabled** in the App
API. Install + a one-time uninstall test are the on-device agent's step, with the user present.

**Local certificate — `targets/android/rooted/app-ca.sh` (unit `app-ca`), via `rooted.sh app-ca`:**
- `rooted.sh app-ca gen` — generate the device-local CA **on the device** (openssl inside the PowOS
  chroot). The **private key** lands at `/data/powos/app-api/ca.key` (0600) and **never** leaves the
  device: it is never printed, never logged, never pushed to the Mac, never committed, and never placed in
  the Magisk module. Only the public cert (`ca.crt`) and its SHA-256 fingerprint are ever shown.
- `rooted.sh app-ca install` — the explicit, separate step that changes what the device trusts: it builds
  a Magisk module (`/data/adb/modules/powos-appca`) that, at boot, overlays the system cacerts dir with
  the real system trust **plus** our one public cert, then prints that a **reboot** is required. Android
  7+ apps ignore user-store CAs, which is why system trust needs root + a module. SELinux is untouched.
- `rooted.sh app-ca remove [--wipe-key]` — drop the module (+ reboot) to revert the trust store fully;
  `--wipe-key` also deletes the local CA key/cert.
- Trusting the CA does **not** by itself route or capture anything — capture is per-app (below).

**In-app hook helper — `targets/android/rooted/app-frida.sh` (unit `app-frida`), via `rooted.sh app-frida`:**
- For an enabled app that pins TLS or signs its requests, the proxy alone can't read the traffic; an
  in-app hook reads the request the way the app itself builds it, so we reuse the app's own auth/headers
  and never re-implement auth or run a second client (the provider contract above).
- `rooted.sh app-frida install [BIN]` stages the matching-arch hook-server binary (0700, root-only),
  **default STOPPED**. `start PKG` runs it only inside an explicit capture window and **refuses any package
  the owner has not enabled in the App API** — the allowlist is exactly the apps the owner picked in the
  UI; it records the one target package (`capture-target`) so the capture layer attaches to that package
  only. `stop` ends the window; `remove` stops it and deletes the binary. No other app is ever hooked.

**Capture on a non-rooted device (non-root parity):** both of the above need root (system-trust CA; a root
hook). On a non-rooted phone the App API falls back to sources that need **neither** a CA nor a hook:
- the **notification-stream** read path (PowOS notification listener) — the ban-safe `needs-me` source for
  Discord/WhatsApp/Gmail, with reply via each app's own RemoteInput action; no capture at all;
- an app's exported deep links / official first-party or LAN APIs with the owner's own key (Hue,
  Open-Meteo, Gmail OAuth) — the app's own normal use, root-free.
So learning an arbitrary app's private HTTPS API is root-only; the read/act capabilities that most apps
need (notifications + deep links + official APIs) have a full non-root path and are the default.

## Streamlined consumer path (AA2 design — existing pieces + gaps)

**Exists today:**
- The runtime `/call` endpoint and consumer tags (`tools/app-api/appcap_serve.py:234`,
  `CONSUMERS = app|cli|sdk|widget|ai`).
- The one network route an app is allowed: `host.net.fetch(app, API+"/call?...", ...)` with the app's
  `net` declaring `127.0.0.1` (`shell/apps/net.ts`, `lib/apps/templates/composed/ui/lib/compose.ts:81`).
- Per-app specs with typed actions, `view` bindings for widgets, and the safety classes.
- The ban-safe read + reply primitives in native code:
  `widgets/runtime/Notifications.kt` (`items()`, `value()`, `action(key,index,text)`).
- `powos app` CLI (`lib/apps/powos-app`) for authoring apps/widgets.

**Gaps (next-agent build):**
- `host.appApi` typed client in `shell/apps/` + `ui/lib/app.ts`: `query(app,"discord.mentions")`,
  `subscribe(app,sel,cb)`, `act(app,"discord.reply",{...})` — thin wrappers over `/call` and over the
  notification listener, hiding the hook/notification/HTTP details per provider.
- Per-app **providers** (Discord, WhatsApp, Gmail) that resolve a capability name to the ban-safe source:
  notification stream / in-app hook / official OAuth — never a token-bearing consumer-service call.
- A `needs-me` capability that unions Discord mentions+DMs, WhatsApp unread, Gmail Primary unread from the
  notification stream (and OAuth for Gmail), with `reply` mapped to each app's RemoteInput action.
- Permissions in `powos-app.json` (`"appApi": ["discord.read","discord.reply", ...]`), granted once by the
  user; enforced in the runtime's consumer check.
- `powos app help` + this doc as the authoring reference, with `needs-me` as the worked example (AA3).
- History: none of the three has an App API data source with message history yet, so What needs me v2
  (`apps/needs-me/ui/lib/history.ts`) keeps its own per-conversation history of the notifications it was shown
  (the app's localStorage, last 6 messages per conversation, 40 conversations, 7 days; the user's own replies
  marked). A provider added here should merge into it by the same conversation id (`model.ts` `groupKey`).

**File list / step plan for AA2 (next agent):**
1. `shell/apps/app-api.ts` (new) + `ui/lib/app.ts`: typed `host.appApi.query/subscribe/act` over `/call`
   and over the notification bridge.
2. `tools/app-api/providers/` (new): `discord.py`, `whatsapp.py`, `gmail.py` — map capability names to the
   ban-safe source; no token-replay path.
3. `widgets/runtime/Notifications.kt`: expose a filtered `needs-me` selector + a reply bridge op (reuse
   `action()`), so the SDK's `act(...reply...)` lands on the real RemoteInput.
4. `apps/app-api/powos-app.json` + runtime consumer check: `appApi` permission declaration + grant.
5. `docs/APP-API.md` (this file): keep the contract and the `needs-me` worked example current.

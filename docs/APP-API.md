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
- **AA4 (design):** runtime survivability is already correct (chroot-persistent + the health check
  restarts the service). What still needs doing: (1) make `app-frida`/`app-ca` real install targets
  (`rooted.sh app-ca`/`app-frida`) so they stop reading MISSING, with frida kept STOPPED by default and
  the CA install gated on the user's OK (it needs a Magisk module + reboot); (2) the health unit survives
  APK/module updates because it lives in the chroot, not `/data/local/tmp`; (3) after the LSPosed/Zygisk
  change, re-run the health check to confirm notification access and the hook path.

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

**File list / step plan for AA2 (next agent):**
1. `shell/apps/app-api.ts` (new) + `ui/lib/app.ts`: typed `host.appApi.query/subscribe/act` over `/call`
   and over the notification bridge.
2. `tools/app-api/providers/` (new): `discord.py`, `whatsapp.py`, `gmail.py` — map capability names to the
   ban-safe source; no token-replay path.
3. `widgets/runtime/Notifications.kt`: expose a filtered `needs-me` selector + a reply bridge op (reuse
   `action()`), so the SDK's `act(...reply...)` lands on the real RemoteInput.
4. `apps/app-api/powos-app.json` + runtime consumer check: `appApi` permission declaration + grant.
5. `docs/APP-API.md` (this file): keep the contract and the `needs-me` worked example current.

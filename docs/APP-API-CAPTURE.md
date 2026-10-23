# App → API capture pipeline

**Status:** design + working prototype of the capture→spec step (2026-10-23).
**Scope:** turn an app the user *explicitly enables*, on the user's *own phone*
and *own accounts*, into a typed API that PowOS AI can call directly — so the AI
can do the reversible part of a task (search a catalog, build a basket) while the
user keeps the irreversible part (checkout, payment, sending messages).

This is the same move as the Lights app (`~/Projects/lights`): there we learned
the Philips Hue **CLIP v2** API, kept the bridge key as an app secret
(`${secret:hue}`, injected by the host, never seen by app code), and called the
device's own LAN API directly instead of driving a UI. The difference: Hue
publishes its API and hands you a key by a button press. Consumer apps do not —
so we have to **observe** the app's own traffic to learn its API, and the app
actively resists observation (TLS pinning, request signing, bot detection). The
rest of this doc is about doing that observation safely and turning what we see
into tools.

---

## 0. Hard safety rules (these constrain the whole design)

1. **Never place an order, pay, or send a message/transaction.** The AI may only
   call operations the spec marks reversible (reads + cart edits). Anything that
   spends money or sends a message is gated behind an explicit per-action yes in
   chat that shows exactly what will happen (items + total).
2. **Never enter credentials.** We capture only sessions the user creates by
   logging in themselves, in the real app.
3. **Never print or commit a token value.** Captures and the token store are
   secrets; they stay local and encrypted at rest.
4. **Every installed dep is a registered PowOS unit** (`units/…`), with owner,
   purpose and a documented removal — no silent system-wide installs (per the
   no-unmanaged-deps rule).
5. **Phone changes (CA, Frida) are reversible and documented here**; SELinux is
   never weakened; no touch injection while the user is active.
6. **Nothing is published externally.**

---

## 1. What already exists in ~/Projects (reuse, don't rebuild)

The capture→spec→emulate chain is ~80% already built on this fleet. The pipeline
below is mostly *integration + a thin OpenAPI/tool-gen layer*, not new infra.

| Project | What it already does | Role in this pipeline |
|---|---|---|
| **`ssl-bypass-foundation/`** (Rust) | Transparent MITM proxy: on-the-fly cert gen from a local CA (`cert_manager.rs`), iptables redirect over a dedicated WireGuard subnet (`traffic_router.rs`, analysis subnet `10.13.14.0/24`, a normal non-intercepting subnet `10.13.13.0/24`), full request/response + **WebSocket** capture to SQLite (`request_capture.rs`, `websocket_handler.rs`, `request_store.rs`), a **schema learner** that infers JSON types from responses (`schema_learner.rs`), a **service profiler** that groups traffic into route patterns with `:id` normalization (`service_profiler.rs`), an **API-key detector** (`api_key_detector.rs`), a **credential store** (`credential_store.rs`), a rewrite engine, an analytics REST+SSE API, and even a service **emulator** (`emulator.rs`). | **The capture + learning engine.** This is the backbone. |
| **`powstation-frida/`** (Frida/JS) | `modules/universal-ssl.js` — universal TLS-pinning bypass (TrustManager, HostnameVerifier, OkHttp CertificatePinner, Conscrypt, etc.). `modules/network-analyzer.js` — hooks OkHttp3/Retrofit/Volley/HttpURLConnection/WebSocket in-process, extracts auth tokens, and already has a `generateApiDocs()` that emits an OpenAPI-like structure. Deploy scripts for frida-server, a gateway, stealth/anti-detection. Docs: `docs/SETUP.md`. | **The pinning-bypass + in-app hook** for apps the network proxy alone can't read. |
| **`debug-proxy/`** (TS, zero-dep) | Simple HTTP/TCP/system proxy with JSON-per-request logging, **replay** and **mock** modes, header/path rewriting (`project.md`). | **Dev-time replay/mock** of a learned API without hitting the real service; quick ad-hoc captures on the Mac. |
| **`lights/`** | The pattern for *consuming* a learned API from a PowOS app: `host.net` capability, pinned cert, secret injected as `${secret:hue}`, never seen by app code (`ui/lib/hue.ts`). | **The consumption model** the generated tools follow. |
| **`EasyReverse/`** | Binary/firmware decompiler. Its `reference/recomp/rea/bridge/mitmproxy/capture.py` is a third-party mitmproxy capture addon (reference only). | Not on the path (binaries, not HTTP), but confirms mitmproxy is the house capture format. |

**Gaps to fill (this is the actual new work):**
- No formal **OpenAPI 3.1 exporter** — `schema_learner` + `service_profiler`
  have the pieces, and the Frida `generateApiDocs()` is "OpenAPI-like", but
  neither emits a spec a client generator can consume. **The prototype in
  `tools/app-api/har2openapi.py` fills this** (and works off the universal HAR
  format, so it sits on top of any capturer).
- No **tool/MCP generation** from the spec.
- The `credential_store` writes `header_value` as **plaintext** in SQLite (only
  the *API output* is redacted to a 12-char prefix). That violates safety rule 3.
  **Must be changed to encrypted-at-rest** before any real account is captured
  (see §5).
- No **"enable an app" UX** tying it together.

---

## 1b. THE CORE: one capability spec, every consumer generated from it

This is the heart of the design and the thing the user asked for: *"a clean spec
so we can easily use apps via API or CLI or for widgets or whatever without
compromising safety."*

Each enabled app — Uber Eats, Hue, a weather app — is described **once** in a
single app-independent file, the **App Capability Spec** (`*.appcap.json`). Every
way of using the app is **generated** from that one file, so they can never
disagree about what an action does or how dangerous it is:

```
                         <app>.appcap.json   (ONE source of truth)
                                  │
      ┌───────────────┬───────────┼────────────────┬──────────────────┐
      ▼               ▼           ▼                ▼                  ▼
  AI tools        CLI          typed SDK        widget bindings     audit log
  (MCP /          powos app    (TS/Rust/py      (read actions +     (every call,
   PowOS AI)      <app> <act>   for code)        refresh hints)      every app)
      └───────────────┴───────────┴────────────────┴──────────────────┘
                 all four enforce the SAME safety class, identically
```

The spec's JSON Schema is committed at
[`tools/app-api/schema/appcap.schema.json`](../tools/app-api/schema/appcap.schema.json);
a full worked example (Hue, whose API we already know) at
[`tools/app-api/examples/hue.appcap.json`](../tools/app-api/examples/hue.appcap.json);
and a validator that enforces the safety invariants at
[`tools/app-api/appcap_validate.py`](../tools/app-api/appcap_validate.py). All
three are real and tested (see §7).

### 1b.0 Everything runs locally on PowOS (no Mac, no cloud at runtime)

The whole pipeline runs **on PowOS itself** — the phone's own Linux side and
desktop PowOS — **offline / LAN-only**. The Mac is development + builds only.

- On the phone/desktop: the capture proxy (mitmproxy-equivalent inside PowOS,
  the Android app's traffic routed to it locally), the **encrypted token store**
  (`appcap_store.py`, §5 — no cloud ever holds a token), the **runtime + call
  path** (`appcap_run.py`), the `powos app` CLI, the phone's PowOS AI/MCP tools,
  the widget bindings and the App API app.
- Packaging: ships as PowOS rootfs packages/units (`targets/android/build-pkgs.sh`
  + a registered unit, `units/phone-android/app-api.json`) that also work on
  desktop PowOS. Dependencies are stdlib Python + `openssl` (already present); no
  unmanaged system installs.
- The store lives under `~/.local/state/powos/app-api/` (0600); on the phone the
  keyfile is wrapped by Android Keystore. Nothing leaves the LAN.

The earlier prototype pieces that assumed a Mac proxy are superseded: the token
store is the local `appcap_store.py` (not the Mac `ssl-bypass-foundation` SQLite
column, which was plaintext); capture + runtime + tools all execute on-device.
The Mac-side converter/validator/renderer are the same Python files, which run
unchanged on PowOS.

### 1b.1 What an action declares

Each action in the spec carries exactly what every consumer needs:

| Field | Meaning |
|---|---|
| `summary` | one-line human description (becomes the tool/CLI help) |
| `inputs` / `output` | **typed** JSON Schema — drives the SDK types, CLI arg parsing, tool parameters and the widget's data shape |
| `endpoint` | the mapping: HTTP `method`+`path` (or `operationId` into the captured OpenAPI spec, or an `argv` template when `base.kind=cli`), plus `origin: official \| captured` |
| `endpoint.auth` | a **token handle** (`"bridge"` → `auth.tokens.bridge`), resolved to a value by the host at call time — the value is never in the spec |
| `safety` | **the safety class every consumer enforces** (below) |
| `rate_limit` / `cache_ttl_s` | per-action limits (fall back to `defaults`) |
| `refresh` | for reads: `poll_s` and/or an `event_stream` endpoint — the widget's refresh hint |
| `undo` | for reversible writes: the action id that reverts it (or `"inverse"` = call again with the prior state) |
| `confirm` / `confirm_template` | per-call confirmation + the exact "what and how much" string shown |

### 1b.2 The safety class (the whole safety model in one field)

Every consumer reads `safety` and behaves the same way. It is not advisory — the
generators and the runtime both key off it:

| `safety` | Examples | AI tool | CLI | Widget | Runtime rule |
|---|---|---|---|---|---|
| **`read`** | list rooms, read cart, weather | free | free | **allowed** | cacheable (`cache_ttl_s`); no side effects |
| **`reversible-write`** | add to cart, toggle a light, set brightness | allowed, **logged**, offers `undo` | allowed, `--undo` | **never** | changes state but is reversible and spends nothing |
| **`spend`** | order, pay, send a message, delete, book | **blocked unless** an explicit per-call user **yes** showing `confirm_template` (what + total) | refuses without `--confirm` + prints the template | **never — a widget can never call it** | irreversible / costs money / contacts others; never automatic |

Two invariants make this safe *by construction*, enforced by `appcap_validate.py`
(so a bad spec fails before any consumer is generated):

- **A widget can only ever bind to `read` actions** (S5). Widgets run
  unattended, so they are physically unable to spend or even to make a
  reversible change.
- **`spend` forces `confirm: true` and forbids `widget: true`** (S4), and the
  confirmation must carry a `confirm_template` (S6) so the user always sees
  *what* and *how much* before approving.

### 1b.3 Capture-generated actions start read-only

An action learned by capture (`origin: "captured"`) is **born `read`-only**. To
become `reversible-write` or `spend` it must be explicitly **promoted** by the
user (`promoted: true`); the validator rejects a captured non-read action that
isn't promoted (S3). So the pipeline from §4 can freely turn observed traffic
into `read` actions the AI and widgets can use immediately, while anything that
changes state waits for a deliberate human promotion. Official APIs we already
trust (like Hue) can ship writes directly.

### 1b.4 Tokens: handles only, never values

`auth.tokens.<id>.store` is a **handle** — `secret:hue`, `store:ubereats:session`
— into the encrypted local store (§5). The validator rejects anything that isn't
a `secret:`/`store:` handle (S2), so a real token can never be committed into a
spec by accident. The host resolves the handle and injects the value into the
outbound request at call time, exactly like the Lights app's `${secret:hue}`;
tool code, CLI output, widgets, logs and git never see it.

**We never implement or touch auth ourselves — we reuse the app's own.** For a
`captured` action, the token store holds the *exact* auth material the app itself
sends (its `Authorization`/cookie/`x-api-key`, and any signed `x-*` headers the
capture saw), and at call time the host replays those same headers verbatim. We
do not log in, mint tokens, re-implement a login flow, or reverse-engineer a
signing scheme by hand: whatever the app presents to its server, we present the
same, pulled from the store by handle. (This is also why request-signing /
attestation apps like Uber may need the on-device path — see §3 — since a
signature that must be freshly minted per request can't be replayed from a stored
header; there the app's own networking mints it and we ride along.) The user logs
in once in the real app; everything after is handle-injected, never handled by us
in the clear.

### 1b.5 Enable / disable, allowlist, audit

- **Enable an app:** `powos app <app> enable` flips the spec's top-level
  `enabled` and walks the §4 capture/import flow. **Per-action allowlist:** every
  action has its own `enabled` flag; the enable step turns them on one at a time
  (`powos app <app> allow <action>` / `deny <action>`). A disabled app or action
  is uncallable from *every* consumer — generators skip it, the runtime refuses
  it.
- **Disable:** `powos app <app> disable` makes the whole app uncallable at once
  (kill switch); the spec and tokens stay so re-enabling is instant.
- **Audit log:** every call through any consumer appends one JSON line to
  `~/.local/state/powos/app-api/audit/<app>.jsonl` — timestamp, consumer
  (ai/cli/sdk/widget), action, safety class, dry-run flag, whether a confirmation
  was shown and its answer, result status and duration. **Inputs are recorded
  with secret-pattern fields redacted; token values are never logged.** This is
  the one place to see everything the AI (or anything) did on your behalf.

### 1b.6 Dry-run everywhere

Every consumer supports **dry-run**: it resolves the action, builds the exact
request (method, URL, headers with the token shown only as `bridge→secret:hue`,
body) and **shows it without sending**. `powos app hue set_room --room … --dry-run`,
an AI tool argument `dry_run: true`, and an SDK `{dryRun:true}` all produce the
same preview. Dry-run is the default the first time the AI touches a new
`reversible-write` or `spend` action, so you always get to look before it fires.

### 1b.7 The JSON Schema (committed; excerpt)

Full file: `tools/app-api/schema/appcap.schema.json`. Shape:

```jsonc
{
  "spec": "powos.appcap/v1",
  "app": "hue",                       // CLI namespace + stable id
  "name": "Philips Hue",
  "enabled": true,
  "base": { "kind": "lan", "url": "https://{bridge_ip}/clip/v2", "tls": "pinned" },
  "auth": { "tokens": {               // HANDLES ONLY — never a value
    "bridge": { "store": "secret:hue", "type": "api-key", "header": "hue-application-key" }
  } },
  "defaults": { "rate_limit": { "per_minute": 60 }, "cache_ttl_s": 2 },
  "actions": {
    "<action-id>": {
      "summary": "…",
      "safety": "read | reversible-write | spend",
      "origin": "official | captured",
      "promoted": false,              // captured non-read needs this true
      "widget": false,                // only true when safety=read
      "confirm": false,               // forced true when safety=spend
      "confirm_template": "Order {item_count} items for {currency}{total}?",
      "undo": "inverse",              // reversible-write: how to revert
      "refresh": { "poll_s": 10, "event_stream": "/eventstream/clip/v2" },
      "rate_limit": { "per_minute": 60 }, "cache_ttl_s": 5,
      "inputs":  { "type": "object", "properties": { … } },
      "output":  { "type": "object", "properties": { … } },
      "endpoint": { "method": "GET", "path": "/resource/room", "auth": "bridge" }
    }
  }
}
```

### 1b.8 Full example — Hue (committed, validated)

`tools/app-api/examples/hue.appcap.json` describes four actions:
`list_rooms` (read, widget-safe, 10s poll + CLIP v2 event stream),
`list_scenes` (read, widget-safe), `set_room` (reversible-write, `undo:inverse`)
and `recall_scene` (reversible-write). The bridge key is the handle
`secret:hue`. `appcap_validate.py --list examples/hue.appcap.json` prints:

```
# hue: 4 action(s)  (app enabled=True)
  list_rooms    read              official  on  widget
  list_scenes   read              official  on  widget
  recall_scene  reversible-write  official  on
  set_room      reversible-write  official  on
```

Hue has no `spend` action. The **Uber Eats "prepare a basket"** flow (§6) is the
same spec with the spend class exercised — the cart actions are
`reversible-write` (no confirm, widget-false) and the only `spend` action is
`place_order`, which the spec marks `confirm: true` with
`confirm_template: "Order {item_count} items from {restaurant} for {currency}{total}?"`
and `widget: false`. By S4/S5 a widget can never call it and no consumer fires it
without the user's per-order yes — and in practice we prefer to hand checkout to
the real app entirely (§6), so `place_order` can simply be left out of the
allowlist (`enabled: false`).

### 1b.9 How each consumer is generated from the spec

One generator per consumer, all reading the same `*.appcap.json`. They reuse the
existing projects (§1): captured `endpoint`s point at operations in the
`har2openapi.py` OpenAPI output, and the request itself is issued/learned through
`ssl-bypass-foundation`; `debug-proxy` replays them in tests.

- **AI tools (MCP / PowOS AI).** Each `enabled` action becomes one tool named
  `<app>__<action>`, its JSON-Schema `inputs` as the tool parameters, `summary`
  as the description, plus a `dry_run` parameter. The generator **bakes the
  safety class into the tool**: `read`/`reversible-write` tools run directly
  (reversible-writes auto-logged, `undo` surfaced); `spend` tools are emitted so
  the model *must* call `present_choices`/confirmation (the `powos-chat` skill's
  present cards) with the `confirm_template` filled in before the call executes —
  the runtime refuses an unconfirmed `spend`. Disabled actions emit no tool.
- **CLI.** `powos app <app> <action> [--arg value …] [--dry-run] [--undo]`,
  dispatching under one `powos app` facade (mirroring the `powos game` facade
  pattern). `--help` is generated from `summary` + `inputs` (so, per the PowOS
  `!cmd` rule, the agent reading `powos app <app> help` always sees the current
  actions). A `spend` action refuses to run without `--confirm` and first prints
  the `confirm_template` with the resolved total. `powos app list` /
  `powos app <app> actions` show the allowlist + safety classes.
- **Typed SDK (for code).** `inputs`/`output` schemas generate typed functions
  (`hue.setRoom({groupId, on})`) in TS/Rust/Python; the type system carries the
  safety class so a `spend` call won't compile without passing a confirmation
  token obtained from a user prompt.
- **Widget data bindings.** A widget may bind **only** to `read` actions (S5).
  The generator exposes each read action as a data source with its `output`
  shape and its `refresh` hint — poll every `poll_s`, or subscribe to
  `event_stream` for push (Hue's CLIP v2 event stream, so the Lights widget is
  live, not polled). A widget literally has no generated binding for any
  write/spend action, so it cannot change anything.

All four go through one call path — resolve action → check app+action enabled →
enforce safety (confirm/undo/widget rules) → attach the token by handle → rate
limit → (dry-run shows, else send) → **append the audit line**. The safety checks
live in that shared path, not in each consumer, so there is exactly one place
that can say no.

### 1b.10 In-app UI automation ("show me a certain page")

Not everything an app does is an API call. Sometimes the useful action is *open
this screen* — show me my cart, jump to this restaurant, open the Lights page. An
action models that with `endpoint.ui` instead of an HTTP mapping:

```jsonc
"endpoint": { "ui": {
  "deep_link": "ubereats://cart",        // preferred: open the screen directly
  "route": "app://local.lights",         // or a PowOS app surface
  "steps": [                             // fallback when no deep link exists
    { "do": "tap", "target": "Search" },
    { "do": "type", "target": "Search", "text": "{query}" }
  ]
}}
```

- **Opening a screen is a `read` action** (it displays, it changes nothing), so
  the AI and the CLI can do it freely and it is the natural end of the
  "prepare a basket" flow (§6): the AI builds the cart over the API, then calls a
  UI action to **open the real app on its cart screen** for the user to review
  and check out. A UI action that *submits* a form takes the safety class of
  what it submits (so a UI "place order" is still `spend`, still confirmed,
  still never a widget).
- **How it runs on the phone:** prefer the app's **deep link / intent** (one
  jump, no scripted taps); the Android side already has the adb-to-itself window
  (`units/phone-android/adb-self.json`) to surface the app. When no deep link
  exists, `steps` replay through the phone's accessibility/automation path (the
  `powos-phone` tooling), **never blind-tapping while the user is active** (the
  no-touch-injection rule). This is strictly navigation/automation of the user's
  own app on their own screen.

### 1b.11 Native Linux apps — the easy case

The same `*.appcap.json` model covers PowOS desktop's **native Linux apps**, and
they are *easier* than mobile, not harder:

- **Capture needs no root:** a user-trust CA plus an env/proxy var
  (`HTTPS_PROXY`) through `ssl-bypass-foundation` is enough — no Magisk, no
  system-partition CA, far less pinning in the wild.
- **Many apps already expose an API you map as `official`:** a **D-Bus**
  interface or a **CLI** (`base.kind: "cli"`, `endpoint.argv`) — map it directly,
  no capture at all. (This is exactly how the Hue skill wraps the `openhue` CLI.)
- **UI automation is first-class on Linux:** **AT-SPI** accessibility, D-Bus
  activation, `wmctrl`/`ydotool` — so `endpoint.ui.steps` are more reliable than
  on mobile.

So a single enabled "app" can be a phone app, a Linux app, a web service or a
LAN device — the spec, the safety model, the CLI (`powos app <app> <action>`),
the tools, the widgets and the audit log are identical. That uniformity is the
point of having one capability spec.

### 1b.12 The "App API" app: toggle it, view the resulting API

The control + view surface is itself a PowOS app ("App API"):

- **Toggle** an app on/off and flip individual actions in its allowlist (writing
  the `enabled` flags), kick off / re-run capture, and promote a captured action
  past `read` — the one place the user grants capability.
- **View the resulting API** for each enabled app: the rendered action list with
  safety badges, the endpoint mapping, the auth handle (never the value), the
  generated tool list and the widget-bindable reads — i.e. the output of
  `appcap_render.py` (§7), live.
- **Audit** tab: the per-app call log (§1b.5).

Built (step 5): the PowOS app `apps/app-api` (local.app-api). Its page talks only
to `tools/app-api/appcap_serve.py`, a loopback service on the device itself
(127.0.0.1:3411, the system tier's `lib/apps/services/app-api.json`, port locked to
the PowOS uid like SpacetimeDB's), through `host.net` - never the Mac. The service
adds no logic: views are `appcap_render.py`'s, calls are `appcap_run.py`'s
(consumer `app`), toggles write the spec's `enabled` flags in
`~/.local/state/powos/app-api/specs/` (seeded once from `examples/`). First slice:
only `read` actions can be sent; writes are dry-run only; `spend` is never sent
from the app ("confirm in chat"). Tabs: Apps (per app: actions by safety class with
typed inputs/outputs and allowlist switches, the API / AI tools / CLI / Widgets
views, dry run), Audit (newest first), Trackers (§1b.13).

Tracker data the app reads (proposed to the capture-proxy side; empty state until it
exists): `~/.local/state/powos/app-api/trackers/<app>.jsonl`, one line per flow
decision `{"ts", "app", "host", "tracker", "category", "list", "action":
"blocked"|"allowed", "count"?}` (never a query or header value), and the per-app
switch it writes, `trackers/policy.json` = `{"apps": {"<app>": {"allow": true}}}`
(an app not listed: trackers blocked).

### 1b.13 First-class feature: tracker identification + blocking

The same local proxy sees the host + URL of every flow, so it is also a
**request-level tracker blocker** — complementing PowOS's Pi-hole (DNS-level)
with per-flow, per-app decisions Pi-hole can't make. **Built and tested**
(`tools/app-api/appcap_block.py`):

- classifies every request as `tracker` / `analytics` / `functional` using
  known lists (EasyPrivacy-style host rules + Exodus-style tracker signatures,
  seeded in the file, refreshed on-device by a scheduled updater unit) plus what
  was learned per app;
- **trackers/analytics blocked by default; functional calls allowed**;
- **per-app ALLOW switch** force-allows a host when blocking breaks an app;
- a **per-app report** — which trackers, how many calls, how many bytes — for the
  App API app to display (`appcap_block.py report` emits exactly that JSON;
  coordinate with the shell agent building the app);
- applies to enabled apps' flows, and optionally to all apps via the proxy/DNS;
- **complements Pi-hole, does not replace it**; observe-and-block only — no
  account, spend or ToS risk.

Tested: `google-analytics.com`/`app-measurement.com`/`appsflyer.com`/
`amplitude.com` → blocked; `api.open-meteo.com` → functional/allowed; a synthetic
5-flow app report rolled up blocked vs allowed calls+bytes per host; a per-app
`allow` override flipped one analytics host back to allowed.

---

## 2. Architecture

```
  ┌─ PHONE (OnePlus Open, rooted / Magisk) ──────────────────────────┐
  │  Target app (user logged in, using it normally)                  │
  │     │ HTTPS / WS / gRPC                                           │
  │     ▼                                                             │
  │  [TLS trust] system CA (Magisk module)  ± Frida unpinning        │
  │     │                                                             │
  │     ▼  routed only while "capture mode" is ON for this app       │
  │  WireGuard → analysis subnet (10.13.14.0/24)                     │
  └──────────────────────────────────┬──────────────────────────────┘
                                      ▼
  ┌─ MAC / Colima VM (192.168.50.100) ───────────────────────────────┐
  │  ssl-bypass-foundation  (transparent MITM, capture → SQLite)     │
  │     ├ schema_learner      (JSON types per route)                 │
  │     ├ service_profiler    (route patterns, :id normalization)    │
  │     └ credential/token    (ENCRYPTED token store — see §5)       │
  │                    │                                             │
  │                    ▼                                             │
  │  har2openapi.py / spec-builder  →  openapi.json  (per app)      │
  │                    │                                             │
  │                    ▼                                             │
  │  toolgen  →  PowOS AI tools  /  MCP server  (per app)           │
  │             (reads un-gated; mutations gated; checkout blocked) │
  └──────────────────────────────────┬──────────────────────────────┘
                                      ▼
  ┌─ PowOS AI (manager / companion) ─────────────────────────────────┐
  │  calls generated tools → mints a session from the token store    │
  │  for reversible actions; for anything that spends, presents the  │
  │  basket + total and waits for the user's yes, or just opens the  │
  │  real app on its cart screen for the user to finish.             │
  └──────────────────────────────────────────────────────────────────┘
```

Two capture routes, used together as needed:

- **Network MITM (default, `ssl-bypass-foundation`).** Phone trusts our CA;
  traffic for the enabled app is routed through the proxy on the analysis VPN
  subnet. Sees everything on the wire. Needs a system CA (and pinning handled).
- **In-app Frida hook (`powstation-frida`).** When the app pins hard or signs
  requests, hook it in-process: read the request *before* it is signed/encrypted
  and *after* responses are decrypted, and neutralize the pinner. More invasive,
  per-app, but defeats pinning and lets us see request-signing inputs.

Only one app's traffic is ever routed/hooked at a time, only while the user has
flipped capture ON for it (see §4). Everything else uses the normal VPN subnet
and is never intercepted.

---

## 3. The hard parts, honestly — and what they mean for Uber Eats

| Obstacle | What it is | Our handling | Uber Eats reality |
|---|---|---|---|
| **TLS pinning** | App ships its own cert/pubkey and rejects our CA. | `universal-ssl.js` (Frida) unpins at runtime; or patch the APK's `network-security-config`; CA alone isn't enough. | Uber pins (OkHttp CertificatePinner + native). Expect to need **Frida unpinning**, not just the CA. |
| **Request signing / attestation** | App signs requests with a device secret; server rejects forged/replayed calls. Includes **Play Integrity / SafetyNet** device attestation. | Must mint the signature the way the app does → means hooking the signing function in-app (Frida) and either calling through the app or replaying its signer. Can't be done from the proxy alone. | Uber uses **`x-uber-*`** signed headers and heavy device fingerprinting. This is the **hardest blocker**: a captured session may only work replayed from the same device, and signatures expire. Likely need the Frida in-app path, calling the app's own signer. |
| **Bot / anomaly detection** | Server flags traffic that doesn't look like the real app (timing, headers, device graph). | Keep real app headers/UA from the capture; low call volume; only mirror flows the user actually performs; never automate checkout. | Uber runs sophisticated fraud/bot detection. Unusual cart-building velocity or a session used off-device can get the **account flagged or banned**. This is a real risk to the user's account — not just a technical one. |
| **gRPC / protobuf** | Body is binary protobuf, not JSON; needs the `.proto` to decode. | Capture raw; decode with `protoc --decode_raw` for field numbers; recover field names from the app (Frida dumps the descriptors) → then schema-infer. `har2openapi.py` handles JSON today; protobuf is a documented extension. | Parts of Uber's stack are gRPC. Some flows won't be readable as JSON without the descriptors. |
| **WebSockets / streaming** | Live order tracking etc. over WS. | `ssl-bypass-foundation/websocket_handler.rs` already captures WS frames both directions. | Order tracking is WS; readable, but it's a read, not needed for basket-building. |
| **ToS / account ban** | Automating a consumer app usually violates its ToS; the account is the user's to risk. | **Design keeps the AI to reversible actions and hands checkout back to the user**, which is the lowest-risk posture, but does not make it ToS-compliant. | **Uber Eats ToS prohibits automated access.** Honest bottom line below. |

### Uber Eats — honest feasibility

- **Technically:** reading the menu/catalog and building a cart is *probably*
  capturable, but **only via the Frida in-app path** (pinning + signed
  `x-uber-*` headers + Play Integrity make the pure-proxy route unlikely to
  work), and a captured session may be **bound to the device and short-lived**,
  so the practical shape is "AI drives the app's own networking through a hook on
  the phone," not "AI holds a portable token and calls from the Mac."
- **Account risk:** real and non-trivial. Automated cart-building can trip
  fraud/bot detection and get the account **flagged or banned**. This is Uber
  Eats specifically, not a generic worry.
- **ToS:** automated access violates Uber's terms. That's the user's call to
  make on their own account; the design does not pretend otherwise.
- **Recommendation for Uber Eats specifically:** treat it as a **later, opt-in,
  Frida-path** target, and seriously consider the **lower-risk alternative**:
  the AI assembles the basket as a *plan* (items + quantities + the exact
  deep-links/search terms), then **opens the real Uber Eats app** pre-filled as
  far as deep links allow, and the user does the final add-to-cart + checkout in
  the genuine app. Much of the value, almost none of the account risk. Start the
  whole pipeline on a **friendlier app** (see §7).

---

## 4. The "enable an app" flow

Capture is **off by default** and **per-app, user-initiated**. Enabling an app
is an explicit act with these steps (UI lives in PowOS; mechanics here):

1. **One-time phone prep** (reversible, see §6): install the PowOS CA as a system
   CA via a Magisk module; install frida-server as a managed unit (stopped until
   needed).
2. **User picks the app** and taps *Enable capture*. PowOS:
   - routes **only that app's** package through the analysis VPN subnet (or
     starts the Frida hook for it); everything else stays on the normal subnet;
   - shows a clear "RECORDING <app>" banner.
3. **User uses the app normally** — including logging in themselves. They browse,
   search, add to cart once or twice. PowOS never types credentials.
4. **User taps *Stop*.** Routing/hook for the app turns off.
5. PowOS runs capture → `har2openapi.py` → a per-app `openapi.json`, extracts the
   session/refresh token into the **encrypted token store** (§5), and generates
   tools (§6). The user sees a summary: "learned N endpoints (M reads, K
   mutations); checkout endpoints are blocked."
6. **Re-capture** any time to refresh an expired token or learn new flows.

A captured app's record (`apps/app-api/<pkg>.json`, no secrets) stores: package,
host(s), the learned spec path, which operations are reads vs mutations, which
are **blocked** (checkout/pay/message), and the token-store key id — never the
token.

---

## 5. Token storage (secrets — local, encrypted, never printed)

Requirement: captured session/refresh tokens stay local, encrypted at rest,
never printed, never committed.

- **Do NOT reuse `ssl-bypass-foundation/credential_store.rs` as-is** — it stores
  `header_value` as plaintext in SQLite. Change it to encrypt the value column
  before any real account is captured.
- **Store:** an age/`libsodium` sealed blob per token, keyed by
  `(package, host, header_name)`. Key material:
  - **On the phone:** Android Keystore (hardware-backed) wraps the store key, the
    way the app secret store already holds `${secret:hue}` for Lights. Tokens
    captured on the phone belong on the phone.
  - **On the Mac:** the store key lives in `secrets/` (already git-ignored,
    root-only), mirroring how `dev/net-secret.sh copy|remove` moved the Hue key
    into the desktop host "the value never printed" (commit `82ff8ad`).
- **Injection, never exposure:** tools reference a token as a handle
  (`${app-api:<pkg>:session}`), resolved by the host at call time and attached to
  the outbound request — exactly the `${secret:hue}` model. Tool code, logs, the
  spec, chat and git never see the value.
- **Refresh:** the capture records *how* the token is renewed (the refresh/login
  response that mints it, its lifetime). The host refreshes on 401 by replaying
  the captured refresh flow; it never asks the user for a password.
- **Logging discipline:** redact `Authorization/Cookie/token/...` in every log
  sink (the proxy already redacts to a 12-char prefix in its API output; apply
  the same at the store boundary so the raw value is encrypted the moment it
  lands and decrypted only into an outbound request).

---

## 6. First end-to-end flow: "prepare a basket" (Uber Eats as the example)

This is the concrete target. The AI prepares a basket; the user owns checkout.

**Allowed without confirmation (reversible, no spend):**
search the catalog/menu, read item details, add / change quantity / remove items
in the cart, read the current cart. These map to these spec operations (names
illustrative; the real ones come from the capture):

| Intent | Operation (from the learned spec) | Gate |
|---|---|---|
| find a restaurant / dish | `GET /search?q=…`, `GET /feed?location=…` | none (read) |
| item detail / options | `GET /store/{id}`, `GET /catalog/item/{id}` | none (read) |
| **add to basket** | `POST /cart/{id}/items` → `x-powos-mutation` | none — **reversible, no spend** |
| change quantity | `PATCH/PUT /cart/{id}/items/{line}` | none — reversible |
| remove item | `DELETE /cart/{id}/items/{line}` | none — reversible |
| read basket | `GET /cart/{id}` | none (read) |
| **checkout / place order / pay** | `POST /checkout`, `POST /orders`, `/payment…` | **BLOCKED in the tool layer** |

Cart edits are mutations (`x-powos-mutation: true` in the spec) but are **not**
money-spending, so the tool layer allows them freely — they change only the
basket, which the user can see and undo. The distinction the tool generator
enforces is **"spends money / sends a message"**, not "is a mutation":

- reversible mutation (cart add/update/remove) → allowed, no confirmation;
- spend/send (checkout, pay, message) → **blocked**; the AI cannot call it.

**How the user sees and completes the basket:**
1. The AI builds the basket by calling the read + cart operations.
2. It then **presents the basket in chat** — every line item + the subtotal — via
   the manager's `present` card (see the `powos-chat` skill), and either:
   - **opens the real app on its cart screen** (deep link / the adb-to-itself
     window from `units/phone-android/adb-self.json`) so the user reviews and
     presses *Order* **in the genuine app** (preferred — Uber's own checkout,
     Uber's own fraud posture, zero replayed-payment risk); **or**
   - if a programmatic checkout is ever wired, it runs **only** after an explicit
     per-order **yes in chat that shows the items and the total**, and even then
     the payment step stays in the app.
3. The AI never presses Order and never touches payment.

For the **first real build**, use the §7 safe app (a menu with a cart but where
the "order" is free/trivial, or a grocery list app), prove add→read→present→hand
off, *then* consider Uber Eats on the Frida path with the user's explicit yes.

---

## 7. Prototype built (capture → OpenAPI), and what it proves

Under **`tools/app-api/`**:

- **`har2openapi.py`** — HAR → OpenAPI 3.1, stdlib-only, no network, secret-safe.
  Templates volatile path ids (`/cart/88f3…/items` → `/cart/{id}/items`), infers
  request+response JSON Schemas by merging samples (a field missing in any sample
  becomes optional), records query params with examples, detects the auth scheme
  (Bearer/cookie/api-key) as an OpenAPI `securityScheme` **without the value**,
  and tags every non-GET op `x-powos-mutation: true` for the gate in §6.
- **`capture-demo.sh`** — a **zero-risk** end-to-end run: captures live reads from
  **Open-Meteo** (free, public, **no auth, no account, no spend**) into a HAR,
  then builds the spec. This is the safe stand-in for "use the app while a proxy
  records."
- **`sample/open-meteo.{har,openapi.json}`** — the committed, reproducible output.

And the **capability-spec layer** (§1b) — the clean, app-independent spec and its
generators:

- **`schema/appcap.schema.json`** — the JSON Schema for `*.appcap.json`.
- **`appcap_validate.py`** — enforces the safety invariants S1–S9 (widget⇒read,
  spend⇒confirm+no-widget, captured-non-read⇒promoted, token handles only,
  auth/endpoint resolve). No bad spec reaches a generator.
- **`appcap_render.py`** — the **"view the resulting API"** generator: `--api`
  (human reference), `--tools` (MCP/PowOS-AI tool list), `--cli`, `--widgets`,
  and `--call <action> --arg k=v` which **dry-run previews** the exact request
  (method, URL, the app's own header shown only as its handle, body) and **never
  sends** — so it is safe to run against Hue without touching the lights.
- **`examples/hue.appcap.json`** — the full worked example (5 actions: reads,
  reversible writes, and a UI-navigation action that opens the Lights page).
- **`viewer/index.html`** — standalone visual viewer (the toggle/view surface
  prototype): renders each app's actions with safety badges, endpoint mapping,
  auth handle and widget/refresh hints.

And the **local runtime** (runs on PowOS, offline):

- **`appcap_store.py`** — the encrypted-at-rest token store (openssl AES-256-CBC
  encrypt-then-MAC, 0600 keyfile, values never printed; `set` reads from stdin,
  `migrate --from-json` imports a plaintext source without printing). Tested:
  set/list/get roundtrip, no plaintext in the DB file, tamper rejected, migrate.
- **`appcap_run.py`** — the one shared call path: resolve → allowlist → enforce
  safety class → inject auth by handle → rate-limit → dry-run/send → audit.
  Default is dry-run; `--send` performs; `spend` needs `--send --confirm`; a
  `widget` consumer may only call reads. Tested: Hue writes stay dry-run (lights
  untouched), widget-write refused, spend-without-confirm refused, a real read
  send to Open-Meteo returned 200, a native-CLI action (`base.kind=cli`) ran, and
  the audit log recorded each call with secret args redacted.
- **`openapi2appcap.py`** — capture→appcap emitter: a captured OpenAPI becomes a
  DRAFT appcap with reads enabled and every write disabled-until-promoted. Tested
  on the Open-Meteo sample (2 reads enabled) and a synthetic cart capture
  (get_menu enabled; add_item + checkout present but OFF, checkout classed
  `spend`+confirm) — both validate.

**Verified (2026-10-23):**
- real capture → spec: 4 Open-Meteo reads → 2 operations
  (`GET /v1/forecast`, `GET /v1/search`) with inferred nested response schemas;
- path templating, mutation tagging and auth-scheme detection on a synthetic
  cart-style HAR (`POST /cart/{id}/items`, `x-powos-mutation: true`, `bearerAuth`
  scheme emitted);
- **leak check passed**: a HAR carrying a Bearer token, a session cookie, a
  `session=` query value and a `token` response field produced a spec containing
  **none** of those values;
- the Hue spec validates and renders into all four consumer views; its 5 actions
  classify correctly (3 read incl. the UI nav, 2 reversible-write);
- safety invariants enforced: a crafted spec with a `spend`+widget action, a
  spend with no confirm, a captured non-promoted write, an inline token value and
  a dangling auth ref produced **6 errors** (S1–S5) and was refused;
- **lights untouched:** `--call set_room/list_rooms/open_lights_page` built the
  real requests (incl. the `hue-application-key` header resolved from `secret:hue`,
  value never shown) and sent nothing — `appcap_render.py` is a previewer that
  has no send path.

Why HAR as the seam: mitmproxy, HTTP Toolkit, reqable and Chrome DevTools all
export HAR, and `ssl-bypass-foundation` can emit it — so the converter is
decoupled from how the capture was done. We did **not** capture Uber Eats or any
logged-in app.

### Tool survey (what each is for)

| Tool | Use | Verdict here |
|---|---|---|
| **`ssl-bypass-foundation`** (ours) | transparent MITM, capture, schema/route learning, WS, emulator | **Primary engine** — already built, LAN-wide, VPN-routed. |
| **Frida / objection** (`powstation-frida` wraps it) | unpin TLS, hook in-app, read pre-sign/post-decrypt | **Required** for pinned/signed apps (Uber). |
| **mitmproxy + mitmproxy2swagger** | the standard capture + a HAR/flows→OpenAPI path | Good alternative capturer; our `har2openapi.py` plays the mitmproxy2swagger role but tuned to our mutation/secret rules. |
| **HTTP Toolkit** | friendly desktop capture, one-click Android intercept | Great for quick manual captures; exports HAR → our converter. |
| **apk-mitm** | re-signs an APK to trust user CAs (patches network-security-config) | The **non-Frida** way past soft pinning; per-app, needs reinstall. |
| **reqable** | mobile+desktop capture, HAR export | Fine alternative capturer. |
| **debug-proxy** (ours) | replay/mock a learned API without the real server | Dev/test of generated tools. |

---

## 8. Recommendation + effort

**Already built (this work, committed under `tools/app-api/`):** the capability
spec + JSON Schema, the safety-invariant validator, the capture→OpenAPI
converter, and the `appcap_render.py` generators that produce the API view, the
AI tool list, the CLI listing, the widget bindings and a dry-run request preview
— plus a standalone HTML viewer; the **local encrypted token store**, the
**runtime call path** (safety enforcement + handle-injected auth + audit), the
**capture→appcap emitter**, and **tracker identification + blocking**
(`appcap_block.py`, default-block trackers, per-app report + allow switch). The
*model*, its *generators*, the runtime and the tracker blocker exist and are
tested; what remains is wiring them to the live capture and the phone. The phone
prep (CA + frida-server) is defined as reversible registered units
(`units/phone-android/app-ca.json`, `app-frida.json`) with documented uninstall,
to be installed + uninstall-tested ON-DEVICE by the on-device agent with the user
present (not from the Mac); SELinux is never touched and interception applies
only to apps on the per-app allowlist.

**Build order (reuse-first):**

1. **Harden the token store** in `ssl-bypass-foundation` — encrypt the credential
   value at rest (age/libsodium), Keystore-wrapped on phone / `secrets/` on Mac,
   `${app-api:…}` / `store:` handle injection. **Blocker for any real account.** ~1–2 days.
2. **Wire `har2openapi.py` onto the live capture**, then an **`appcap` emitter**:
   capture → OpenAPI → a draft `*.appcap.json` with every action `read`/captured
   (promotion left to the user). ~2 days. *(Converter + spec + validator already
   done.)*
3. **Runtime + `toolgen`**: the one shared call path (resolve → allowlist →
   enforce safety → handle-inject auth → rate-limit → dry-run/send → audit) and
   the four generators emitting against it. The render/validate logic is done;
   this makes them *execute*. Reads un-gated; reversible writes logged with undo;
   `spend` requires confirmation; `spend`/writes never reachable from a widget.
   ~3–4 days.
4. **The "App API" PowOS app** (§1b.12): toggle apps/actions, run capture, promote
   captured actions, view the rendered API + audit. The CLI + HTML viewer are the
   prototype; the in-shell app is this step. ~3–4 days.
5. **UI automation** (§1b.10): deep-link/intent first; `steps` via the phone's
   accessibility path (and AT-SPI/D-Bus for native Linux), honoring no-touch
   -injection-while-active. ~2–3 days.
6. **Prove "prepare a basket" end-to-end on a safe app** (grocery-list / a menu
   app with a free cart), present-in-chat + hand-off to the real app's cart
   screen via a UI action. ~2 days.
7. **Phone prep as units**: Magisk system-CA module + managed frida-server unit,
   both with documented removal (§ below). ~1 day.
8. **Native Linux apps** (§1b.11): user-CA MITM (no root), plus map D-Bus/CLI
   surfaces directly as `official` actions. Lower-risk, can run in parallel. ~2 days.
9. **Only then, Uber Eats as an opt-in Frida target** — with the user's explicit
   yes, the account-risk and ToS caveats of §3 stated, and the hand-off-to-app
   model of §6 as the default (no programmatic checkout).

**Total to a safe, working "prepare a basket" + the toggle/view app on a friendly
app: ~2.5–3 weeks**, most of it integration since the capture engine and the
whole spec/generator layer already exist. Native Linux apps are the quickest win
(no root, often a D-Bus/CLI to map directly). Uber Eats is a separate, riskier
increment on top.

**My recommendation:** build steps 1–6 and ship the "prepare a basket" flow on a
**low-risk app first**. Keep Uber Eats behind the Frida path and the hand-off
model; don't hold portable Uber tokens or automate its checkout. The highest
value for the least risk is: **AI fills the basket, user taps Order in the real
app.**

### Phone changes and how to undo them (reversible)

Both go in `units/phone-android/` with `owner`, `purpose`, `installedBy`, and a
`remove`:

- **PowOS system CA** — Magisk module dropping the PowOS CA into the system trust
  store (needed because Android 7+ apps ignore user CAs). *Undo:* remove the
  Magisk module + reboot; trust reverts. Does **not** touch SELinux.
- **frida-server** — pushed to `/data/local/tmp`, run as root via Magisk, **kept
  stopped** until a capture starts. *Undo:* stop + delete the binary; the unit's
  `remove` lists both. Does **not** weaken SELinux or modify system partitions.

Neither is active except during an explicit capture window. Capture routing is
per-package and off by default.

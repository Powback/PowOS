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

**Verified (2026-10-23):**
- real capture → spec: 4 Open-Meteo reads → 2 operations
  (`GET /v1/forecast`, `GET /v1/search`) with inferred nested response schemas;
- path templating, mutation tagging and auth-scheme detection on a synthetic
  cart-style HAR (`POST /cart/{id}/items`, `x-powos-mutation: true`, `bearerAuth`
  scheme emitted);
- **leak check passed**: a HAR carrying a Bearer token, a session cookie, a
  `session=` query value and a `token` response field produced a spec containing
  **none** of those values.

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

**Build order (reuse-first):**

1. **Harden the token store** in `ssl-bypass-foundation` — encrypt the credential
   value at rest (age/libsodium), Keystore-wrapped on phone / `secrets/` on Mac,
   `${app-api:…}` injection. **Blocker for any real account.** ~1–2 days.
2. **Wire `har2openapi.py` onto the live capture** — add a HAR/`exchanges`
   exporter to the proxy (the schema+route data already exists) so capture→spec
   is one command. ~1 day. *(Converter already done — this prototype.)*
3. **`toolgen`**: spec → PowOS AI tools (+ optional MCP server). Reads un-gated;
   reversible mutations (cart) allowed; **checkout/pay/message operations dropped
   entirely** so the AI *cannot* call them; token injected by handle. ~2–3 days.
4. **"Enable an app" UX** (§4) + per-app record. ~2–3 days.
5. **Prove "prepare a basket" end-to-end on a safe app** (grocery-list / a menu
   app with a free cart), present-in-chat + hand-off to the real app. ~2 days.
6. **Phone prep as units**: Magisk system-CA module + managed frida-server unit,
   both with documented removal (§ below). ~1 day.
7. **Only then, Uber Eats as an opt-in Frida target** — with the user's explicit
   yes, the account-risk and ToS caveats of §3 stated, and the hand-off-to-app
   model of §6 as the default (no programmatic checkout).

**Total to a safe, working "prepare a basket" on a friendly app: ~1.5–2 weeks**,
most of it integration since the capture engine exists. Uber Eats is a separate,
riskier increment on top.

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

# The PowOS composer

**Goal (the user's words):** "we should be able to create absolutely any app or widget using any other app or widget
or software." The composer lets PowOS AI, or the user in plain words, make a new PowOS widget (next: an app) out of
the building blocks PowOS already has, without writing code and without weakening any safety rule.

**Status (2026-10-23):** first slice working - `powos compose widget "<plain words>"` makes a home widget from App API
read actions (the Hue room-status widget is the worked example), installs it, and it shows in home's edit sheet.
Composed *apps* (pages that may also write) are designed below, not built.

## 1. Building blocks

Everything a composition may use is something that already exists, reached only through its own public surface:

| Block | What it is | How a composition reaches it | In this slice |
|---|---|---|---|
| **appcap action** | an app capability spec's action (`tools/app-api`, docs/APP-API-CAPTURE.md): Hue, Open-Meteo, any captured app | App API's call path (`appcap_serve.py` /call -> `appcap_run.py`), as consumer `widget` (reads only) or `app` | yes - widget-safe reads |
| **CLI / D-Bus action** | a Linux command or D-Bus call, as an appcap action with `base.kind: cli` + `endpoint.argv` | the same call path (the runtime runs the argv; safety class as declared) | yes, through appcap (no CLI spec ships yet) |
| **PowOS app** | an app's SpacetimeDB database (apps/, ~/Projects/*: Lights, Sketch, Shopping) | its **subscriptions** (read) and **reducers** (its own API), never a write to its tables | designed (`block: stdb`) |
| **composition** | another composed widget/app | its `snapshot` table (what it last read), subscribed read-only | designed |
| **OWL widget** | a `.owl` widget (the Kotlin engine's sources) | embedded as a tile part, its sources unchanged | designed |
| **navigation** | "open app X" (an appcap UI read action with `endpoint.ui.route: app://X`) | `host.openApp(X)` on a tap | yes (`open`) |

The catalog is `powos compose blocks` (`--json` for PowOS AI): every widget-safe read action of every spec in App API,
switched on or off, with the inputs it needs and its **row hint** - the spec's new optional `view` field
(appcap.schema.json, validator rule S10, reads only):

```jsonc
"list_rooms":          { "view": { "rows": "data", "key": "id", "label": "metadata.name" } },
"list_grouped_lights": { "view": { "rows": "data", "of": "list_rooms", "key": "owner.rid",
                                   "fields": { "on": "on.on", "level": "dimming.brightness" } } }
```

`of` says these rows annotate another read's rows of the same app (matched on `key`): that is how the word match
knows a room's on/off lives in its grouped light. Hue gained the `list_grouped_lights` read (CLIP v2
`/resource/grouped_light`) for this.

## 2. A composition is one manifest

`composition.json`, spec `powos.compose/v1` - the whole description; the app folder is generated from it:

```jsonc
{
  "spec": "powos.compose/v1", "kind": "widget",
  "id": "local.hue-rooms", "name": "Hue rooms",
  "words": "which Hue rooms are on", "by": "ai | matcher | user",
  "uses": [                                     // the blocks, each named by `as`
    { "as": "rooms", "block": "appcap", "app": "hue", "action": "list_rooms", "name": "Philips Hue" },
    { "as": "grouped_lights", "block": "appcap", "app": "hue", "action": "list_grouped_lights", "name": "Philips Hue" }
  ],
  "show": {                                     // how it looks: a template + its bindings
    "template": "status-list", "title": "Hue rooms",
    "rows": { "from": "rooms", "path": "data", "key": "id", "label": "metadata.name" },
    "join": [ { "from": "grouped_lights", "path": "data", "key": "owner.rid",
                "fields": { "on": "on.on", "level": "dimming.brightness" } } ],
    "empty": "Nothing to show"
  },
  "refresh": { "poll_s": 10 },                  // the blocks' own refresh hints, at least 5 s
  "open": "local.lights",                       // a tap opens it (navigation only)
  "widget": { "size": "4x2", "minSize": "2x1" }
}
```

Templates are generic widget bodies the composer owns (`lib/apps/templates/composed/ui/widgets/<template>.tsx`). The
first is **status-list**: rows of a name with an on dot, a level bar or a value - which covers rooms, sensors,
containers, services, a forecast's "Now 12 °C" (rows of one object, a `=Literal` label). More templates (a single big
value, a chart over a snapshot history, a grid of tiles, an OWL embed) slot in the same way: a template is a name in
`show.template` plus its own binding fields.

## 3. Generation

```
plain words --> PowOS AI (or the word match) --> manifest --> the rules (check) --> app folder --> powos app install
```

- **PowOS AI** gets the blocks catalog and the manifest's shape and answers one JSON object (`powos ai`; the command
  is `POWOS_COMPOSE_AI`). Its manifest is used only if it passes the rules; otherwise the composer says so and uses the
  word match. PowOS AI's chat has the same thing as tools: `compose_blocks` and `compose_widget` (the manager's MCP
  server, lib/ai/comms/comms-mcp.py), with `!powos compose help` in its prompt.
- **The word match** (no AI, deterministic, offline): the widget-safe read whose app name, action and summary share
  the most words with the request (lights -> hue, weather -> forecast), plus the reads of the same app whose `view.of`
  is it; the title from the app and the action ("Hue rooms"); `open` from the app's UI action.
- **The folder** (default `~/Projects/<name>`): `powos-app.json` (`net: ["127.0.0.1"]`, one island, the manifest
  embedded as `composition`), `composition.json`, `ui/` (the template, `lib/compose.ts` - the runtime -, the
  shell's `lib/app.ts`, an icon), and `module/` - **the one shared module** every composition runs (apps/composed),
  copied with its build (wasm + `.module.sha` + bindings) when that build is of exactly this source, so composing
  never compiles Rust. `powos compose build <dir>` regenerates the folder after the manifest is edited.

Commands: `powos compose blocks | widget | check | build | install` (`powos compose help`).

## 4. Registry and databases (the SpacetimeDB layers stay separate)

- A composition is an ordinary PowOS app: `powos app install` publishes the shared module to **its own database**
  (`local-hue-rooms`), puts its UI in place and registers it in **powos-registry** (the `app` row keeps the whole
  `powos-app.json`, so the composition and the blocks it uses are in the registry; the `widget` row is what home's
  edit sheet lists under "PowOS apps"). `powos app remove` takes it away again; it's a unit like every app.
- Its database holds only its own state: `snapshot` (one row per block: the last JSON it read), written by its own
  reducer `keep` when a read came back different. That is what shows greyed while a block is away, and what another
  composition subscribes to - a composition is itself a building block.
- It never writes another app's tables. Other apps are reached only through their reducers, their subscriptions or
  their capability actions (App API), each through that app's own surface.

## 5. Safety

The safety classes of docs/APP-API-CAPTURE.md carry over unchanged, enforced in three places:

1. **At compose time** (`powos compose check`, every compose/build/install): C1-C7 in `powos compose help` - above
   all C4: a widget's every block is a `read` marked widget-safe; a reversible write, a spend or a non-widget read is
   refused (PowOS AI's manifest included: a widget that would switch the lights off is refused and replaced).
2. **At call time** (the runtime, whatever the code asks): the widget calls App API as consumer `widget`, and
   `appcap_run.py` refuses anything but a read for that consumer; the app's and the action's allowlist (`enabled`)
   apply; a send with an unfilled placeholder (`{bridge_ip}` of an unlinked Hue) is refused instead of going
   anywhere; a pinned-TLS device is reached only when its certificate matches the pin its link step stored
   (`<state>/state/<app>.json`); every call is in the audit log as `consumer: widget`.
3. **By construction**: the widget's manifest allows only `127.0.0.1` (App API) on the network, and its code has no
   reducer of another app, no write action, no other URL.

Composed **apps** (next): a page may bind reversible writes (through the call path as consumer `app`, dry run first,
each logged with its undo) and never sends a spend itself - a spend is handed to PowOS AI's chat, which shows the
action's `confirm_template` (what and how much) and sends only on the user's explicit yes (`--confirm`).

Everything runs on PowOS itself: the composer, App API's runtime, the module and the widget. The Mac is only a build
host (`powos app builder`) when a module has to be compiled, which a composition doesn't.

## 6. A device already paired: handed over by its own app (Hue from Lights)

A device the user paired in its own PowOS app is not paired again. The app hands the pairing to App API itself,
through its own interface (`tools/app-api/appcap_link.py`):

- **Lights** (`~/Projects/lights`, `ui/lib/appapi.ts`), once its bridge answered, does `GET /link?app=hue` on App API
  (`net` now declares `127.0.0.1`). If App API isn't linked to that bridge address yet, Lights sends
  `POST /link {app: "hue", from: "local.lights", state: {bridge_ip, bridge_id}, pin}`. The key goes in the header
  `x-powos-secret: ${secret:hue}`, and the PowOS app fills in the value on the way out (ShellNet.kt). Lights' code
  never sees the key. The pin is the certificate host.net pinned for the bridge (`host.net.pin`, new in ShellNet; an
  older PowOS app sends none). This happens once per shell session, and again when the address changes.
- **App API** keeps the pairing only after checking it:
  - The bridge's certificate must be the pin. Without a pin, its subject must be the bridge id Lights paired with,
    and then that certificate is pinned.
  - The key must read the bridge (`GET /resource/bridge`, nothing changes).

  The key then goes into the encrypted store as `secret:hue`. The address and pin go into
  `<state>/state/hue.json`, plus one audit line without the key. `GET /link` reports linked/pinned, never the key.
- Nothing reads Lights' tables or its private storage. App API only receives what Lights chose to send. Without an
  App API that has `/link` (a service started before this change), Lights' GET gets a 404 and nothing happens; the
  next session tries again.
- Known limit, the same as ShellNet's HACK about app ids: App API can't tell which app called `/link`. Any PowOS app
  that declares `127.0.0.1` could send a pairing, though it must still pass the certificate and read checks.

Until it's linked, the widget shows "Link Hue in App API", and the runtime refuses its reads ("needs bridge_ip").

App API's service picks up a newer package's actions and row hints (`list_grouped_lights`, `view`) and `/link` at its
start (`appcap_serve.py` seed is additive and keeps the toggles). On the phone that's the next start of the app-api
service (a system-tier restart).

## 7. Tests

- `test/tier1/test-composer.py` (headless, no network): the rules (writes, spend, switched-off, inputs, refs), the
  word match, PowOS AI's manifest used / refused, the folder (own database, net, island, module build copied only on
  a matching stamp), the widget's code, and the runtime + service paths (a widget's write refused with nothing sent,
  unlinked and unpinned sends refused, a read's JSON parsed, consumer passthrough, the additive seed).
- `tools/compose/render-check.sh`: composes the Hue widget, builds it and renders it in the widget preview at every
  size, both screens, two themes, against mocked App API answers (live, not linked, stale).
- `test/tier1/test-appcap-link.py` (headless, a fake HTTPS bridge on loopback): link by header only, pin / bridge id /
  key checks, nothing kept on a refusal, the key nowhere in the clear; then the widget's two reads reach the bridge and
  a widget's write is refused (the bridge sees GETs only).
- `tools/phone/verify/hue-link.sh`: on the phone, after App API's restart - linked by Lights and pinned, both reads
  answer from the real bridge with rows, and the audit shows reads only.
- `tools/phone/verify/composer.sh`: on the phone - installed and registered (the edit sheet's list), its module
  served to the shell, its database published, and App API's audit shows the widget's calls as reads only.

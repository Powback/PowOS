# Any app -> a PowOS widget (plan, 2026-10-28)

**Goal (the user's words):** "insanely easy to turn any app into a customized widget" - one widget per wearable, a
superwidget or a health central fed "right out of the apps", "my youtube recommends or my x feed there as if the
original app was doing it". The end state: *"PowOS AI, make me a widget of my X feed"* -> a live tile on home.

**One widget system.** Everything below lands in PowOS's own widgets: **app islands** (an app's `ui/widgets/*.tsx`,
`shell/ui/island.tsx`, on home's grid, checked by `shell/dev/preview.sh`), made by the **composer**
(`docs/COMPOSER.md`: `composition.json` -> template island -> its own DB). **OWL is kept out**: no new `.owl`, no OWL
block in the composer (drop its "OWL widget" row and "OWL embed" template), recon's `owl` field unused. Whether OWL is
retired outright is decision D1.

## 1. What exists

| Piece | Where | State |
|---|---|---|
| Android widgets live on home, as pixels | `shell/AppWidgets.kt` (off-screen AppWidgetHost on a private VirtualDisplay, frames to `/_appwidget/<id>`), `AppWidgetColors.kt` (PowOS palette), `shell/ui/appwidget.tsx`, bridge `appwidgets.*` | shipped (a2ace3db, 29ba27e6); BIND_APPWIDGET via privapp allowlist |
| Widget *data* reader | `widgets/recon/ViewTreeDump.kt` (texts, sizes, colours, images, bounds), `RemoteViewsDump.kt` (setText/bitmaps by reflection) | built for recon only (agents copying widgets into OWL) |
| App API widget analysis | `AppLinks.kt` -> `appcap_add.py from_android`: `spec.android.widgets`, `widget_*` read actions routed `android-widget://pkg/cls`, detail page card (`apps/app-api/ui/lib/action.tsx Widgets`) | shipped (91544490); **nothing resolves `android-widget://` yet**, no "put on home" |
| Notifications | NotificationListener (`MediaListener`), bridge `notifications.list/changed/open/action` | shipped; nothing kept (no history) |
| Capture + tracker blocking | `appcap_proxy.py`, `appcap_block.py`, capture -> read-only draft (c4e5efca, 002d9951); Frida unpinning in `powstation-frida/` | built; pinned apps need Frida (docs/APP-API-CAPTURE.md section 3) |
| Composer | `lib/apps/powos-compose`, `lib/apps/templates/composed/ui/{lib/compose.ts,widgets/main.tsx}` (status-list), C1-C7 rules, `snapshot` table per composition, PowOS AI tools `compose_blocks`/`compose_widget` | first slice shipped (5afac436) - appcap blocks only |
| Accessibility service, Health Connect | - | none |

## 2. The pipeline: source -> block -> composition -> island

```
 source adapter  ->  block (a read: rows/record JSON + view hint)  ->  composition.json  ->  island template  ->  home
 (Android side       (catalogued in App API as a widget-safe read;      (uses: [blocks],      (status-list,
  or App API)         per-app switch, audit, consent)                   show, refresh)        native-card, feed, chart)
```

- **Two block kinds, one shape.** `appcap` (HTTP/CLI, run by App API's service, as today) and new **`android`**
  (`source: widget | notifications | health | screen`), resolved in the island's runtime (`compose.ts`) through the
  bridge - islands are trusted with it, so Android data never crosses to a network service. Both are listed in
  `powos compose blocks`, both return `{rows | record}` with a `view` hint, both honour App API's per-app enable.
- **Refresh** is event-driven for `android` blocks (`appwidgets.data`, `notifications.changed`), poll for `appcap`.
- **Superwidget** = a composition with several `uses` (status-list already joins blocks; add a "merge by key" join).
- **Central stores** (health first): a PowOS app `local.health` with **its own DB** (`sample(kind, t, value, unit,
  source)`), filled by its own reducer `ingest` from blocks it uses; other widgets subscribe to it. Never another
  app's tables (the SpacetimeDB layer rule); each source writes only through `local.health`'s reducer.

### Source adapters, ranked (effort / value)

| # | Adapter | How | Effort | Value | Risk |
|---|---|---|---|---|---|
| a | **App's own widget, as data** | AppWidgets already hosts it; after each update run ViewTreeDump on the hosted view -> slim `{texts, images, lists, taps}` -> `appwidgets.data`. Tap = existing `appwidgets.touch` at the element's bounds | **S-M** | high: weather, calendar, Garmin/Fitbit/Oura/Samsung Health step/sleep widgets | none new |
| b | Notifications | `notifications.changed` normalised per app (title, text, progress, messaging/media style) + a short history in the block's snapshot | S | med: deliveries, rides, messages | low |
| c | Health Connect / rooted DBs | `androidx.health.connect` reads (privileged app, perms granted via root `pm grant`) -> `local.health`; per-app rooted SQLite reads (read-only copy) for wearables that don't write HC | M (HC), L per app | **very high** (6 wearables -> one store) | rooted reads break on app updates |
| d | Screens (accessibility) | PowOS AccessibilityService (enabled via root), read-only node tree of a chosen app; run it on a hidden VirtualDisplay (as AppWidgets does) to refresh a feed without the user | L | high: YouTube home, X timeline | ToS/account flags, battery |
| e | Network responses | capture proxy, **passive**: latest response per captured read while the user uses the app (no replay) -> block | M-L | high when readable | pinning (X, YouTube) needs Frida |

### The builder ("PowOS AI, make me a widget of ...")
`compose_blocks` gains the android blocks; the AI picks: the app's widget if it has one (a), else notifications (b),
health (c), screen (d), capture (e). It writes `composition.json` with a template: existing **status-list**, new
**native-card** (a widget's texts/images in PowOS type and glass, largest text = headline), **feed** (title,
subtitle, thumbnail, tap -> deep link), **big-value + chart** (from `snapshot` history). Preview data and checks as for
every island; placeholders/progress while it builds (`creationwidgets.tsx`).

### Privacy and safety
All on the phone; images through the local `/_wimg` route only. A source is used only for an app switched on in App
API (consent per app and per source kind, shown on its detail page); every read audited as consumer `widget`. C4 still
holds: widgets only read; taps go back to the app (touch / deep link), never a write. Capture keeps tracker blocking.
`local.health` declares no network. Screen (d) and capture (e) stay off until the user enables them per app.

## 3. First slice: "pick an app's widget in App API -> it lives on home, in PowOS's style"

Step A is the instant win (the pixel host already works); B-F make it a real PowOS island fed by the widget's data.

| Task | Files (edit only) | ~min |
|---|---|---|
| A1 host API `host.home.addAppWidget(pkg, cls)`: name = `pkg/cls#0`, spot from `placeNewCells`, `powos.appWidgets.add` | `shell/apps/stdb.ts` (host), `shell/ui/editsheet.tsx` (reuse addAppWidget) | 8 |
| A2 "Put on home" on each card of App API's Widgets section (needs-set-up note when `configure`) | `apps/app-api/ui/lib/action.tsx`, `ui/lib/api.ts` | 6 |
| B Kotlin data mode: after a hosted widget redraws, ViewTreeDump the KeptView (no `owl` field, images to `/_wimg`) -> slim JSON; emit `appwidgets.data`, bridge `appwidgets.data(id)` | `shell/AppWidgets.kt`, `widgets/recon/ViewTreeDump.kt`, `shell/ShellBridge.kt` | 10 |
| C bridge types + mock data | `shell/bridge.ts`, `shell/types.ts` | 6 |
| D compose runtime: block `{block: "android", source: "widget", app, provider}` - hosts it hidden, subscribes data; `check` allows it as a widget-safe read | `lib/apps/templates/composed/ui/lib/compose.ts`, `lib/apps/powos-compose` | 10 |
| E template `native-card` (fill rules of the widgets skill; tap -> `appwidgets.touch` at bounds) + preview data + variant | `lib/apps/templates/composed/ui/widgets/native-card.tsx`, `shell/dev/preview/data/` | 10 |
| F "Make a PowOS widget" on the card -> `powos compose widget --from android-widget://pkg/cls` -> install; pending placeholder shown | `apps/app-api/ui/lib/action.tsx`, `lib/apps/powos-compose`, `tools/app-api/appcap_serve.py` | 8 |
| G docs: COMPOSER.md (android blocks, OWL rows removed), powos-shell skill widgets section | docs only | 5 |

About 65 agent-minutes, 8 tasks; A1-A2 ship alone first. Next slices: (b) notifications block + feed template;
(c) `local.health` + Health Connect; then (e) passive capture and (d) screens per decision.

## 3b. What landed: the health central (`local.health`)

D2/D5 decided: **Health Connect first** (the aggregator most wearable apps write to), rooted per-app DB reads later only
for apps that don't write to it; **history kept indefinitely** (nothing deletes by age).

- **Android side** (`shell/HealthConnectBridge.kt`, `androidx.health.connect:connect-client`, read-only). Bridge, all
  feature-detected (f307; `// detect` in `shell/bridge.ts`, `powos.health` is host-optional):
  `powos.health.status()`, `.grant()` (Health Connect's own permission dialog, shown over PowOS, once),
  `.read(types, sinceMs, untilMs?)` -> `{id, type, start, end, value, unit, source[, detail]}` (source = the package of
  the wearable's app; steps count, heart_rate bpm one record per sample, sleep/exercise min, weight kg, active_calories
  kcal), and `.token(types)` / `.changes(types, token)` -> `{token, records, deleted, expired}` so polling only
  fetches what changed. Manifest: the six `android.permission.health.READ_*`, the provider `<queries>` entry and the
  rationale activity-aliases Health Connect requires before it shows the dialog.
- **The app** (`apps/health`, id `local.health`, database `local-health`, own module). Tables: `sample` (every reading,
  keyed by the source's record id, so re-reads upsert), `daily` (per type, per source, per local day: sum/count/min/max/
  last - derived by the module), `cursor` (the changes token + newest sample). The `ingest` reducer is the only way
  samples get in; `rebuild(tz_min)` re-buckets days after a time-zone change. Other apps never touch these tables:
  widgets subscribe to `daily` (today and the last 7 days, per source) or go through appcap.
- **Sync loop** (`ui/lib/sync.ts`): runs in the app's own surfaces (page and widget) - at once, every 5 min, and when
  shown again - one loop at a time; first run reads the last 30 days (what Health Connect allows without the history
  permission) in week windows, later runs use the changes token. The page asks for the permission on first open; the
  widget only says to open the page. It does not run with no Health surface mounted (an app has no process of its own):
  for always-on sync a background reader would need the READ_HEALTH_DATA_IN_BACKGROUND permission and a service - not done.
- **Headline figure** per type is the source with the most that day, never a sum across sources (two apps often see the
  same steps); the per-source figures are all there.
- **To use it**: install the APK, `apps/install.sh health`, open Health and allow in the Health Connect dialog (or
  `pm grant com.powos.app android.permission.health.READ_STEPS` ... as root for the six).
- Not yet: the `android`-block `source: health` for compositions (widgets can already read `daily`), rooted per-app DB reads.

## 4. Open decisions for the user

- **D1** OWL: freeze (no new work, existing `.owl` tiles stay) or retire (move its widgets to islands, delete engine)?
- **D2** The six wearables: which apps? Health Connect first, or rooted per-app DB reads for those that don't write HC?
- **D3** Feeds (X, YouTube): allow the accessibility service with hidden-display refreshes, and/or Frida unpinning on
  the phone? Both carry account/ToS risk the user owns.
- **D4** Keep the pixel tile as a fallback beside the native-card island, or replace it once data mode works?
- **D5** Health history: how long `local.health` keeps samples (all, or N days)?

# tools/app-api — capability spec + capture → OpenAPI prototype

The PowOS "app → API" pipeline. Full design, the capability-spec model, the
safety classes, the threat model and the "enable an app" flow:
[`docs/APP-API-CAPTURE.md`](../../docs/APP-API-CAPTURE.md).

## The capability spec (the core)

One app-independent file per app — `*.appcap.json` — from which every consumer
(AI tools, CLI, typed SDK, widget bindings) is generated, all enforcing the same
safety class (`read` / `reversible-write` / `spend`). See §1b of the doc.

- `schema/appcap.schema.json` — the JSON Schema.
- `appcap_validate.py` — enforces the safety invariants S1–S9. `--list` prints
  the action/safety table. A spec that fails is refused before any consumer is
  built.
- `appcap_render.py` — **view the resulting API**: `--api` (Markdown reference),
  `--tools` (MCP/PowOS-AI tool list), `--cli`, `--widgets`, and
  `--call <action> --arg k=v` to **dry-run preview** a request (it never sends,
  so it's safe to run against any app, lights included).
- `examples/hue.appcap.json` — full worked example (reads, reversible writes, a
  UI-navigation action). `appcap_render.py examples/hue.appcap.json --api`.
- `viewer/index.html` — standalone visual viewer (the toggle/view surface).
  Open it, or drop any `*.appcap.json` onto it.

```bash
python3 appcap_validate.py --list examples/hue.appcap.json
python3 appcap_render.py examples/hue.appcap.json --api --tools --widgets
python3 appcap_render.py examples/hue.appcap.json --call set_room --arg group_id=X --arg on=true   # preview, never sends
```

Auth is never handled by us in the clear: `auth.tokens.*.store` is a handle
(`secret:hue`, `store:<app>:session`) into the encrypted store; captured actions
replay the app's own headers verbatim; the value is never in the spec, logs,
tool output or git.

## "+ add app": drafts (`appcap_add.py`)

The App API app's "+ add app" makes a **draft**: `<state>/drafts/<app>.appcap.json`, never in `specs/`, so no
consumer sees it; it is only ever previewed (`/call` with `draft:true` = `appcap_run.py --draft`, a dry run past the
allowlist that can't send). "Add to my apps" (`POST /draft/add`) moves it into `specs/` with the whole app off.
Three sources, one `normalize()` (app off, reads on, writes off + unpromoted, origin `drafted`, spend confirmed,
auth only as `store:<app>:session` / `secret:<app>` handles, credentials in URLs/bodies made `{placeholders}`), then
`appcap_validate` before anything is written:

- **describe**: PowOS AI gets a ready prompt (the shell's `host.askAssistant`) and runs
  `appcap_add.py put --source describe FILE` - the model never runs in this runtime (its memory budget is 48 MB);
- **an installed app**: a PowOS app's page (`app://<id>`) + its own database's public tables (SQL reads) and
  reducers (writes, off); an Android app's exported VIEW/BROWSABLE deep links (the bridge's `apps.links`, read from
  its manifest, nothing fired) as UI reads, plus its home-screen widgets (AppWidgetProviders: label, class, sizes,
  resize, preview, update period, configure activity) kept as `spec.android.widgets`, shown on the detail page and
  offered as widget-able `widget_*` read actions;
- **import**: an OpenAPI document (`openapi2appcap.convert`) or a capability spec, from a URL (fetched here, no
  credentials accepted) or a file; `{"sample": "open-meteo"}` imports `sample/open-meteo.openapi.json`.

Switching a `captured`/`drafted` write on in App API (`/enable`) promotes it (S3). Tests:
`test/tier1/test-appcap-add.py`.

## Capture → OpenAPI (the capture step)

## Files

- `har2openapi.py` — HAR → OpenAPI 3.1. Stdlib only, no network, never writes a
  secret. Templates volatile path ids (`/cart/88f3…/items` → `/cart/{id}/items`),
  infers request/response JSON Schemas by merging samples (missing-in-any-sample
  → optional), records query params, detects the auth scheme (Bearer / cookie /
  api-key) as a `securityScheme` without the value, and tags every non-GET
  operation `x-powos-mutation: true` so the tool generator can gate it behind a
  confirmation.
- `capture-demo.sh` — zero-risk end-to-end demo: captures reads from Open-Meteo
  (free, public, no auth, no account, no spend) into a HAR, then runs the
  converter.
- `sample/open-meteo.har`, `sample/open-meteo.openapi.json` — committed output of
  the demo so it is reproducible offline.

## Run

```bash
./capture-demo.sh                     # live capture + spec to stdout
python3 har2openapi.py capture.har -o api.json --title "My App"
python3 har2openapi.py capture.har --stats          # summary, writes nothing
python3 har2openapi.py capture.har --host api.x.com  # one host only
```

Feed it a HAR from mitmproxy, HTTP Toolkit, reqable or Chrome DevTools — the HAR
format is the shared interchange, so the converter never has to know how the
capture was done.

## Secret safety

`Authorization`, `Cookie`, `Set-Cookie`, `x-api-key` and any header/param name
matching the secret pattern never have their value copied out. Bodies are
schema-inferred, not embedded, so a token field becomes `{"type":"string"}` with
no example. Verified: a synthetic HAR with a Bearer token, a session cookie, a
`session=` query value and a `token` response field produces a spec containing
none of those values.

Captures themselves (the `.har`) DO contain live tokens — treat them like the
secrets they are: keep them out of git (see the `docs/APP-API-CAPTURE.md` token
store), never paste them into chat.

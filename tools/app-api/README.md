# tools/app-api — capture → OpenAPI prototype

The capture → spec step of the PowOS "app → API" pipeline. Full design,
threat model and the "enable an app" flow: [`docs/APP-API-CAPTURE.md`](../../docs/APP-API-CAPTURE.md).

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

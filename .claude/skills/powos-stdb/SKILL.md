---
name: powos-stdb
description: Use for the PowOS phone's SpacetimeDB - its modules and databases, the shell's vendored bindings (shell/vendor/<db>.js), shell/apps/stdb.ts, decode errors on home, tools/phone/bindings-check.sh, apps/vendor.sh and publishing a module.
---

# The phone's SpacetimeDB

## What runs
- One server per device: `spacetimedb-standalone` 2.12.0 at 127.0.0.1:3410 (unit dev.powos.spacetimedb, data
  /var/lib/powos/stdb). Its port is locked to the PowOS app's uid; root inside PowOS reaches it too. The client SDK
  is vendored at the same version (shell/vendor/spacetimedb.js); bump both together (targets/android/pkgs/spacetimedb-bin).
- Every PowOS app is a database. The shell vendors three (shell/vendor/VERSIONS, the "generated" lines = the list
  every tool reads):
  | vendor file | database | source | shell users |
  |---|---|---|---|
  | local-pet.js | local-pet | apps/pet | ui/pet.tsx (pet, said) |
  | powos-agents.js | powos-agents | apps/agents (no UI: bindings in out/bindings) | ui/pet.tsx, ui/powai.tsx (work), ui/units.tsx (unit) |
  | powos-registry.js | powos-registry | apps/registry (no powos-app.json; published by lib/apps/powos-app) | apps/registry.ts (app, widget) |
- Apps' islands (local-lights, local-shopping, ...) bring their own bindings in their UI (`powos app build`), not vendored.
- Live schema: `curl http://127.0.0.1:3410/v1/database/<db>/schema?version=9` (tables[].name,
  typespace.types[product_type_ref].Product.elements[].name.some). Installed apps: /home/powos/.local/share/powos/apps/<id>/current.

## Decode-error signature
`rejection (vendor/spacetimedb.js:19): Offset is outside the bounds of the DataView` in shell-errors.log (home) means
a table's bindings have more columns than the server's rows (BSATN is positional). On 2026-10-21 this happened twice:
local-pet's `overlay` and then the `goto_*` columns were added to the bindings but the module was never published.
It recurs on every page load, because the initial subscription fails. It is not a power-loss or reconnect fault.

## The guard (shell/apps/stdb.ts)
- The builder's public `dbConnectionCtor` is wrapped so `createWSFn` returns a socket whose onmessage runs in a try. A throw
  goes to `undecodable()`. It drops that connection, fetches the server schema, and compares it with
  `builder().remoteModule.tables` (column = columnMetadata.name ?? key). It then reports
  `stdb: <db>: a message didn't decode (...) - bindings stale for <table> (bindings: ...; server: ...): not subscribed`
  via `__powosBoot.report` (shell-errors), sets `stale`, and reconnects in 3 s. useRows/watchRows skip stale tables.
- Stale lasts until the entry is dropped (page hidden 5 s). A replaced connection's callbacks are ignored (`mine(c)`).

## bindings-check (tools/phone/bindings-check.sh + .mjs)
- Run by shell/push.sh --vpn (schemas read in its one phone call) and ship-apk (after the install). Standalone it makes one
  adb call. `--remote-cmd` prints the phone-side command.
- The bindings checked are the ones the phone runs: the pushed files, then overrides, then the installed APK's shell, then shell/vendor.
- Per database: `ok`; `absent` (not checked); `ahead` (the bindings add tables or trailing columns): if
  apps/<app>/powos-app.json + module exist and `apps/vendor.sh <app> --out tmp` is byte-identical to the bindings, publish
  (`apps/install.sh <app> publish`); else refuse with the fix. `differs` (any other shape, e.g. the phone's module is newer):
  refuse, never publish. `--no-publish` refuses on ahead too. Test hooks: BINDINGS_ADB / BINDINGS_VENDOR / BINDINGS_PUBLISH.

## Commands
- Regenerate bindings: `apps/vendor.sh <app>` (apps/build.sh in the rust container, then esbuild of the bindings'
  index.ts, spacetimedb external). It reproduces the committed files byte for byte. Commit them, then push `vendor/<db>.js`.
- Publish a module: `ADB="docker exec powos-vadb adb" apps/install.sh <app> publish --note "plain words"` (a hot swap;
  additive columns need `#[default(...)]`).
- Check: `tools/phone/bindings-check.sh --no-publish`; tier-1: `bash test/tier1/test-bindings-check.sh`.
- Row peek on the phone (root.sh script): `curl -s -X POST -d "SELECT * FROM pet" http://127.0.0.1:3410/v1/database/local-pet/sql`.
- Inside PowOS, avoid `journalctl` and `/logs` endpoints in root.sh scripts; they hung for minutes.

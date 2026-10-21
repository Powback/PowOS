// The tables of the shell's vendored bindings (shell/vendor/<db>.js) against a module schema the server reports
// (GET /v1/database/<db>/schema?version=9): one line per database -
//   <db> ok | <db> ahead <what> (the bindings add tables/columns at the end: publishing the module fixes it) |
//   <db> differs <what> (anything else: the bindings are older or another shape) | <db> absent (no such database)
// node tools/phone/bindings-check.mjs SDK SCHEMAS <db>=<vendor.js>...   SDK: shell/vendor/spacetimedb.js; SCHEMAS: "@@<db>"
// lines, each followed by its JSON.
// Run by tools/phone/bindings-check.sh.
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

const [sdk, schemasFile, ...pairs] = process.argv.slice(2);
const schemas = {};
let cur = null;
for (const line of readFileSync(schemasFile, "utf8").split("\n")) {
  if (line.startsWith("@@")) cur = line.slice(2).trim();
  else if (cur && line.trim()) schemas[cur] = (schemas[cur] ?? "") + line;
}
const live = (db) => {
  try {
    const s = JSON.parse(schemas[db]);
    return Object.fromEntries(s.tables.map((t) => [t.name, s.typespace.types[t.product_type_ref].Product.elements.map((c) => c.name.some)]));
  } catch {
    return null;
  }
};
const tmp = mkdtempSync(join(tmpdir(), "bindings-check-"));
// The bundles import "spacetimedb" (the shell's import map): here the SDK, by path.
copyFileSync(sdk, join(tmp, "spacetimedb.js"));
try {
  for (const pair of pairs) {
    const [db, file] = pair.split("=");
    const f = join(tmp, basename(file).replace(/\.js$/, ".mjs"));
    writeFileSync(f, readFileSync(file, "utf8").replace(/from"spacetimedb"/g, 'from"./spacetimedb.js"'));
    const { DbConnection } = await import(f);
    const mine = Object.fromEntries(
      Object.values(DbConnection.builder().remoteModule.tables).map((t) => [
        t.sourceName,
        Object.entries(t.columns).map(([k, c]) => c.columnMetadata?.name ?? k),
      ]),
    );
    const server = live(db);
    if (!server) {
      console.log(`${db} absent`);
      continue;
    }
    const diff = [];
    let additive = true;
    for (const [t, cols] of Object.entries(mine)) {
      const have = server[t];
      if (have && have.join() === cols.join()) continue;
      if (!have) diff.push(`table ${t} (${cols.join(", ")}) not on the phone`);
      else if (cols.slice(0, have.length).join() === have.join()) diff.push(`${t}: + ${cols.slice(have.length).join(", ")}`);
      else {
        additive = false;
        diff.push(`${t}: bindings ${cols.join(", ")}; phone ${have.join(", ")}`);
      }
    }
    console.log(diff.length ? `${db} ${additive ? "ahead" : "differs"} ${diff.join("; ")}` : `${db} ok`);
  }
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

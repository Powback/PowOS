#!/usr/bin/env node
// The import-cycle lint: a module in a cycle can be evaluated before its dependency finished, so an
// imported function is still undefined at its top level ("Cannot read properties of undefined (reading
// 'call')" at line 1 of recents.tsx, 2026-10-28). Walks the static value imports (not `import type`, not
// dynamic import()) of shell/*.ts(x) + shell/ui, apps/ etc., prints every cycle, and fails on any cycle
// not listed in dev/cycles-allow.txt (one cycle per line, its modules sorted and joined by " ").
// Usage: lint-cycles.mjs [shell dir]   (default: this script's ../)
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, dirname, relative, resolve } from "node:path";
const root = resolve(process.argv[2] || join(dirname(new URL(import.meta.url).pathname), ".."));
const skip = new Set(["node_modules", "dev", "dist", "out", "test", "tests"]);
const files = [];
(function walk(d) { for (const n of readdirSync(d)) { const p = join(d, n);
  if (statSync(p).isDirectory()) { if (!skip.has(n) && !n.startsWith(".")) walk(p); }
  else if (/\.tsx?$/.test(n) && !/\.d\.ts$|\.test\.tsx?$/.test(n)) files.push(p); } })(root);
const re = /^\s*(?:import|export)\s+(?!type\b)(?:[^"';]*?\sfrom\s+)?["'](\.[^"']+)["']/gm;
const graph = new Map(files.map((f) => { const deps = [];
  for (const m of readFileSync(f, "utf8").matchAll(re)) { const t = resolve(dirname(f), m[1]);
    const hit = [t, t + ".ts", t + ".tsx", join(t, "index.ts")].find((c) => existsSync(c) && statSync(c).isFile());
    if (hit && /\.tsx?$/.test(hit)) deps.push(hit); }
  return [f, deps]; }));
// Tarjan's strongly connected components: each component of 2+ modules (or a self-import) is a cycle.
let idx = 0; const st = [], on = new Set(), ix = new Map(), low = new Map(), sccs = [];
function sc(v) { ix.set(v, idx); low.set(v, idx++); st.push(v); on.add(v);
  for (const w of graph.get(v) || []) { if (!ix.has(w)) { sc(w); low.set(v, Math.min(low.get(v), low.get(w))); }
    else if (on.has(w)) low.set(v, Math.min(low.get(v), ix.get(w))); }
  if (low.get(v) === ix.get(v)) { const c = []; let w; do { w = st.pop(); on.delete(w); c.push(w); } while (w !== v);
    if (c.length > 1 || (graph.get(v) || []).includes(v)) sccs.push(c.map((f) => relative(root, f)).sort().join(" ")); } }
for (const f of files) if (!ix.has(f)) sc(f);
const allowFile = join(dirname(new URL(import.meta.url).pathname), "cycles-allow.txt");
const allow = new Set(existsSync(allowFile) ? readFileSync(allowFile, "utf8").split("\n").map((l) => l.replace(/#.*/, "").trim()).filter(Boolean) : []);
const fresh = sccs.filter((c) => !allow.has(c));
if (process.argv.includes("--list")) { for (const c of sccs) console.log(c); process.exit(0); }
for (const c of fresh) console.log(`cycle lint: new import cycle: ${c}`);
console.log(`     cycle lint: ${sccs.length} cycle(s), ${sccs.length - fresh.length} allow-listed, ${fresh.length} new`);
process.exit(fresh.length ? 1 : 0);

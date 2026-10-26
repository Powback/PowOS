// trace.ts [secs=10] (in powos-vadb, like devperf.ts): a WebView trace over the window, broken down by WHAT draws -
// Paint events by the DOM node they paint (resolved via DOM.describeNode), raster / image-decode tasks by name, and
// the busiest events of every thread. Read-only (tracing and DOM reads). drag-raster.sh's TRACE=1 runs it per drag.
const secs = Number(process.argv[2] ?? 10);
const pages = await (await fetch("http://127.0.0.1:9333/json")).json();
const p = pages.find((x: any) => x.type === "page" && x.url.endsWith("/index.html"));
if (!p) { console.log("no home page"); process.exit(1); }
const ws = new WebSocket(p.webSocketDebuggerUrl);
let id = 0; const wait = new Map<number, (v: any) => void>(); const trace: any[] = []; let done!: () => void;
const ended = new Promise<void>((r) => (done = r));
const call = (method: string, params: any = {}) => new Promise<any>((res) => { const i = ++id; wait.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
ws.onmessage = (m) => {
  const d = JSON.parse(String(m.data));
  if (d.id && wait.has(d.id)) { wait.get(d.id)!(d.result ?? d.error); wait.delete(d.id); }
  if (d.method === "Tracing.dataCollected") trace.push(...d.params.value);
  if (d.method === "Tracing.tracingComplete") done();
};
await new Promise((r) => (ws.onopen = r));
await call("DOM.enable");
await call("DOM.getDocument", { depth: 0 });
await call("Tracing.start", { categories: "cc,viz,gpu,blink,devtools.timeline,disabled-by-default-devtools.timeline,toplevel,disabled-by-default-devtools.timeline.frame", transferMode: "ReportEvents" });
await new Promise((r) => setTimeout(r, secs * 1000));
await call("Tracing.end");
await Promise.race([ended, new Promise((r) => setTimeout(r, 10000))]);
const threads = new Map<string, string>();
for (const e of trace) if (e.name === "thread_name") threads.set(`${e.pid}:${e.tid}`, e.args?.name);
const paints = new Map<string, { n: number; ms: number; area: number }>();
// A frame id is its page's target id (the main frame): which page painted.
const pageOf = new Map<string, string>(pages.map((x: any) => [x.id, (x.url.match(/mode=(\w+)/)?.[1] ?? "home")]));
const tasks = new Map<string, { n: number; ms: number }>();
for (const e of trace) {
  if (e.name === "Paint" && e.args?.data) {
    const k = `${pageOf.get(e.args.data.frame) ?? e.args.data.frame ?? "?"}|${e.args.data.nodeId ?? -1}`;
    const a = paints.get(k) ?? { n: 0, ms: 0, area: 0 };
    const c = e.args.data.clip ?? [];
    a.n++; a.ms += (e.dur ?? 0) / 1000; a.area += c.length >= 8 ? Math.abs((c[2] - c[0]) * (c[5] - c[1])) : 0;
    paints.set(k, a);
  }
  if (e.name === "FunctionCall" && e.ph === "X" && e.args?.data) {
    const d = e.args.data;
    const k = `script ${String(d.url ?? "").replace(/^.*\/\/[^/]+\//, "")}:${d.lineNumber ?? "?"} ${d.functionName || "(anon)"}`;
    const a = tasks.get(k) ?? { n: 0, ms: 0 };
    a.n++; a.ms += (e.dur ?? 0) / 1000; tasks.set(k, a);
  }
  if (/Raster|Decode|PaintImage|TileManager|DrawLayers|PrepareToDraw|Composite/i.test(e.name) && (e.ph === "X" || e.ph === "B")) {
    const k = `${threads.get(`${e.pid}:${e.tid}`) ?? e.tid} ${e.name}`;
    const a = tasks.get(k) ?? { n: 0, ms: 0 };
    a.n++; a.ms += (e.dur ?? 0) / 1000; tasks.set(k, a);
  }
}
const name = async (key: string) => {
  const [page, idText] = key.split("|");
  const backendNodeId = Number(idText);
  if (backendNodeId < 0) return `[${page}] ?`;
  const r = await call("DOM.describeNode", { backendNodeId });
  const n = r?.node; if (!n) return `[${page}] #${backendNodeId}`;
  const at = n.attributes ?? []; const cls = at[at.indexOf("class") + 1];
  return `[${page}] ${n.nodeName.toLowerCase()}${at.includes("class") && cls ? "." + cls.trim().split(/\s+/).join(".") : ""}`;
};
console.log(`${trace.length} events in ${secs}s. Paint by node (per second: count, ms, Mpx):`);
for (const [k, v] of [...paints].sort((a, b) => b[1].ms - a[1].ms).slice(0, 12))
  console.log(`${(v.n / secs).toFixed(1).padStart(7)}/s ${(v.ms / secs).toFixed(1).padStart(6)} ms/s ${(v.area / secs / 1e6).toFixed(2).padStart(6)} Mpx/s  ${await name(k)}`);
console.log("script (FunctionCall by url:line function) and raster / decode / draw tasks (per second):");
for (const [k, v] of [...tasks].sort((a, b) => b[1].ms - a[1].ms).slice(0, 24))
  console.log(`${(v.n / secs).toFixed(1).padStart(7)}/s ${(v.ms / secs).toFixed(1).padStart(7)} ms/s  ${k}`);
process.exit(0);

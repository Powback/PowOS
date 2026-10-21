// devperf.ts <file.js> (device.sh runs it in powos-vadb): Chromium metrics in the phone's home page - 3 s at rest, then
// around the evaluated probe. Nothing but the probe touches the page.
const expr = await Bun.file(process.argv[2]).text();
const pages = await (await fetch("http://127.0.0.1:9333/json")).json();
const p = pages.find((x: any) => x.type === "page" && x.url.endsWith("/index.html"));
if (!p) { console.log("no home page", pages.map((x: any) => x.url)); process.exit(1); }
const ws = new WebSocket(p.webSocketDebuggerUrl);
let id = 0; const wait = new Map<number, (v: any) => void>();
const call = (method: string, params: any = {}) => new Promise<any>((res) => { const i = ++id; wait.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
ws.onmessage = (m) => { const d = JSON.parse(String(m.data)); if (d.id && wait.has(d.id)) { wait.get(d.id)!(d.result ?? d.error); wait.delete(d.id); } };
await new Promise((r) => (ws.onopen = r));
await call("Performance.enable");
const m = async () => Object.fromEntries((await call("Performance.getMetrics")).metrics.map((x: any) => [x.name, x.value]));
const keys = ["LayoutCount", "RecalcStyleCount", "LayoutDuration", "RecalcStyleDuration", "ScriptDuration", "TaskDuration"];
const d = (a: any, b: any) => Object.fromEntries(keys.map((k) => [k, Math.round((b[k] - a[k]) * (k.endsWith("Duration") ? 1000 : 1) * 10) / 10]));
const r0 = await m(); await new Promise((r) => setTimeout(r, 3000)); const r1 = await m();
const before = await m();
const r = await call("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
const after = await m();
console.log(JSON.stringify({ atRest3s: d(r0, r1), drag: r?.result?.value ?? r, dragMetrics: d(before, after) }));
process.exit(0);

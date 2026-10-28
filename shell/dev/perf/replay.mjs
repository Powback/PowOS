/**
 * Replays an FPS-meter recording (shell/ui/fpsmeter.tsx + perfrec.ts) and traces it: replay.sh runs it.
 *   MODE=gate: the gate's headless Chromium (inside the gate image; /shell = the shell, /rec.json, /out), the mock
 *     bridge seeded from the recording's snapshot (stored settings, store keys, home layout, dock), at its viewport+dpr.
 *   MODE=emu: the emulator's live home page over CDP (CDP=http://127.0.0.1:9334, forwarded by tools/phone/cdp.sh),
 *     viewport emulated to the recording's, stored settings + store keys seeded and the page reloaded. The emulator's
 *     own home layout stays (the host owns it).
 * Then the recorded inputs at their original times (Input.dispatchTouchEvent / dispatchMouseEvent / dispatchKeyEvent)
 * under a Tracing session (devtools.timeline, blink, ...). Out: OUT/replay-trace.json (Perfetto / DevTools), and on
 * stdout each long frame (long-animation-frame >= 50 ms) with its main-thread split: script, style, layout, paint, gc.
 * A recording without `home` (older shells) has no inputs or snapshot: the shell idles for the recorded duration.
 */
import fs from "node:fs";
import path from "node:path";

const MODE = process.env.MODE ?? "gate", OUT = process.env.OUT ?? "/out", REC = process.env.REC ?? "/rec.json", ROOT = process.env.ROOT ?? "/shell";
const ORIGIN = "https://shell.powos";
const rec = JSON.parse(fs.readFileSync(REC, "utf8"));
const d = rec.home && typeof rec.home === "object" ? rec.home : null;
const snap = d?.snapshot ?? {};
const vp = snap.viewport ?? { w: 404, h: 899, dpr: Number(rec.dpr) || 2.7625 };
const inputs = (d?.inputs ?? []).slice().sort((a, b) => a[0] - b[0]);
const durMs = Math.min(130_000, Math.max(d?.durationMs ?? rec.summary?.durationMs ?? 10_000, (inputs.at(-1)?.[0] ?? 0) + 1500));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
if (!d) console.log(`recording has no home detail (older shell): no inputs, no snapshot - idle replay of ${Math.round(durMs / 1000)} s at ${vp.w}x${vp.h} dpr ${vp.dpr}`);
else console.log(`replaying ${inputs.length} inputs, ${d.state?.length ?? 0} state changes over ${Math.round(durMs / 1000)} s at ${vp.w}x${vp.h} dpr ${vp.dpr} (mode ${snap.mode ?? "home"})`);

// --- a CDP session: puppeteer's (gate) or a bare WebSocket (emu) ---
let send, on, page, browser;
const handlers = new Map();
const MIME = { html: "text/html", js: "text/javascript", mjs: "text/javascript", css: "text/css", json: "application/json", svg: "image/svg+xml",
  png: "image/png", jpg: "image/jpeg", webp: "image/webp", wasm: "application/wasm", woff2: "font/woff2", ttf: "font/ttf" };
/** The shell file a same-origin request path maps to, or null (outside ROOT, missing, not a file). */
function shellFile(p) {
  if ((p === "fonts/nerd_symbols.ttf" || p === "_font/symbols") && fs.existsSync("/fonts/nerd_symbols.ttf")) return "/fonts/nerd_symbols.ttf";
  const f = p.split("/").includes("..") ? null : path.join(ROOT, p);
  return f && fs.existsSync(f) && fs.statSync(f).isFile() ? f : null;
}
/** Gate mode: the shell is served from ROOT by request interception; data:/blob: pass, anything else off-origin is aborted. */
function serveRequest(req) {
  const url = req.url();
  if (!url.startsWith(ORIGIN + "/")) return url.startsWith("data:") || url.startsWith("blob:") ? req.continue() : req.abort();
  const f = shellFile(decodeURIComponent(new URL(url).pathname).replace(/^\/+/, "") || "index.html");
  if (!f) return req.respond({ status: 404, contentType: "text/plain", body: "" });
  const type = MIME[f.slice(f.lastIndexOf(".") + 1)] ?? "text/plain";
  req.respond({ status: 200, contentType: type, body: fs.readFileSync(f), headers: { "Cache-Control": "no-store" } });
}
if (MODE === "gate") {
  const { default: puppeteer } = await import("puppeteer");
  browser = await puppeteer.launch({ executablePath: process.env.CHROME || "/usr/bin/chromium-browser", headless: true,
    args: ["--no-sandbox", "--disable-dev-shm-usage", "--no-first-run", "--mute-audio", "--font-render-hinting=none"], protocolTimeout: 180_000 });
  page = await browser.newPage();
  await page.setViewport({ width: vp.w, height: vp.h, deviceScaleFactor: vp.dpr, hasTouch: true, isMobile: true });
  page.on("pageerror", (e) => console.log("page error:", e.message.split("\n")[0]));
  await page.setRequestInterception(true);
  page.on("request", serveRequest);
  // The mock bridge's storage (bridge.ts mock(): store = localStorage "powos-shell:<key>", the home kept by mock.keepHome).
  await page.evaluateOnNewDocument((snap) => {
    try {
      for (const [k, v] of Object.entries(snap.stored ?? {})) localStorage.setItem(k, v);
      for (const [k, v] of Object.entries(snap.store ?? {})) if (v != null) localStorage.setItem(`powos-shell:${k}`, JSON.stringify(v));
      if (snap.dock) localStorage.setItem("powos-shell:dock", JSON.stringify(snap.dock));
      if (snap.home) { localStorage.setItem("powos-shell:mock.home", JSON.stringify(snap.home)); localStorage.setItem("powos-shell:mock.keepHome", "1"); }
    } catch {}
  }, snap);
  const cdp = await page.createCDPSession();
  send = (m, p = {}) => cdp.send(m, p);
  on = (ev, f) => cdp.on(ev, f);
  await page.goto(`${ORIGIN}/index.html${snap.url ?? ""}`, { waitUntil: "domcontentloaded" });
} else {
  const base = process.env.CDP ?? "http://127.0.0.1:9334";
  const pages = await (await fetch(`${base}/json`)).json();
  const want = snap.mode && snap.mode !== "home" ? `mode=${snap.mode}` : null;
  const target = pages.find((x) => x.type === "page" && (want ? x.url.includes(want) : /\/index\.html(\?|$)/.test(x.url) && !x.url.includes("mode=")));
  if (!target) { console.log(`no ${snap.mode ?? "home"} page on the emulator`); process.exit(1); }
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  let id = 0; const wait = new Map();
  ws.onmessage = (m) => {
    const x = JSON.parse(String(m.data));
    if (x.id && wait.has(x.id)) { const [res, rej] = wait.get(x.id); wait.delete(x.id); x.error ? rej(new Error(x.error.message)) : res(x.result); }
    else if (x.method) for (const f of handlers.get(x.method) ?? []) f(x.params);
  };
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; wait.set(i, [res, rej]); ws.send(JSON.stringify({ id: i, method, params })); });
  on = (ev, f) => handlers.set(ev, [...(handlers.get(ev) ?? []), f]);
  await send("Emulation.setDeviceMetricsOverride", { width: vp.w, height: vp.h, deviceScaleFactor: vp.dpr, mobile: true });
  await send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 });
  const seed = `(async () => { const S = ${JSON.stringify({ stored: snap.stored ?? {}, store: snap.store ?? {}, dock: snap.dock })};
    for (const [k, v] of Object.entries(S.stored)) localStorage.setItem(k, v);
    const { powos } = await (window.importShim ?? ((p) => import(p)))("./bridge.ts");
    for (const [k, v] of Object.entries(S.store)) if (v != null) await powos.store.set(k, v);
    if (S.dock) await powos.store.set("dock", S.dock); return true; })()`;
  if (d) { await send("Runtime.evaluate", { expression: seed, awaitPromise: true }); await send("Page.reload", {}); await sleep(1000); }
  console.log("emulator: home layout is the emulator's own (the host owns it); stored settings and store keys seeded");
}
const evaluate = async (expression) => (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result?.value;
for (let i = 0; i < 100 && !(await evaluate("window.__powosAlive === true").catch(() => false)); i++) await sleep(100);

// The recorded look and state: theme tokens, the shell's signals at the start.
await evaluate(`(async () => {
  const s = ${JSON.stringify({ css: snap.css ?? {}, state: snap.state ?? {} })};
  for (const [k, v] of Object.entries(s.css)) document.documentElement.style.setProperty(k, v);
  const S = await (window.importShim ?? ((p) => import(p)))("./state.ts");
  for (const k of ["page", "drawer", "pullKind", "notif", "panel", "chatting"]) if (k in s.state && S[k]) S[k].value = s.state[k];
})()`).catch((e) => console.log("seed state:", e.message));
await sleep(1500);

// --- trace + inputs ---
const trace = [];
let traced; const done = new Promise((r) => (traced = r));
on("Tracing.dataCollected", (p) => trace.push(...p.value));
on("Tracing.tracingComplete", () => traced());
await send("Tracing.start", { transferMode: "ReportEvents", categories: ["devtools.timeline", "blink", "blink.user_timing", "toplevel", "v8.execute", "v8",
  "disabled-by-default-devtools.timeline", "disabled-by-default-devtools.timeline.frame", "disabled-by-default-devtools.timeline.stack"].join(",") });
const pageT0 = await evaluate(`(() => { window.__rp = []; try { new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__rp.push({ start: e.startTime, dur: e.duration,
  render: e.renderStart, style: e.styleAndLayoutStart, blocking: e.blockingDuration, scripts: (e.scripts ?? []).map((s) => ({ src: s.sourceURL, fn: s.sourceFunctionName, inv: s.invoker, dur: s.duration, forced: s.forcedStyleAndLayoutDuration })) }); })
  .observe({ type: "long-animation-frame" }); } catch {} performance.mark("replay-t0"); return performance.now(); })()`);
const t0 = performance.now(), touches = new Map();
let mouseDown = false;
const pts = () => [...touches.entries()].map(([id, [x, y]]) => ({ x, y, id, radiusX: 4, radiusY: 4, force: 1 }));
async function sendKey(key, code) {
  await send("Input.dispatchKeyEvent", { type: "keyDown", key, code });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key, code });
}
async function sendMouse(k, x, y) {
  const t = k === "d" ? "mousePressed" : k === "m" ? "mouseMoved" : "mouseReleased";
  if (k === "d") mouseDown = true; else if (k !== "m") mouseDown = false;
  await send("Input.dispatchMouseEvent", { type: t, x, y, button: k === "m" && !mouseDown ? "none" : "left", buttons: mouseDown ? 1 : 0, clickCount: 1 });
}
async function sendTouch(k, x, y, pid) {
  const id = Number(pid) % 16;
  if (k === "m" && !touches.has(id)) return;
  if (k === "d" || k === "m") touches.set(id, [x, y]); else touches.delete(id);
  const type = { d: "touchStart", m: "touchMove", c: "touchCancel" }[k] ?? "touchEnd";
  await send("Input.dispatchTouchEvent", { type, touchPoints: pts() });
}
/** One recorded input [t, kind, x|key, y|code, pointerType, pointerId] through CDP. */
function sendInput([, k, x, y, type, pid]) {
  if (k === "k") return sendKey(x, y);
  return type === "mouse" ? sendMouse(k, x, y) : sendTouch(k, x, y, pid);
}
for (const ev of inputs) {
  const wait = ev[0] - (performance.now() - t0);
  if (wait > 0) await sleep(wait);
  try { await sendInput(ev); } catch (e) { console.log(`input at ${ev[0]} ms: ${e.message}`); }
}
const left = durMs - (performance.now() - t0);
if (left > 0) await sleep(left);
const loafs = (await evaluate("window.__rp")) ?? [];
await send("Tracing.end");
await Promise.race([done, sleep(30_000)]);
if (MODE === "emu") await send("Emulation.clearDeviceMetricsOverride").catch(() => {});
fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(path.join(OUT, "replay-trace.json"), JSON.stringify({ traceEvents: trace }));

// --- the long frames, split by what the main thread did in them ---
const mark = trace.find((e) => e.name === "replay-t0");
const B = { script: /^(FunctionCall|EvaluateScript|v8\.compile|v8\.callFunction|TimerFire|FireAnimationFrame|EventDispatch|RunMicrotasks|v8\.run)$/,
  style: /^(UpdateLayoutTree|RecalculateStyles|ParseAuthorStyleSheet)$/, layout: /^Layout$/,
  paint: /^(Paint|PrePaint|PaintImage|Layerize|UpdateLayer|UpdateLayerTree|CompositeLayers|Commit|RasterTask)$/, gc: /(MinorGC|MajorGC|V8\.GC|BlinkGC)/ };
const main = mark ? trace.filter((e) => e.pid === mark.pid && e.tid === mark.tid && e.ph === "X" && e.dur) : [];
const union = (evs, a, b) => { let sum = 0, end = a; for (const e of evs.sort((x, y) => x.ts - y.ts)) { const s = Math.max(e.ts, end), f = Math.min(e.ts + e.dur, b); if (f > s) { sum += f - s; end = f; } } return Math.round(sum / 100) / 10; };
const long = loafs.filter((l) => l.dur >= 50).sort((a, b) => b.dur - a.dur).slice(0, 15);
console.log(`\nreplayed long frames (>= 50 ms): ${long.length}${mark ? "" : " (no replay-t0 mark in the trace: no split)"}`);
for (const l of long.sort((a, b) => a.start - b.start)) {
  const at = Math.round(l.start - pageT0);
  let split = "";
  if (mark) {
    const a = mark.ts + (l.start - pageT0) * 1000, b = a + l.dur * 1000;
    const inWin = main.filter((e) => e.ts < b && e.ts + e.dur > a);
    split = Object.entries(B).map(([k, re]) => `${k} ${union(inWin.filter((e) => re.test(e.name)), a, b)}`).join(" | ");
    const fns = inWin.filter((e) => e.name === "FunctionCall").sort((x, y) => y.dur - x.dur).slice(0, 2)
      .map((e) => `${String(e.args?.data?.url ?? "").replace(/^.*\/\/[^/]+\//, "")}:${e.args?.data?.lineNumber ?? "?"} ${e.args?.data?.functionName || "(anon)"} ${Math.round(e.dur / 100) / 10}ms`);
    if (fns.length) split += `\n      top calls: ${fns.join("; ")}`;
  }
  console.log(`  at ${at} ms  ${Math.round(l.dur)} ms  ${split}`);
}
const orig = (d?.loaf ?? rec.events ?? []).filter((l) => l.dur >= 50).sort((a, b) => a.start - b.start);
console.log(`\nrecorded long frames (${d ? "home" : "the bar's own window"}): ${orig.map((l) => `${l.start}:${l.dur}ms`).join(" ") || "none"}`);
console.log(`trace: ${path.join(process.env.OUT_HOST ?? OUT, "replay-trace.json")} (${trace.length} events; open in https://ui.perfetto.dev)`);
await browser?.close();
process.exit(0);

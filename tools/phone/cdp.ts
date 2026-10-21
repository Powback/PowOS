// CDP to the PowOS shell's WebView pages (run by tools/phone/cdp.sh inside powos-vadb's network, port 9333 forwarded).
//   pages                      the pages (url, title)
//   eval <suffix> <expr>       evaluate in the page whose url ends with <suffix> ("" = home: the url without ?mode)
//   net [secs=10]               per page: WebSocket frames (by socket URL) and requests per second
//   raster [secs=10]            the busiest renderer/GPU/viz trace events (what draws per frame at rest)
//   idle [secs=20] [suffix]    what every page (or one) does while nothing happens: frames, paints, layouts, style
//                              recalcs, script time, timers and the CSS/Web animations running - from a devtools.timeline
//                              trace and Performance.getMetrics deltas. An idle page should show 0 frames and 0 paints.
// Read-only: nothing is drawn on the phone's screen (no paint flashing overlay).
const [cmd = "pages", a1, a2] = process.argv.slice(2);
const PORT = process.env.CDP_PORT ?? "9333";

type Page = { url: string; title: string; webSocketDebuggerUrl: string; type: string };
const pages: Page[] = (await (await fetch(`http://127.0.0.1:${PORT}/json`)).json()).filter((p: Page) => p.type === "page");
const short = (u: string) => (u.match(/[?&]mode=([^&]+)/)?.[1] ?? (u.includes("index.html") ? "home" : u.slice(-40)));

class Session {
  ws: WebSocket;
  id = 0;
  waits = new Map<number, (v: any) => void>();
  events: ((m: any) => void)[] = [];
  open: Promise<void>;
  constructor(url: string) {
    this.ws = new WebSocket(url);
    this.open = new Promise((r, e) => ((this.ws.onopen = () => r()), (this.ws.onerror = e)));
    this.ws.onmessage = (m) => {
      const d = JSON.parse(String(m.data));
      if (d.id && this.waits.has(d.id)) this.waits.get(d.id)!(d), this.waits.delete(d.id);
      else this.events.forEach((f) => f(d));
    };
  }
  send(method: string, params: object = {}): Promise<any> {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((r) => this.waits.set(id, r));
  }
  async eval(expression: string) {
    const d = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    return d.result?.result?.value ?? d.result?.exceptionDetails?.exception?.description ?? d;
  }
}

const pick = (suffix: string) => pages.filter((p) => (suffix === "" ? short(p.url) === "home" : suffix ? p.url.endsWith(suffix) || short(p.url) === suffix : true));

if (cmd === "pages") {
  for (const p of pages) console.log(short(p.url).padEnd(10), p.url);
  process.exit(0);
}

if (cmd === "eval") {
  const [p] = pick(a1 ?? "");
  if (!p) (console.log("no page", pages.map((x) => x.url)), process.exit(1));
  const s = new Session(p.webSocketDebuggerUrl);
  await s.open;
  console.log(JSON.stringify(await s.eval(a2), null, 1));
  process.exit(0);
}

if (cmd === "idle") {
  const secs = Number(a1 ?? 20);
  const targets = pick(a2 ?? (undefined as any));
  const metric = (m: any[], name: string) => m.find((x) => x.name === name)?.value ?? 0;
  // One trace for the whole WebView (tracing is browser-wide): events are told apart by their frame / layer tree.
  const sessions = await Promise.all(
    targets.map(async (p) => {
      const s = new Session(p.webSocketDebuggerUrl);
      await s.open;
      await s.send("Performance.enable");
      const frame = (await s.send("Page.getFrameTree")).result?.frameTree?.frame?.id;
      return { p, s, frame, before: (await s.send("Performance.getMetrics")).result.metrics };
    }),
  );
  const tracer = new Session(pages[0].webSocketDebuggerUrl);
  await tracer.open;
  const trace: any[] = [];
  let done!: () => void;
  const ended = new Promise<void>((r) => (done = r));
  tracer.events.push((d) => {
    if (d.method === "Tracing.dataCollected") trace.push(...d.params.value);
    if (d.method === "Tracing.tracingComplete") done();
  });
  const traced = await tracer.send("Tracing.start", {
    categories: "devtools.timeline,disabled-by-default-devtools.timeline.frame,disabled-by-default-devtools.timeline,disabled-by-default-devtools.timeline.stack,blink.animations,cc",
    transferMode: "ReportEvents",
  });
  if (traced.error) console.error("no trace:", traced.error.message, "(another devtools client tracing?)");
  await new Promise((r) => setTimeout(r, secs * 1000));
  if (!traced.error) await tracer.send("Tracing.end"), await Promise.race([ended, new Promise((r) => setTimeout(r, 8000))]);
  // layer tree id -> frame (SetLayerTreeId), for the compositor's frames
  const treeOf = new Map<number, string>();
  for (const e of trace) if (e.name === "SetLayerTreeId") treeOf.set(e.args?.data?.layerTreeId, e.args?.data?.frame);
  const frameOf = (e: any) => e.args?.data?.frame ?? e.args?.frame ?? (e.args?.layerTreeId != null ? treeOf.get(e.args.layerTreeId) : undefined) ?? treeOf.get(e.args?.data?.layerTreeId);
  const out = [];
  for (const { p, s, frame, before } of sessions) {
    const after = (await s.send("Performance.getMetrics")).result.metrics;
    const anims = await s.eval(`JSON.stringify(document.getAnimations().filter(a => a.playState === "running").map(a => {
      const t = a.effect && a.effect.target; return (a.animationName || a.transitionProperty || a.constructor.name) + "@" +
      (t ? (t.tagName.toLowerCase() + (t.className && typeof t.className === "string" ? "." + t.className.trim().split(/\\s+/).join(".") : "")) : "?") }))`);
    const mine = trace.filter((e) => frameOf(e) === frame && e.ph !== "E");
    const count = (name: string) => mine.filter((e) => e.name === name).length;
    const d = (n: string) => metric(after, n) - metric(before, n);
    const timers = new Map<string, number>();
    // Who asks for frames and timers: the script location that requested them (the .stack category's stackTrace).
    const askers = new Map<string, number>();
    for (const e of mine) if (e.name === "RequestAnimationFrame" || e.name === "TimerInstall" || e.name === "ScheduleStyleRecalculation" || e.name === "InvalidateLayout") {
      const st = e.args?.data?.stackTrace ?? e.args?.beginData?.stackTrace ?? [];
      const at = st.slice(0, 2).map((f: any) => `${f.functionName || "?"}@${String(f.url).replace(/^.*shell\.powos\//, "")}:${f.lineNumber}`).join(" < ");
      const k = `${e.name} ${at || "(no stack)"}`;
      askers.set(k, (askers.get(k) ?? 0) + 1);
    }
    for (const e of mine) if (e.name === "TimerFire" || e.name === "FireAnimationFrame" || e.name === "Paint") {
      const k = e.name === "Paint" ? `Paint node ${e.args?.data?.nodeId ?? "?"} ${JSON.stringify(e.args?.data?.clip?.slice?.(0, 2) ?? "")}` : `${e.name} ${e.args?.data?.timerId ?? e.args?.data?.id ?? ""}`;
      timers.set(k, (timers.get(k) ?? 0) + 1);
    }
    const per = (n: number) => +(n / secs).toFixed(2);
    out.push({
      page: short(p.url),
      hidden: await s.eval("document.hidden"),
      perSec: {
        compositorFrames: per(count("DrawFrame")),
        beginFrames: per(count("BeginFrame") + count("BeginMainThreadFrame")),
        paints: per(count("Paint")),
        rAF: per(count("FireAnimationFrame")),
        timers: per(count("TimerFire")),
        layouts: per(d("LayoutCount")),
        styleRecalcs: per(d("RecalcStyleCount")),
        scriptMs: per(d("ScriptDuration") * 1000),
      },
      busiest: [...timers].sort((a, b) => b[1] - a[1]).slice(0, 6),
      askers: [...askers].sort((a, b) => b[1] - a[1]).slice(0, 8),
      runningAnimations: JSON.parse(anims || "[]"),
    });
  }
  const unattributed = trace.filter((e) => ["DrawFrame", "BeginFrame", "Paint", "FireAnimationFrame", "TimerFire"].includes(e.name) && e.ph !== "E" && !sessions.some((x) => x.frame === frameOf(e)));
  const un = new Map<string, number>();
  for (const e of unattributed) un.set(e.name, (un.get(e.name) ?? 0) + 1);
  console.log(JSON.stringify({ secs, traceEvents: trace.length, pages: out, unattributedPerSec: Object.fromEntries([...un].map(([k, v]) => [k, +(v / secs).toFixed(2)])) }, null, 1));
  process.exit(0);
}
if (cmd === "net") {
  // net [secs=10]: per page, the network traffic it makes - WebSocket frames (by URL) and requests - observed through
  // the Network domain over the window. Read-only.
  const secs = Number(a1 ?? 10);
  const out = await Promise.all(
    pages.map(async (p) => {
      const s = new Session(p.webSocketDebuggerUrl);
      await s.open;
      const sockets = new Map<string, string>();
      const frames = new Map<string, { rx: number; tx: number; bytes: number }>();
      const reqs = new Map<string, number>();
      s.events.push((d) => {
        const m = d.method, q = d.params;
        if (m === "Network.webSocketCreated") sockets.set(q.requestId, q.url.replace(/[?].*/, ""));
        if (m === "Network.webSocketFrameReceived" || m === "Network.webSocketFrameSent") {
          const k = sockets.get(q.requestId) ?? q.requestId;
          const f = frames.get(k) ?? { rx: 0, tx: 0, bytes: 0 };
          m.endsWith("Received") ? f.rx++ : f.tx++;
          f.bytes += q.response?.payloadData?.length ?? 0;
          frames.set(k, f);
        }
        if (m === "Network.requestWillBeSent") {
          const k = q.request.url.replace(/[?].*/, "").slice(0, 90);
          reqs.set(k, (reqs.get(k) ?? 0) + 1);
        }
      });
      await s.send("Network.enable");
      await new Promise((r) => setTimeout(r, secs * 1000));
      await s.send("Network.disable");
      const per = (n: number) => +(n / secs).toFixed(2);
      return {
        page: short(p.url),
        wsFramesPerSec: Object.fromEntries([...frames].map(([k, v]) => [k, { rx: per(v.rx), tx: per(v.tx), bytesPerSec: per(v.bytes) }])),
        requestsPerSec: Object.fromEntries([...reqs].sort((a, b) => b[1] - a[1]).slice(0, 8).map(([k, v]) => [k, per(v)])),
      };
    }),
  );
  console.log(JSON.stringify(out.filter((o) => Object.keys(o.wsFramesPerSec).length || Object.keys(o.requestsPerSec).length), null, 1));
  process.exit(0);
}
if (cmd === "raster") {
  // raster [secs=10]: the busiest trace events of the whole WebView (renderer + GPU/viz threads) over the window, by
  // name and thread, with their total duration - what rasterizes or composites per frame at rest. Read-only.
  const secs = Number(a1 ?? 10);
  const tracer = new Session(pages[0].webSocketDebuggerUrl);
  await tracer.open;
  const trace: any[] = [];
  let done!: () => void;
  const ended = new Promise<void>((r) => (done = r));
  tracer.events.push((d) => {
    if (d.method === "Tracing.dataCollected") trace.push(...d.params.value);
    if (d.method === "Tracing.tracingComplete") done();
  });
  const r = await tracer.send("Tracing.start", {
    categories: "cc,viz,gpu,blink,devtools.timeline,disabled-by-default-devtools.timeline,disabled-by-default-devtools.timeline.frame,toplevel",
    transferMode: "ReportEvents",
  });
  if (r.error) (console.log("no trace:", r.error.message), process.exit(1));
  await new Promise((res) => setTimeout(res, secs * 1000));
  await tracer.send("Tracing.end");
  await Promise.race([ended, new Promise((res) => setTimeout(res, 10000))]);
  const threads = new Map<string, string>();
  for (const e of trace) if (e.name === "thread_name") threads.set(`${e.pid}:${e.tid}`, e.args?.name);
  const agg = new Map<string, { n: number; ms: number }>();
  for (const e of trace) {
    if (e.ph !== "X" && e.ph !== "B" && e.ph !== "I" && e.ph !== "i") continue;
    const k = `${threads.get(`${e.pid}:${e.tid}`) ?? e.tid} ${e.name}`;
    const a = agg.get(k) ?? { n: 0, ms: 0 };
    a.n++;
    a.ms += (e.dur ?? 0) / 1000;
    agg.set(k, a);
  }
  const top = [...agg].sort((x, y) => y[1].ms - x[1].ms).slice(0, 30);
  console.log(`${trace.length} events in ${secs}s; per second:`);
  for (const [k, v] of top) console.log(`${(v.n / secs).toFixed(1).padStart(7)}/s ${(v.ms / secs).toFixed(1).padStart(7)} ms/s  ${k}`);
  process.exit(0);
}
console.log("usage: pages | eval <suffix> <expr> | idle [secs] [suffix]");

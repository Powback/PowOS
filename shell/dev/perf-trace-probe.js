// The perf-trace gate scene's slow code (dev/gate.mjs perfTraceCheck), in a module of the page's own origin: the JS
// Self-Profiling API names only frames of such scripts (code from page.evaluate has no URL and is left out).
import { h } from "preact";
import { useState } from "preact/hooks";

const busy = (ms) => { const end = performance.now() + ms; let x = 0; while (performance.now() < end) x += Math.sqrt(x + 1); return x; };
/** A slow frame before the record tap: the pre-roll must hold it, its stack naming this function. */
export function gatePreRollJank() { return busy(90); }
/** A slow click handler with layout thrash (a write, then a read, 40 times): named in the trace with its forced layout. */
export function gateSlowClick(el) {
  let y = 0;
  for (let i = 0; i < 40; i++) { el.style.width = `${100 + i}px`; y += el.offsetWidth; }
  return busy(70) + y;
}
export function GateSlowButton() {
  const [n, setN] = useState(0);
  return h("button", { id: "gate-slow", onClick: (e) => { gateSlowClick(e.currentTarget); setN(n + 1); } }, `slow ${n}`);
}

// The "perf.meter" value as the bar's record tap broadcasts it, to home's recorder (fpssample.ts passes it on).
const meter = (v) => app("./ui/perfrec.ts").then((P) => P.onMeter(v));
// The app's own module instances (the ones fpssample.ts drives), not the gate's __gw.mod copies.
const app = (m) => window.importShim(m);
const G = () => window.__gw, wait = (ms) => new Promise((r) => setTimeout(r, ms));
/** The scene: home's detail of a recording made around the slow code above (or the one thing that went wrong). */
export async function perfTraceScene() {
  const { powos } = await app("./bridge.ts"), J = await app("./ui/jsprofile.ts");
  const sent = [], pub = powos.perf.publish;
  powos.perf.publish = async (json) => { sent.push(JSON.parse(json)); };
  try {
    const d = await record(sent);
    if (typeof d === "string") return [d];
    return [...(J.profileWhy() ? [`no JS profile in the gate's Chromium: ${J.profileWhy()}`] : []), ...readFrames(d)];
  } finally {
    powos.perf.publish = pub;
  }
}
/** Armed, a slow frame, the record tap, a slow handler, stop, the meter off. */
async function record(sent) {
  const { h, render } = await window.importShim("preact");
  const J = await app("./ui/jsprofile.ts");
  await wait(1500); // home's own start-up reads the stored meter (off here) and would disarm what this arms
  await meter({ on: true }); // armed: the pre-roll runs
  if (!J.profiling()) return `the meter on starts no JS profiler: ${J.profileWhy()}`;
  await wait(300); // the profiler's own start-up
  await new Promise((r) => requestAnimationFrame(() => { gatePreRollJank(); r(); }));
  await G().frames(6);
  await meter({ on: true, rec: 777 }); // the record tap, after the jank
  const host = document.body.appendChild(document.createElement("div"));
  render(h(GateSlowButton, null), host);
  await G().frames(3);
  document.getElementById("gate-slow").click();
  await G().frames(8);
  await meter({ on: true, stop: 777 }); // stop
  for (let i = 0; i < 60 && !complete(sent); i++) await wait(50);
  render(null, host); host.remove();
  return (await meterOff()) ?? detail(sent);
}
const complete = (sent) => sent.length > 0 && sent.length === sent[0].of;
/** The meter off: no profiler, no render scan hooks (or what still runs). */
async function meterOff() {
  const J = await app("./ui/jsprofile.ts"), R = await app("./ui/renderscan.ts");
  await meter(null);
  await G().frames(2);
  if (J.profiling()) return "the JS profiler still runs with the meter off";
  return R.scanning() ? "the render scan still hooked with the meter off" : null;
}
function detail(sent) {
  const mine = sent.filter((x) => x.rec === 777).sort((a, b) => a.recPart - b.recPart);
  if (!complete(mine)) return `home sent ${mine.length} of ${mine[0]?.of ?? "?"} parts`;
  return JSON.parse(mine.map((x) => x.data).join(""));
}
const named = (f, fn) => f.stacks.some((s) => s.at.includes(fn));
const dump = (f) => JSON.stringify(f).slice(0, 700);
/** The pre-roll's slow frame and the handler's frame, each named down to its function. */
function readFrames(d) {
  const frames = d.frames ?? [];
  const fails = d.preRollMs > 0 ? [] : [`no pre-roll: preRollMs ${d.preRollMs}`];
  if (!(d.js?.selfTop?.length > 0)) fails.push(`no js.selfTop: ${JSON.stringify(d.js).slice(0, 200)}`);
  return [...fails, ...preRollFrame(frames, d), ...handlerFrame(frames, d)];
}
function preRollFrame(frames, d) {
  // Its stack names it (a loaded Mac adds slow frames of its own; the verdict is this one's).
  const pre = frames.find((f) => f.start < 0 && named(f, "gatePreRollJank (dev/perf-trace-probe.js"));
  if (!pre) return [`the slow frame before the record tap isn't in the trace: ${JSON.stringify(frames.map((f) => [f.start, f.dur, f.verdict]))} preRollMs ${d.preRollMs} loaf ${JSON.stringify((d.loaf ?? []).map((l) => [l.start, l.dur]))} js ${dump(d.js)}`];
  return pre.verdict.startsWith("js") && pre.dur >= 80 ? [] : [`pre-roll frame not a js verdict of 80 ms+: ${dump(pre)}`];
}
function handlerFrame(frames, d) {
  const click = frames.find((f) => f.start >= 0 && f.handlers.some((x) => x.startsWith("GateSlowButton.onClick")));
  if (!click) return [`no long frame names the handler GateSlowButton.onClick: ${dump(frames)}`];
  const ok = click.forced > 0 && click.components.includes("GateSlowButton") && named(click, "gateSlowClick");
  return ok ? [] : [`handler frame lacks forced layout / its renders / its stack: ${dump(click)} commits ${JSON.stringify(d.renders?.commitList?.slice(-4))}`];
}

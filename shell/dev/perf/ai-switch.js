// Headless: the cost of switching to the AI page (GitHub Powback/PowOS#5, "a small hitch every time you switch to the
// AI page"). A board the live size (154 tasks over 10 areas, from dev/sample-board.json) and a 70-item chat, then three
// switches home -> AI page -> home. Per switch: the frames while it lands (rAF deltas and long animation frames), and
// the render scan (ui/renderscan.ts: which components rendered, needless ones, their time). Then [redeliver]: the board
// delivered again with equal content as fresh objects - what the page's feed does on every show on the phone (a new
// subscription's first rows, apps/stdb.ts useRows) - and what that re-renders.
//   shell/dev/perf/run.sh ai-switch.js [shell-dir]        PERF_TRACE=inv: also what restyled (run.sh)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const AREAS = ["AI page", "Home & launcher", "Shade & lock", "Windows", "Games", "Performance", "Kernel & system", "PowOS · phone UI", "Speech", "Devices"];
const ST = ["done", "done", "queued", "queued", "waiting", "working", "done", "queued", "waiting", "blocked"];
const ASK = [
  { kind: "user", text: "is the phone healthy? anything I should clean up?" },
  { kind: "tool", name: "Bash", hint: "powos status", ok: true, out: "Layers  custom,updates,base\nRAM     1.2G of 8G used" },
  { kind: "assistant", text: "Mostly **healthy**. One thing:\n\n- `/var` is at **91%**: old container images take 40 GB\n- the devops inbox is full\n\n```\npowos containers prune --older 30d\n```\nSee [the units](https://powos.pow/units)." },
  { kind: "tool", name: "Read", hint: "/home/powos/x.json", ok: true },
  { kind: "assistant", text: "Shipped the window raise fix: tap a window behind another and it comes to the front. The dock keeps its size." },
];

/** 154 board rows over the ten areas, cycled from the sample board. */
function boardRows(B, now) {
  return Array.from({ length: 154 }, (_, i) => {
    const r = B[i % Math.max(1, B.length)] ?? {};
    const st = ST[i % ST.length];
    return { ...r, id: `${r.id ?? "t"}-${i}`, project: AREAS[i % AREAS.length], status: st, created: now - 3e6 - i * 1000, updated: now - 2e5 - i * 1000, done: st === "done" ? now - 1e5 - i * 1000 : 0, activity: now - 1e5 };
  });
}

/** One long animation frame: its parts and its top scripts. */
const loafOf = (e) => ({
  ms: Math.round(e.duration),
  style: Math.round(e.styleAndLayoutStart ? e.startTime + e.duration - e.styleAndLayoutStart : 0),
  by: (e.scripts ?? []).slice(0, 3).map((x) => `${x.invoker} ${Math.round(x.duration)}ms`),
});

/** Frames from now for [ms]: rAF deltas, and long animation frames (>50 ms) where Chromium has them. */
async function frames(ms) {
  const loaf = [];
  let po = null;
  try {
    po = new PerformanceObserver((l) => l.getEntries().forEach((e) => loaf.push(loafOf(e))));
    po.observe({ type: "long-animation-frame" });
  } catch {}
  const ts = [];
  const t0 = performance.now();
  await new Promise((ok) => {
    const step = (t) => (ts.push(t), t - t0 < ms ? requestAnimationFrame(step) : ok());
    requestAnimationFrame(step);
  });
  po?.disconnect();
  const d = ts.slice(1).map((t, i) => t - ts[i]);
  const first = ts.length ? Math.round(ts[0] - t0) : -1;
  return { firstFrameMs: first, maxFrameMs: Math.round(Math.max(first, ...d)), over20: d.filter((x) => x > 20).length + (first > 20 ? 1 : 0), frames: ts.length, loaf };
}

/** The render scan since its last reset. */
function scan(R) {
  const r = R.report();
  const row = (x) => `${x.name} ${x.renders}r ${x.needless}n ${x.selfMs}ms`;
  return { renders: r.renders, needless: r.needlessRenders, renderMs: r.renderMs, commits: r.commits, byTime: r.byTime.slice(0, 6).map(row), byCount: r.byCount.slice(0, 6).map(row) };
}

/** One switch to the AI page and the board delivered again on it, then home again. */
async function oneSwitch(S, P, R, k) {
  R.reset();
  S.page.value = -1;
  const sw = await frames(700);
  const swScan = scan(R);
  R.reset();
  P.board.value = P.board.value.map((r) => ({ ...r }));
  const rd = await frames(400);
  const out = { k, switch: { ...sw, ...swScan }, redeliver: { ...rd, ...scan(R) } };
  S.page.value = 0;
  await sleep(900);
  return out;
}

async function aiSwitch() {
  const S = await importShim("./state.ts"), P = await importShim("./ui/powai.tsx");
  if (!window.__powosRenders) await importShim("./ui/renderscan.ts");
  const R = window.__powosRenders;
  const B = await fetch("./dev/sample-board.json").then((r) => r.json()).catch(() => []);
  P.board.value = boardRows(B, Date.now());
  P.boardSeen.value = true;
  S.chat.value = { busy: false, items: Array.from({ length: 14 }, () => ASK).flat() };
  S.page.value = 0;
  await sleep(1200);
  R.start();
  const out = [];
  for (let k = 0; k < 3; k++) out.push(await oneSwitch(S, P, R, k));
  R.stop();
  return out;
}

aiSwitch();

/**
 * LA1: the launcher adopts home's dock and bar (the user, 2026-10-31 15:44-15:45: "It should also reuse the docking, so
 * that we don't get duplicate docking" / "If the docking and recents is already available, we should just reuse that").
 * gate.mjs's launcher-adopt-* cases.
 *
 * adoptsHome (home's page, index.html): the launcher opened over home keeps ONE bar and ONE dock on screen in every
 * frame sampled through the open and after, at the same rects - only the app grid's layer moves.
 * ownDock (the overlay's page, index.html?mode=pull, over an app): no home dock under it, so it brings its own (one).
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const frame = () => new Promise((r) => requestAnimationFrame(() => r()));

/** On screen: laid out, not hidden, not faded out. */
function shown(el) {
  const r = el.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) return false;
  const cs = getComputedStyle(el);
  return cs.visibility !== "hidden" && cs.display !== "none" && Number(cs.opacity) > 0.05;
}

/** The bars and docks (not the wide foot's recents tray) on screen, and their rects. */
function foot() {
  const bars = [...document.querySelectorAll("form.bar")].filter(shown);
  const docks = [...document.querySelectorAll(".dock:not(.dock-tray)")].filter(shown);
  const at = (el) => {
    const r = el.getBoundingClientRect();
    return [r.left, r.top, r.width, r.height].map(Math.round).join(",");
  };
  return { bars: bars.length, docks: docks.length, rects: [...bars, ...docks].map(at).join(" ") };
}

/** Ten frames - five through the open's animation, five after it settled: one bar, one dock, where they were. */
async function sampled(before) {
  const fails = [];
  for (let i = 0; i < 10; i++) {
    if (i === 5) await sleep(450);
    await frame();
    const f = foot();
    if (f.bars !== 1 || f.docks !== 1) fails.push(`frame ${i}: ${f.bars} bars, ${f.docks} docks`);
    else if (f.rects !== before.rects) fails.push(`frame ${i}: moved ${before.rects} -> ${f.rects}`);
  }
  return fails;
}

export async function adoptsHome(position) {
  const S = await importShim("./state.ts");
  const { powos } = await importShim("./bridge.ts");
  const asked = [];
  powos.pull.open = async (kind) => (asked.push(kind), true);
  if (S.dock.value.length < 4) S.dock.value = S.recent.value.slice(0, 4);
  S.dockTry.value = position;
  await sleep(300);
  const before = foot();
  const fails = before.bars === 1 && before.docks === 1 ? [] : [`at rest: ${before.bars} bars, ${before.docks} docks`];
  S.openPanel("apps", { search: true });
  fails.push(...(await sampled(before)));
  if (S.drawer.value !== 1) fails.push("the launcher didn't open in place");
  if (asked.length) fails.push("asked the host's overlay over home");
  if (document.querySelector(".pull-screen")) fails.push("a launcher copy (.pull-screen) on home's page");
  S.closeDrawer();
  S.dockTry.value = "";
  return [...new Set(fails)].map((f) => `${position}: ${f}`);
}

export async function ownDock() {
  const E = window.__mockEvents;
  E.emit("pull.begin", { kind: "apps" });
  E.emit("pull.end", { open: true });
  await sleep(450);
  const f = foot();
  const fails = f.docks === 1 && f.bars === 1 ? [] : [`over an app: ${f.bars} bars, ${f.docks} docks (its own, one each)`];
  E.emit("pull.end", { open: false });
  return fails;
}

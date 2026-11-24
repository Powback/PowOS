/**
 * RZ8 (board window-shadow-is-mispositioned-while-resizing-a, ww-shadow.sh 11-23: the n and s drags resized the
 * Calculator, w, se and nw left its frame as it was). Every resize zone of a window takes a real finger: unfolded,
 * one window placed as the phone check places it (half the work area, its bottom right), each of the 8 zones dragged
 * by CDP touch (the node side: gate.mjs wwHandlesScene) out and in, within the min size and the work area. Twice:
 * alone, and over a lower window lying under its west zones (the phone's Chrome left of the Calculator) - the zone of
 * the window on top is the finger's there, a lower window's BODY never takes it (RZ7 passes on only its bar).
 * Runs in the page; the node side sends the touches.
 */
const TOP = 960;
const LOW = 961;
const sel = (id) => `.webwindow[data-wwid="${id}"]`;
const mods = async () => Promise.all(["./state.ts", "./ui/webwindows.tsx"].map((m) => window.__gw.mod(m)));

/** The windows as the case [under] wants (true: the lower one left of the top one, under its w/nw/sw zones), the top one placed fresh (ww-shadow.sh's place()). */
async function putWindows(under) {
  const [S, W] = await mods();
  S.dockTry.value = "right";
  S.page.value = 0;
  await window.__gw.settled();
  const p = S.pages.value[0];
  W.tilings.value = {};
  const a = W.workArea();
  const w = Math.round((a.right - a.left) * 0.5);
  const h = Math.round((a.bottom - a.top) * 0.5);
  const low = { id: LOW, key: "a:gate.low/.Main", label: "Low", page: p, x: 20, y: 120, w: a.right - w - 40, h: a.bottom - 200, live: true };
  const top = { id: TOP, key: "a:gate.top/.Main", label: "Top", page: p, x: 0, y: 0, w, h, live: true };
  W.webWins.value = under ? [low, top] : [top];
  await window.__gw.settled();
  W.placeWindow(TOP, { x: a.right - w - 56, y: a.bottom - h - 64, w, h });
  await window.__gw.settled();
  await new Promise((ok) => setTimeout(ok, 120));
}

/** [putWindows], then the top window's frame and the centre of its zone [side] (viewport px), what a finger there hits. */
export async function handlesPut(side, under) {
  await putWindows(under);
  const own = document.querySelector(sel(TOP));
  const z = own?.querySelector(`.ww-edge-${side}`)?.getBoundingClientRect();
  if (!z) return { why: `no ${side} zone` };
  const f = own.getBoundingClientRect();
  const x = z.left + z.width / 2;
  const y = z.top + z.height / 2;
  const below = document.elementsFromPoint(x, y).find((el) => !own.contains(el));
  return { x, y, frame: [f.left, f.top, f.right, f.bottom].map(Math.round), hit: String(document.elementFromPoint(x, y)?.className ?? ""), underLow: !!below?.closest(sel(LOW)) };
}

/** The top window's frame now, viewport px (l t r b), and which window is on top. */
export async function handlesFrame() {
  const [, W] = await mods();
  await window.__gw.settled();
  const f = document.querySelector(sel(TOP))?.getBoundingClientRect();
  return { frame: f ? [f.left, f.top, f.right, f.bottom].map(Math.round) : null, top: W.webWins.value.at(-1)?.id };
}

export async function handlesDone() {
  const [, W] = await mods();
  W.webWins.value = [];
  W.tilings.value = {};
}

/**
 * The verdict of one drag ([name]) of zone [side] by ([dx], [dy]): each side it names moved that way (by more than half the
 * drag, less than all of it plus a snap), the others stayed (2 px). [f0] / [f1]: frames before / after.
 */
export function handlesVerdict({ name, side, dx, dy, f0, f1 }) {
  if (!f1) return [`RZ8 ${name}: the window is gone`];
  const moves = { w: [0, dx], n: [1, dy], e: [2, dx], s: [3, dy] };
  const fails = [];
  for (const [s, [i, d]] of Object.entries(moves)) {
    const got = f1[i] - f0[i];
    if (!side.includes(s)) {
      if (Math.abs(got) > 2) fails.push(`its ${s} side moved ${got} px (want still)`);
    } else if (Math.sign(got) !== Math.sign(d) || Math.abs(got) < Math.abs(d) / 2) fails.push(`its ${s} side moved ${got} px (want ~${d})`);
  }
  return fails.length ? [`RZ8 ${name}: a real drag of the ${side} zone by ${dx},${dy}: ${fails.join(", ")} (frame ${f0} -> ${f1})`] : [];
}

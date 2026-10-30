/**
 * The side-button overlay (assist.tsx) while drawing and when summoned with a short press. Runs in the page
 * (gate.mjs "assist-draw-*", index.html?mode=assist), against the mock bridge. In two steps, so the gate renders the
 * stroke mid-way between them.
 *
 * AO2 (the user, 2026-10-30: "when I activate it with like a short click, we should still activate the
 * transcription"): a summoning followed by a short press (assist.reset, assist.quick) starts the recognizer once, the
 * field listening, and nothing asks it to end at a pause (no speech.quiet).
 * AO1 (the user, 2026-10-30: "It should hide while I'm drawing so that I can draw like under the drawer"): a stroke
 * going down into the panel's area - the panel fades to opacity 0 and takes no touches (the point over it is the
 * drawing layer's), the stroke's points there recorded and drawn above everything, the dictation paused; on its end
 * the panel is back with the cut-out attached and the dictation listens again.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const panel = () => document.querySelector(".assist-panel");
const mic = () => document.querySelector("form.assist-ask .mic");
const field = () => document.querySelector("form.assist-ask textarea");
const listening = () => !!mic()?.classList.contains("on");

/** The mock recognizer counted (and, as the real one, going on through pauses); synthetic pointers' capture a no-op. */
function spy(sp, fails) {
  const orig = { start: sp.start, quiet: sp.quiet, capture: Element.prototype.setPointerCapture };
  const n = { starts: 0, quiets: 0 };
  sp.start = () => (n.starts++, orig.start(true));
  sp.quiet = (ms) => (n.quiets++, orig.quiet(ms));
  Element.prototype.setPointerCapture = () => {};
  const wait = async (what, f, ms = 3000) => {
    for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(30)) if (f()) return true;
    fails.push(`timed out waiting for ${what}`);
    return false;
  };
  const restore = () => (Object.assign(sp, { start: orig.start, quiet: orig.quiet }), (Element.prototype.setPointerCapture = orig.capture));
  return { n, wait, restore };
}

/** AO2: summoned, then the side button already up. */
async function shortPress({ n, wait }, fails) {
  window.__mockEvents.emit("assist.reset");
  window.__mockEvents.emit("assist.quick");
  await wait("the short press's dictation", listening, 1000);
  await sleep(300);
  if (n.starts !== 1) fails.push(`short press: speech.start called ${n.starts} times, not once`);
  if (n.quiets) fails.push(`short press: speech.quiet called (${n.quiets}): a pause would end the dictation`);
  if (!listening()) fails.push("short press: the mic isn't listening");
  const f = field();
  if (f?.placeholder !== "listening…" && !f?.value) fails.push(`short press: the field shows neither listening… nor words (${f?.placeholder})`);
}

/** A screenshot to cut from (the mock's screen has none): a checker the size of the window. */
function screenshot() {
  const c = document.createElement("canvas");
  c.width = window.innerWidth;
  c.height = window.innerHeight;
  const g = c.getContext("2d");
  g.fillStyle = "#3a6ea5";
  g.fillRect(0, 0, c.width, c.height);
  g.fillStyle = "#f0c040";
  for (let y = 0; y < c.height; y += 60) for (let x = (y / 60) % 2 ? 30 : 0; x < c.width; x += 60) g.fillRect(x, y, 30, 30);
  window.__mockEvents.emit("assist.context", { text: "Inbox", screenshot: c.toDataURL("image/png") });
}

/** From just above the panel down into it: a circle round what's under the panel's middle. */
function circle(p) {
  const cx = p.left + p.width / 2;
  const cy = p.top + p.height / 2;
  const r = Math.min(p.width, p.height) / 3;
  const pts = [[cx, p.top - 20]];
  for (let i = 0; i <= 24; i++) pts.push([cx + r * Math.sin((i / 24) * 2 * Math.PI), cy - r * Math.cos((i / 24) * 2 * Math.PI)]);
  return { pts, cx, cy };
}

const at = (x, y) => ({ bubbles: true, pointerId: 7, isPrimary: true, clientX: x, clientY: y });
const line = () => (document.querySelector(".crop-stroke polyline")?.getAttribute("points") ?? "").split(" ").filter(Boolean).map((s) => s.split(",").map(Number));
const zOf = (sel) => Number(getComputedStyle(document.querySelector(sel)).zIndex) || 0;

/** AO1, mid-stroke: the panel unseen and untouchable, the touch over it the drawing's, the points there, the mic paused. */
function midStroke(p, cx, cy, fails) {
  const inPanel = (q) => q[0] >= p.left && q[0] <= p.right && q[1] >= p.top && q[1] <= p.bottom;
  const style = getComputedStyle(panel());
  if (style.opacity !== "0") fails.push(`mid-stroke: the panel's opacity is ${style.opacity}, not 0`);
  if (style.pointerEvents !== "none") fails.push(`mid-stroke: the panel takes touches (pointer-events ${style.pointerEvents})`);
  const hit = document.elementFromPoint(cx, cy);
  if (!hit?.closest(".assist-draw")) fails.push(`mid-stroke: a touch over the panel's middle reaches ${hit?.className || hit?.tagName}, not the drawing layer`);
  if (!line().filter(inPanel).length) fails.push("mid-stroke: no stroke point recorded over the panel's area");
  return inPanel;
}

export async function assistDrawStart() {
  const { powos } = await importShim("./bridge.ts");
  const fails = [];
  const s = spy(powos.speech, fails);
  // The boot's own summoning dictation (the mock's) first: done, the mic off.
  await s.wait("the boot's dictation to end", () => mic() && !listening(), 5000);
  await sleep(200);
  s.n.starts = 0;
  await shortPress(s, fails);
  screenshot();
  await sleep(300);
  const draw = document.querySelector(".assist-draw");
  const p = panel()?.getBoundingClientRect();
  if (!draw || !p) return (s.restore(), [...fails, "no .assist-draw or .assist-panel"]);
  const { pts, cx, cy } = circle(p);
  draw.dispatchEvent(new PointerEvent("pointerdown", at(...pts[0])));
  for (const [x, y] of pts.slice(1, 14)) draw.dispatchEvent(new PointerEvent("pointermove", at(x, y)));
  // The fade: ~120 ms.
  await sleep(250);
  const inPanel = midStroke(p, cx, cy, fails);
  if (zOf(".crop-stroke") <= Math.max(zOf(".assist-panel"), zOf(".assist-edge"))) fails.push("mid-stroke: the stroke isn't drawn above the panel and the edge");
  if (listening()) fails.push("mid-stroke: the dictation didn't pause");
  window.__ad = { fails, s, draw, pts, inPanel };
  return fails;
}

export async function assistDrawEnd() {
  const { fails, s, draw, pts, inPanel } = window.__ad;
  try {
    for (const [x, y] of pts.slice(14)) draw.dispatchEvent(new PointerEvent("pointermove", at(x, y)));
    draw.dispatchEvent(new PointerEvent("pointerup", at(...pts[pts.length - 1])));
    // The fade back (~120 ms), with room for a loaded gate.
    await s.wait("the panel back", () => getComputedStyle(panel()).opacity === "1", 1500);
    if (getComputedStyle(panel()).pointerEvents === "none") fails.push("after the stroke: the panel still takes no touches");
    await s.wait("the cut-out attached", () => /circled/.test(document.querySelector(".assist-attach")?.textContent ?? ""), 1000);
    if (!line().filter(inPanel).length) fails.push("after the stroke: the stroke over the panel's area is gone");
    await s.wait("the dictation to listen again", listening, 1000);
    if (s.n.starts !== 2) fails.push(`after the stroke: speech.start called ${s.n.starts} times in all, not 2 (the short press's + the resume)`);
  } finally {
    s.restore();
  }
  return fails;
}

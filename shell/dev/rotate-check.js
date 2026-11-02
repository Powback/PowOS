/**
 * RT1 (the user, 11-02 21:55, P0: "I rotated my phone and know it's in a bad state", then "I had to restart my phone to
 * fix it"). Runs in the page (index.html): gate.mjs's rotate-* cases turn and fold the viewport (window.screen with
 * it, as the WebView's); [turned] asserts from inside the page that the shell laid out at the new size and draws.
 */

const box = (q) => document.querySelector(q)?.getBoundingClientRect();
const r4 = (b) => b && [b.left, b.top, b.right, b.bottom].map(Math.round).join(",");

/** The surface on screen for page [start] (PowOS AI's for -1, home's otherwise) covers the [w]x[h] screen from x 0. */
function shownFills(start, w, h) {
  const q = start < 0 ? ".ai-screen" : ".home";
  const b = box(q);
  const fills = b && Math.round(b.left) === 0 && Math.round(b.top) === 0 && Math.round(b.width) === w && Math.round(b.height) === h;
  return fills ? "" : `${q} at ${r4(b)}, not the ${w}x${h} screen`;
}

/** Folded (mobile), home's own dock is inside the screen - on the right when sideways. */
function dockPlaced(w, h) {
  const d = box(".home .dock:not(.dock-tray)");
  if (!d || d.left < -1 || d.top < -1 || d.right > w + 1 || d.bottom > h + 1) return `the dock at ${r4(d)} leaves the ${w}x${h} screen`;
  return w > h && d.left < w / 2 ? "folded sideways: the dock is not the right column" : "";
}

/** Folded, the dock placed and the pages on [start]. */
function homePlaced(start, w, h) {
  if (start < 0 || w >= 700) return "";
  const dock = dockPlaced(w, h);
  if (dock) return dock;
  const track = box(".page-track"), pages = box(".pages");
  if (Math.abs(track.left - (pages.left - start * pages.width)) > 2) return `the pages slid to ${Math.round(track.left)}, not page ${start}`;
  return "";
}

/** Nothing scrolled out of place by the resize (the document, home's boxes, the AI page). */
function unscrolled() {
  const doc = document.scrollingElement;
  if (doc.scrollTop || doc.scrollLeft) return `the document scrolled ${doc.scrollLeft},${doc.scrollTop}`;
  const moved = [".home", ".screens", ".stage", ".pages", ".ai-screen"].find((q) => {
    const e = document.querySelector(q);
    return e && (e.scrollTop || e.scrollLeft);
  });
  return moved ? `${moved} scrolled` : "";
}

/** After a turn to [w]x[h] on page [start]: "" when the shell is laid out at it and still drawing, else why not. */
export async function turned(w, h, start) {
  const G = window.__gw;
  await G.sleep(700);
  const drew = await Promise.race([G.frames(3).then(() => true), G.sleep(1500).then(() => false)]);
  if (!drew) return "no frames after the turn";
  if (innerWidth !== w || innerHeight !== h) return `the page is ${innerWidth}x${innerHeight}`;
  const blank = (await importShim("./ui/homedrawn.ts")).homeBlank();
  return shownFills(start, w, h) || (blank && `blank: ${blank}`) || homePlaced(start, w, h) || unscrolled();
}

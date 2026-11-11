/**
 * The widget fit checks: one tile's measurement, shared by the gate's widget sweep (dev/preview/sheet.tsx check(), every
 * widget at every size in a headless Chromium) and the phone's live page (homeWidgetFit below, through
 * tools/phone/verify/shell-check.sh: the widgets as the user placed them, at their real sizes) - one assertion, so the
 * device check and the gate can't drift. Plain JS without imports: shell-check.sh inlines this file into the page.
 */

/** A box's visible part: clipped by every overflow-hiding ancestor up to [stop]. */
function visible(el, r, stop) {
  let { left, top, right, bottom } = r;
  for (let a = el.parentElement; a && a !== stop.parentElement; a = a.parentElement) {
    const cs = getComputedStyle(a);
    if (cs.overflowX === "visible" && cs.overflowY === "visible") continue;
    const b = a.getBoundingClientRect();
    if (cs.overflowX !== "visible") (left = Math.max(left, b.left)), (right = Math.min(right, b.right));
    if (cs.overflowY !== "visible") (top = Math.max(top, b.top)), (bottom = Math.min(bottom, b.bottom));
  }
  return { left, top, right, bottom, w: Math.max(0, right - left), h: Math.max(0, bottom - top) };
}

/**
 * A canvas's drawn pixels' box, in page coordinates (null: nothing drawn). Read through a copy (drawImage), never the
 * canvas's own context: asking for one claims the canvas (a widget's later transferControlToOffscreen or WebGL context
 * then fails), and a canvas a worker draws (an OffscreenCanvas's placeholder: the stickman's) has none to give.
 */
function inked(c) {
  if (!c.width || !c.height) return null;
  const copy = document.createElement("canvas");
  copy.width = c.width;
  copy.height = c.height;
  const g = copy.getContext("2d", { willReadFrequently: true });
  if (!g) return null;
  let d;
  try {
    g.drawImage(c, 0, 0);
    d = g.getImageData(0, 0, c.width, c.height).data;
  } catch {
    return null; // a canvas another origin drew (tainted): its ink can't be read
  }
  let x0 = c.width, y0 = c.height, x1 = -1, y1 = -1;
  for (let y = 0; y < c.height; y++)
    for (let x = 0; x < c.width; x++)
      if (d[(y * c.width + x) * 4 + 3] > 24) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
  if (x1 < 0) return null;
  const r = c.getBoundingClientRect();
  const k = r.width / c.width;
  return { left: r.left + x0 * k, top: r.top + y0 * k, right: r.left + (x1 + 1) * k, bottom: r.top + (y1 + 1) * k };
}

/** Painted: a background or a shadow of its own (a chip, a bar, a swatch), not a transparent box. */
const painted = (cs) => (cs.backgroundColor && !/rgba\(0, 0, 0, 0\)|transparent/.test(cs.backgroundColor)) || cs.backgroundImage !== "none";

/**
 * The fit checks for one tile's face (a .home-tile > .tile): { problems, covered } - covered the share of its inside
 * the content covers (null: not measured).
 * - clipped text: a text box wider (or taller) than the box that shows it - ellipsis, a cut line;
 * - a row cut in half: content partly hidden by the tile's (or a container's) edge - between 8% and 92% of it shows;
 * - unfilled: the content's box leaves more than [EMPTY] of a side of the tile's inside empty;
 * - small content: what's drawn (text boxes, painted boxes, a canvas's ink, an SVG) covers less than [COVER] of it
 *   (calibrated 2026-10-21 on the manager's review: the big tiles flagged as "a tiny 5° in a huge box" measured 8-15%,
 *   the folded ones approved as they were 27-44%);
 * - scroll: a scrolling container in a tile (a home tile can't take a scroll gesture from the page) - but a strip
 *   that scrolls sideways and says so (touch-action: pan-x: it took the gesture), or a list that scrolls up and down
 *   in whole rows (pan-y, scroll-snap y);
 * - a slider (a range, role=slider: a drag-to-dim pill) inside something that scrolls sideways;
 * - a sideways drag (touch-action none / pan-y) without the flag home's pager respects (role=slider, data-owns-gesture);
 * - hard border: a drawn 1px+ line round content (the design language: no lines).
 * An island's shared offline state (.island-offline.alone: the app can't reach its device, nothing to show) and the
 * Agents widget's compact empty line (.ag-idle-line: nobody running, a small tile / the desktop) are sparse by design -
 * one calm muted line was asked for, not a filled tile - and so are content that says so ([data-sparse]: the Agents
 * widget's rows, each at its own height from the top, the room under them empty glass - the manager's QA 11-01 19:20,
 * "never stretch") - so unfilled / small content don't apply to them; everything else (clipped text above all) does.
 */
export function tileFit(face, EMPTY = 0.12, COVER = 0.25) {
  const problems = [];
  let covered = null;
  const fr = face.getBoundingClientRect();
  // The inside: the face less its own padding and the OWL root's (the widget's declared padding is its margin).
  const owl = face.querySelector(":scope > .owl");
  const pad = (e) => {
    const cs = e ? getComputedStyle(e) : null;
    return cs ? [parseFloat(cs.paddingLeft), parseFloat(cs.paddingTop), parseFloat(cs.paddingRight), parseFloat(cs.paddingBottom)] : [0, 0, 0, 0];
  };
  const [a, b] = [pad(face), pad(owl)];
  const inner = { left: fr.left + a[0] + b[0], top: fr.top + a[1] + b[1], right: fr.right - a[2] - b[2], bottom: fr.bottom - a[3] - b[3] };
  const ink = { left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity };
  // How much of the inside the content covers: a 2 px grid over it, each cell under some ink marked once.
  const GW = Math.max(1, Math.ceil((inner.right - inner.left) / 2));
  const GH = Math.max(1, Math.ceil((inner.bottom - inner.top) / 2));
  const grid = new Uint8Array(GW * GH);
  const add = (r) => {
    if (r.right - r.left < 1 || r.bottom - r.top < 1) return;
    const x0 = Math.max(0, Math.floor((r.left - inner.left) / 2));
    const x1 = Math.min(GW, Math.ceil((r.right - inner.left) / 2));
    const y0 = Math.max(0, Math.floor((r.top - inner.top) / 2));
    const y1 = Math.min(GH, Math.ceil((r.bottom - inner.top) / 2));
    for (let y = y0; y < y1; y++) grid.fill(1, y * GW + x0, Math.max(y * GW + x0, y * GW + x1));
    ink.left = Math.min(ink.left, r.left);
    ink.top = Math.min(ink.top, r.top);
    ink.right = Math.max(ink.right, r.right);
    ink.bottom = Math.max(ink.bottom, r.bottom);
  };
  const clipped = new Set();
  const cut = new Set();
  const range = document.createRange();
  // A strip that scrolls sideways on purpose (touch-action: pan-x - it took the gesture from the page): what it holds
  // past its edge is reachable, not cut.
  const strip = (e) => {
    const cs = getComputedStyle(e);
    return /(auto|scroll)/.test(cs.overflowX) && cs.touchAction.includes("pan-x");
  };
  // A list that scrolls up and down on purpose: it takes the vertical gesture (pan-y) and snaps to whole rows.
  const column = (e) => {
    const cs = getComputedStyle(e);
    return /(auto|scroll)/.test(cs.overflowY) && cs.touchAction.includes("pan-y") && cs.scrollSnapType.startsWith("y");
  };
  const inColumn = (e) => {
    for (let a = e.parentElement; a && a !== face; a = a.parentElement) if (column(a)) return true;
    return false;
  };
  // Something dragged sideways (a slider, a range, a drag-to-dim pill): never inside what scrolls sideways - the
  // scroll would take its drag (Lights' strip of pills that couldn't be dimmed).
  const sideways = (e) => {
    for (let a = e.parentElement; a && a !== face; a = a.parentElement) {
      const cs = getComputedStyle(a);
      if (/(auto|scroll)/.test(cs.overflowX) && a.scrollWidth > a.clientWidth + 1) return true;
    }
    return false;
  };
  const inStrip = (e) => {
    for (let a = e.parentElement; a && a !== face; a = a.parentElement) if (strip(a)) return true;
    return false;
  };
  const short = (t) => (t.length > 28 ? t.slice(0, 27) + "…" : t);
  for (const el of face.querySelectorAll("*")) {
    // A failed image hidden in its own box (owl.tsx Image onError) keeps the widget's layout: its slot counts as laid out.
    if (el instanceof HTMLImageElement && el.complete && !el.naturalWidth && el.style.visibility === "hidden") add(visible(el, el.getBoundingClientRect(), face));
    if (!el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
    const cs = getComputedStyle(el);
    if (el instanceof HTMLCanvasElement) {
      // Sized by its node, never by its bitmap (owl.tsx Canvas: contain size): one taller or wider than its tile grew.
      const cr = el.getBoundingClientRect();
      if (cr.height > fr.height + 1 || cr.width > fr.width + 1) problems.push(`a canvas ${Math.round(cr.width)}x${Math.round(cr.height)} past its tile (sized by its bitmap)`);
      const r = inked(el);
      if (r) add(r);
      continue;
    }
    // An SVG (a ring, a sparkline): its box - a gauge's open foot is its shape, not empty room.
    if (el instanceof SVGSVGElement) {
      add(visible(el, el.getBoundingClientRect(), face));
      continue;
    }
    if (el instanceof SVGElement) continue;
    // A failed image is hidden (owl.tsx Image onError), never the WebView's broken-image box (data/97-now-playing~broken-art).
    if (el instanceof HTMLImageElement && el.complete && !el.naturalWidth && el.getAttribute("src")) problems.push("a broken image shows (hide it on error)");
    if (el instanceof HTMLImageElement || el instanceof HTMLInputElement || painted(cs)) add(visible(el, el.getBoundingClientRect(), face));
    // Its own text: clipped by itself (ellipsis, line clamp) or by what holds it.
    const own = [...el.childNodes].filter((n) => n.nodeType === 3 && n.textContent.trim());
    if (own.length) {
      const t = el.textContent.trim().replace(/\s+/g, " ");
      if ((el.scrollWidth > el.clientWidth + 1 && cs.overflowX !== "visible") || (el.scrollHeight > el.clientHeight + 2 && cs.overflowY !== "visible" && el.clientHeight > 0))
        clipped.add(short(t));
      for (const n of own) {
        range.selectNodeContents(n);
        for (const r of range.getClientRects()) {
          const v = visible(el, r, face);
          const shown = (v.w * v.h) / Math.max(1, r.width * r.height);
          if (shown > 0.08 && shown < 0.92 && r.height > 4 && !inStrip(el) && !inColumn(el)) cut.add(short(t));
          if (shown > 0.08) add(v);
        }
      }
    }
    const scrollsY = /(auto|scroll)/.test(cs.overflowY) && el.scrollHeight > el.clientHeight + 1;
    const scrollsX = /(auto|scroll)/.test(cs.overflowX) && el.scrollWidth > el.clientWidth + 1;
    if ((scrollsY && !column(el)) || (scrollsX && !strip(el))) problems.push("scrolls (a tile can't)");
    const drags = (el instanceof HTMLInputElement && el.type === "range") || el.getAttribute("role") === "slider";
    if (drags && sideways(el)) problems.push("a slider in a sideways scroller (the scroll takes its drag)");
    // It asks for sideways drags itself (touch-action none / pan-y, not a list that scrolls) but doesn't say it owns
    // them: home's pager (shell/ui/gesture.ts) takes the drag and swipes the page. A range, role=slider or
    // data-owns-gesture is the flag.
    const wantsX = /^(none|pan-y)$/.test(cs.touchAction) && !/(auto|scroll)/.test(cs.overflowY) && !(el instanceof HTMLInputElement);
    if (wantsX && !el.closest("input[type=range], [role=slider], [data-owns-gesture]"))
      problems.push("a drag the home pager takes (mark it role=slider or data-owns-gesture)");
    const bw = Math.max(parseFloat(cs.borderTopWidth), parseFloat(cs.borderLeftWidth));
    if (bw >= 1 && cs.borderTopStyle !== "none" && !/rgba\(0, 0, 0, 0\)|transparent/.test(cs.borderTopColor)) problems.push("hard border");
  }
  // Other visible children (an element painted nothing but has size, e.g. a fixed-size Box) don't count as ink.
  if (face.dataset.pvSheet) problems.push(...face.dataset.pvSheet.split("\n"));
  for (const t of clipped) problems.push(`clipped text "${t}"`);
  for (const t of cut) if (!clipped.has(t)) problems.push(`row cut in half "${t}"`);
  if (face.querySelector(".island-offline.alone, .ag-idle-line, [data-sparse]")) {
    if (!(ink.right > ink.left)) problems.push("nothing drawn");
  } else if (ink.right > ink.left) {
    const W = inner.right - inner.left;
    const H = inner.bottom - inner.top;
    const gaps = {
      left: (ink.left - inner.left) / W,
      right: (inner.right - ink.right) / W,
      top: (ink.top - inner.top) / H,
      bottom: (inner.bottom - ink.bottom) / H,
    };
    const empty = Object.entries(gaps).filter(([, g]) => g > EMPTY).map(([s, g]) => `${s} ${Math.round(g * 100)}%`);
    if (empty.length) problems.push(`unfilled: ${empty.join(", ")} empty`);
    // Spread thin: content reaching the edges but small in the middle of a big tile (a "5°" in a box) - it should
    // scale with the tile, not only spread out.
    let n = 0;
    for (let i = 0; i < grid.length; i++) n += grid[i];
    covered = n / grid.length;
    if (covered < COVER) problems.push(`small content: covers ${Math.round(covered * 100)}% of the tile`);
  } else problems.push("nothing drawn");
  return { problems: [...new Set(problems)], covered };
}

/**
 * The device side (tools/phone/verify/shell-check.sh, home's live page): every home tile of app [app]'s islands (default
 * the Progress app's, "app:<app>/<widget>") as the user placed them - their real sizes, the theme on now - through
 * tileFit, the gate's own assertion. Read-only: it never adds, moves or resizes a widget, never changes a page. [fold]
 * names the screen in the answers. The fails ([] = PASS); "SKIP: ..." when none is placed or none has drawn yet.
 */
export async function homeWidgetFit(fold = "", app = "local.powos-progress", EMPTY = 0.12, COVER = 0.25) {
  const S = await window.__gw.mod("./state.ts");
  const where = fold ? ` (${fold})` : "";
  const mine = S.home.value.items.filter((i) => i.kind === "panel" && (i.name ?? "").startsWith(`app:${app}/`));
  if (!mine.length) return [`SKIP: no ${app} widget placed on home${where} - the check never adds one`];
  const faceOf = (i) => document.querySelector(`.home-tile[data-key="${CSS.escape(i.key)}"] > .tile`);
  // Drawn: its island loaded (not the "…" / loading fault face) and laid out.
  const drawn = (i) => {
    const f = faceOf(i);
    return !!f && f.matches(".island-face") && f.getBoundingClientRect().width > 0;
  };
  await window.__gw.until(() => mine.every(drawn), 8000);
  const fails = [];
  const undrawn = [];
  let measured = 0;
  for (const i of mine) {
    const name = `${i.name.slice(`app:${app}/`.length)} ${i.cell ? `${i.cell.w}x${i.cell.h}` : "unplaced"} on page ${i.page}${where}`;
    const f = faceOf(i);
    if (!f) continue; // a page home doesn't render now: not this screen's
    // Its island not loaded (a wait face: no Linux image, SpacetimeDB down, loading): nothing of its own to fit yet.
    if (!drawn(i)) {
      undrawn.push(`${name}: "${(f.textContent ?? "").trim().replace(/\s+/g, " ").slice(0, 60)}"`);
      continue;
    }
    measured++;
    // The island's own settle: what it shows stops changing (its data arriving) before it's measured.
    await window.__gw.steady(() => f.innerHTML.length, 8, 6000);
    for (const p of tileFit(f, EMPTY, COVER).problems) fails.push(`${name}: ${p}`);
  }
  if (measured) return fails;
  if (undrawn.length) return [`SKIP: no ${app} widget drew its own content - ${undrawn.join("; ")}`];
  return [`SKIP: ${mine.length} ${app} widget(s) placed, none rendered on this screen${where}`];
}

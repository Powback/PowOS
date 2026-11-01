/**
 * The design language's page probe (docs/DESIGN-LANGUAGE.md §4, §6), gate.mjs's design-lint-* runs: REPORT-ONLY - it
 * returns what it found, the gate prints it and never fails on it (yet).
 *
 * - pop-ins: a surface is opened from state (as shots.mjs's scenes do) under a MutationObserver; every element added
 *   while it opens is read on its first frame - drawn (a box, visible, not transparent) with no animation running on
 *   it or an ancestor and no ancestor mid-fade is an element that appeared in a single frame.
 * - monospace: once the surface is at rest, every visible text whose font's first family is a monospace one, outside
 *   code (pre, code, kbd, samp, a terminal, a textarea) - UI text is --font-ui.
 *
 * Returns { popins: [label...], mono: { count, where: [[label, n]...] } }.
 */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const frame = () => new Promise((r) => requestAnimationFrame(() => r()));
const MONO = /mono|courier|consolas|menlo/i;
const CODE = "pre, code, kbd, samp, textarea, .term, .terminal, .xterm, [data-code]";

const label = (el) => `${el.tagName.toLowerCase()}${[...el.classList].slice(0, 2).map((c) => "." + c).join("")}`;

/** The surface's opening, from the state the shots scenes use. */
const OPEN = {
  launcher: (S) => { S.drawer.value = 1; },
  shade: (S) => { S.panel.value = "notifications"; S.notif.value = true; },
  control: (S) => { S.panel.value = "control"; S.notif.value = true; },
  menu: async (S) => {
    const a = (await (await importShim("./bridge.ts")).powos.apps.list())[0];
    S.menu.value = { app: a, at: new DOMRect(innerWidth / 2 - 30, innerHeight * 0.35, 60, 60) };
  },
  home: () => {},
};

function drawn(el) {
  if (!el.isConnected) return false;
  const r = el.getBoundingClientRect();
  if (r.width < 2 || r.height < 2 || r.bottom < 0 || r.top > innerHeight) return false;
  const cs = getComputedStyle(el);
  return cs.visibility !== "hidden" && cs.display !== "none";
}

/** An animation running on [el] or around it, or an ancestor not yet at full opacity (a fade carrying it in). */
function moving(el, anims) {
  for (const a of anims) {
    const t = a.effect?.target;
    if (t && (t === el || t.contains(el)) && a.playState !== "finished") return true;
  }
  for (let e = el; e && e !== document.documentElement; e = e.parentElement) if (Number(getComputedStyle(e).opacity) < 0.99) return true;
  return false;
}

async function popins(open, S) {
  const added = [];
  const mo = new MutationObserver((ms) => {
    for (const m of ms) for (const n of m.addedNodes) if (n.nodeType === 1) added.push(n);
  });
  mo.observe(document.body, { childList: true, subtree: true });
  await open(S);
  const seen = new Set();
  const found = [];
  for (let f = 0; f < 40; f++) {
    await frame();
    const anims = document.getAnimations();
    for (const el of added.splice(0)) {
      // Only the root of what was added: its descendants appear with it.
      if (seen.has(el) || [...seen].some((s) => s.contains(el))) continue;
      seen.add(el);
      if (drawn(el) && !moving(el, anims)) found.push(label(el));
    }
  }
  mo.disconnect();
  return [...new Set(found)];
}

function mono() {
  const where = new Map();
  let count = 0;
  const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    const el = n.parentElement;
    if (!el || !n.textContent.trim() || el.closest(CODE) || !drawn(el)) continue;
    const first = getComputedStyle(el).fontFamily.split(",")[0];
    if (!MONO.test(first)) continue;
    count++;
    where.set(label(el), (where.get(label(el)) ?? 0) + 1);
  }
  return { count, where: [...where].sort((a, b) => b[1] - a[1]).slice(0, 8) };
}

export async function designLint(surface) {
  const S = await window.__gw.mod("./state.ts");
  await sleep(300);
  const p = await popins(OPEN[surface] ?? OPEN.home, S);
  await sleep(600);
  return { popins: p, mono: mono() };
}

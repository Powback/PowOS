/**
 * The design language's page probe (docs/DESIGN-LANGUAGE.md §4, §6), gate.mjs's design-lint-* runs: it returns what it
 * found and the gate prints it - failing on it for the surfaces in gate.mjs DESIGN_LINT_BLOCKING (the launcher), report-only
 * for the rest.
 *
 * - pop-ins: a surface is opened from state (as shots.mjs's scenes do) under a MutationObserver; every element added
 *   while it opens is read on its first frame - drawn (a box, visible, not transparent) with no animation running on
 *   it or an ancestor and no ancestor mid-fade is an element that appeared in a single frame, unless it paints nothing
 *   itself and all that's drawn in it comes in moving (comesIn).
 * - monospace: once the surface is at rest, every visible text whose font's first family is a monospace one, outside
 *   code (pre, code, kbd, samp, a terminal, a textarea), faded-out text and OWL widgets (unseen) - UI text is --font-ui.
 *
 * Returns { popins: [label...], mono: { count, where: [[label, n]...] } }.
 */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const frame = () => new Promise((r) => requestAnimationFrame(() => r()));
const MONO = /mono|courier|consolas|menlo/i;
const CODE = "pre, code, kbd, samp, textarea, .term, .terminal, .xterm, [data-code]";

const label = (el) => `${el.tagName.toLowerCase()}${[...el.classList].slice(0, 2).map((c) => "." + c).join("")}`;

/** The switcher up (?mode=recents), as shots.mjs's "switcher" scene opens it. */
async function showSwitcher() {
  const tasks = await (await importShim("./bridge.ts")).powos.tasks.list();
  window.__mockEvents.emit("recents.show", { open: true, from: 100, tasks });
}

/** Two web windows on home's first page (shots.mjs WINDOWS): Chrome, Files over it (id 2, focused). */
async function twoWindows(S) {
  const W = await importShim("./ui/webwindows.tsx");
  const p = S.pages.value[0];
  W.webWins.value = [
    { id: 1, key: "a:x", label: "Chrome", page: p, x: 20, y: 70, w: Math.round(innerWidth * 0.55), h: 420, live: true },
    { id: 2, key: "a:y", label: "Files", page: p, x: Math.round(innerWidth * 0.3), y: 260, w: Math.round(innerWidth * 0.5), h: 300, live: true },
  ];
  return W;
}

/** What's already on screen before the surface opens (not watched): the launcher, open and at rest, for its search. */
const BEFORE = {
  "launcher-search": async (S) => {
    S.drawer.value = 1;
    await sleep(800);
  },
  // Design wave 6: the switcher at rest, for its card menu; two web windows, for their tile menu and resize outline.
  "switcher-menu": async () => {
    await showSwitcher();
    await sleep(1000);
  },
  windows: async (S) => {
    await twoWindows(S);
    await sleep(600);
  },
  "windows-resize": async (S) => {
    await twoWindows(S);
    await sleep(600);
  },
};

/** The surface's opening, from the state the shots scenes use. */
const OPEN = {
  launcher: (S) => { S.drawer.value = 1; },
  // The launcher's search as it's typed (drawer.tsx SearchResults): its rows arrive on the spring, never in one frame.
  "launcher-search": (S) => { S.query.value = "s"; },
  shade: (S) => { S.panel.value = "notifications"; S.notif.value = true; },
  control: (S) => { S.panel.value = "control"; S.notif.value = true; },
  menu: async (S) => {
    const a = (await (await importShim("./bridge.ts")).powos.apps.list())[0];
    S.menu.value = { app: a, at: new DOMRect(innerWidth / 2 - 30, innerHeight * 0.35, 60, 60) };
  },
  home: () => {},
  // Design wave 6 (the switcher, web windows): the switcher rising, a card's menu (a tap on its icon), a window's tile
  // menu and its resize outline - each comes in on the spring (§6).
  switcher: showSwitcher,
  "switcher-menu": () => {
    const icon = document.querySelector(".recents .task:first-child .task-icon");
    const r = icon.getBoundingClientRect();
    const at = { bubbles: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, pointerId: 7, pointerType: "touch", isPrimary: true };
    icon.dispatchEvent(new PointerEvent("pointerdown", at));
    icon.dispatchEvent(new PointerEvent("pointerup", at));
  },
  windows: async () => { (await importShim("./ui/webwindows.tsx")).tileMenu.value = 2; },
  "windows-resize": async () => { (await importShim("./ui/webwindows.tsx")).resizeView.value = { id: 2, snapped: "w" }; },
};

function drawn(el) {
  if (!el.isConnected) return false;
  const r = el.getBoundingClientRect();
  if (r.width < 2 || r.height < 2 || r.bottom < 0 || r.top > innerHeight) return false;
  const cs = getComputedStyle(el);
  return cs.visibility !== "hidden" && cs.display !== "none";
}

/** Motion in time: not a scroll-driven one (the drawer list's edge fades, scroll-fade-t/-b: always "running", never moving it in). */
const timed = (a) => !a.timeline || a.timeline instanceof DocumentTimeline;

/** An animation running on [el] or around it, or an ancestor not yet at full opacity (a fade carrying it in). */
function moving(el, anims) {
  for (const a of anims.filter(timed)) {
    const t = a.effect?.target;
    if (t && (t === el || t.contains(el)) && a.playState !== "finished") return true;
  }
  for (let e = el; e && e !== document.documentElement; e = e.parentElement) if (Number(getComputedStyle(e).opacity) < 0.99) return true;
  return false;
}

/** [el] draws something of its own: a fill, an image, an edge, a shadow, a blur, or a text of its own. */
function paints(el) {
  const cs = getComputedStyle(el);
  const fill = !/^(transparent|rgba\(.*, 0\))$/.test(cs.backgroundColor);
  const edge = ["Top", "Right", "Bottom", "Left"].some((s) => parseFloat(cs[`border${s}Width`]) > 0 && !/^(transparent|rgba\(.*, 0\))$/.test(cs[`border${s}Color`]));
  const text = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim());
  return fill || edge || text || cs.backgroundImage !== "none" || cs.boxShadow !== "none" || (cs.backdropFilter ?? "none") !== "none";
}

/**
 * [el] comes in moving: animated itself (or carried by an ancestor's animation or fade) - or it draws nothing of its
 * own and everything drawn in it comes in moving (a bar whose glass and content are each animated: launchmorph.ts).
 */
function comesIn(el, anims) {
  if (moving(el, anims)) return true;
  if (paints(el)) return false;
  return [...el.children].filter(drawn).every((c) => comesIn(c, anims));
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
      if (drawn(el) && !comesIn(el, anims)) found.push(label(el));
    }
  }
  mo.disconnect();
  return [...new Set(found)];
}

/**
 * Text not seen: faded out (an ancestor at opacity ~0: home's pages under the open launcher) - or an OWL widget's, the
 * known exception (ui/owl.tsx OWL_FONT: they size text by counting characters until OWL can measure it; §4).
 */
function unseen(el) {
  if (el.closest(".owl")) return true;
  for (let e = el; e && e !== document.documentElement; e = e.parentElement) if (Number(getComputedStyle(e).opacity) < 0.05) return true;
  return false;
}

function mono() {
  const where = new Map();
  let count = 0;
  const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    const el = n.parentElement;
    if (!el || !n.textContent.trim() || el.closest(CODE) || !drawn(el) || unseen(el)) continue;
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
  await BEFORE[surface]?.(S);
  const p = await popins(OPEN[surface] ?? OPEN.home, S);
  await sleep(600);
  return { popins: p, mono: mono() };
}

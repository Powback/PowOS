/**
 * The pre-push gate's browser half (shell/dev/gate.sh runs it in a headless Chromium container): every page of the
 * shell - each mode app.tsx knows, as ShellHost loads them (index.html?mode=) - booted against the mock bridge, from
 * the origin and with the MIME types the phone's WebView gets (ShellHost.Client: .ts/.tsx as text/plain, the page
 * transpiling them). A page fails on any uncaught error, failed module load (a 404, a missing export, an import
 * cycle's "does not provide an export named"), unhandled rejection, or not reaching ready (window.__powosAlive, set
 * by app.tsx once its screen rendered) within READY_MS.
 *
 * Also, with /apps mounted (apps/install.sh): every page, glasses and widget entry of each PowOS app UI there
 * (/apps/<id>/powos-app.json + /apps/<id>/ui/), imported as the shell imports them (./_app/<id>/<entry>, the shell's
 * import map) - a module that doesn't load fails.
 *
 * Idle (IDLE_MS, default 2000; 0 skips it): once a shell page is ready and has settled (IDLE_WAIT_MS more, default
 * 3000), nothing on it may keep drawing - over IDLE_MS it must run no requestAnimationFrame callback, paint no layer
 * (CDP LayerTree.layerPainted) and have no infinite CSS/Web animation running. An idle home that draws costs the phone
 * its CPU and battery for as long as the screen is on (2026-10-21: ~60 compositor frames a second from a hidden page's
 * pulsing dots). The mock bridge's own timed events are paused for it (window.__powosMockQuiet).
 *
 * Mounted: /shell (the composed shell, read only), optionally /apps. Prints one line per page and exits 1 on any
 * failure; the reasons go to stdout as "FAIL <page>: <reason>".
 */
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import puppeteer from "puppeteer";

const ORIGIN = "https://shell.powos";
const ROOT = "/shell";
const APPS = "/apps";
const READY_MS = Number(process.env.READY_MS || 8000);
/** After ready: errors this soon after the first render are boot errors too (an effect throwing, a lazy import). */
const SETTLE_MS = Number(process.env.SETTLE_MS || 400);
const IDLE_MS = Number(process.env.IDLE_MS ?? 2000);
const IDLE_WAIT_MS = Number(process.env.IDLE_WAIT_MS || 3000);

/** As ShellHost.mime: what the phone serves, so a module the phone refuses is refused here. */
function mime(p) {
  const ext = p.slice(p.lastIndexOf(".") + 1).toLowerCase();
  return (
    {
      html: "text/html",
      js: "text/javascript",
      mjs: "text/javascript",
      ts: "text/plain",
      tsx: "text/plain",
      css: "text/css",
      json: "application/json",
      wasm: "application/wasm",
      svg: "image/svg+xml",
      png: "image/png",
      webp: "image/webp",
      woff2: "font/woff2",
      ttf: "font/ttf",
    }[ext] ?? "application/octet-stream"
  );
}

/** The modes app.tsx renders (`mode === "x"`), home first: a mode added there is checked without touching this. */
function modes() {
  const src = fs.readFileSync(path.join(ROOT, "app.tsx"), "utf8");
  const found = [...src.matchAll(/mode === "([a-z0-9-]+)"/g)].map((m) => m[1]);
  return ["home", ...new Set(found)];
}

/** The PowOS apps mounted at /apps: [{ id, entries }] - their page and widget entries, under ui/. */
function apps() {
  if (!fs.existsSync(APPS)) return [];
  return fs.readdirSync(APPS).flatMap((id) => {
    const mf = path.join(APPS, id, "powos-app.json");
    if (!fs.existsSync(mf)) return [];
    const m = JSON.parse(fs.readFileSync(mf, "utf8"));
    const entries = [m.page?.entry, m.glasses?.entry, ...(m.widgets ?? []).map((w) => w.entry)].filter(Boolean);
    return [{ id, entries }];
  });
}

/** The file a shell URL names (ShellHost.open, without the override folder: /shell is already composed), or null. */
function file(url) {
  const u = new URL(url);
  let p = decodeURIComponent(u.pathname).replace(/^\/+/, "") || "index.html";
  if (p.split("/").includes("..")) return null;
  if (p === "__gate_app.html") return { virtual: true };
  let f;
  if (p.startsWith("_app/")) {
    const [, id, ...rest] = p.split("/");
    f = path.join(APPS, id, "ui", rest.join("/"));
  } else f = path.join(ROOT, p);
  return fs.existsSync(f) && fs.statSync(f).isFile() ? { path: f, name: p } : null;
}

/** The app gate's page: index.html's head (the loader, the import map, the boot guard) and no app.tsx. */
function appPage() {
  const html = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
  const head = html.slice(0, html.indexOf("</head>")).replace(/<script type="module-shim"[^>]*><\/script>/g, "");
  return `${head}</head><body></body></html>`;
}

/**
 * A shell module's JS as index.html's fetch hook makes it (vendor/sucrase.js, its options): once per file per run,
 * and kept in /cache by source hash (gate.sh mounts ~/.cache/powos-gate/tx) so an unchanged file isn't transpiled again.
 */
const txRuns = new Map();
let sucrase;
async function transpiled(p) {
  const src = fs.readFileSync(p, "utf8");
  const key = createHash("sha1").update(src).digest("hex");
  if (!txRuns.has(key))
    txRuns.set(
      key,
      (async () => {
        const disk = fs.existsSync("/cache") ? path.join("/cache", key + ".js") : null;
        if (disk && fs.existsSync(disk)) return fs.readFileSync(disk, "utf8");
        sucrase ??= await import(path.join(ROOT, "vendor/sucrase.js"));
        const { code } = sucrase.transform(src, {
          transforms: ["typescript", "jsx"],
          jsxRuntime: "automatic",
          jsxImportSource: "preact",
          production: true,
          filePath: p,
        });
        if (disk) fs.writeFileSync(disk, code);
        return code;
      })(),
    );
  return txRuns.get(key);
}

/** Waits for [r]'s page to be up, then adds what [check] returns to its problems (a timeout said as the pages say it). */
async function whenReady(r, check) {
  await r.page.waitForFunction(() => window.__powosAlive === true || window.__powosBoot?.failed === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
  if (!(await r.page.evaluate(() => window.__powosAlive === true).catch(() => false))) {
    r.problems.push(`not ready (window.__powosAlive) within ${Date.now() - r.started} ms`);
    return { ...r, ready: false, ms: Date.now() - r.started };
  }
  r.problems.push(...(await check().catch((e) => [`evaluate: ${e.message.split("\n")[0]}`])));
  return { ...r, ready: true, ms: Date.now() - r.started };
}

/** In the page: steam (6x3) over fetch (3x3, the right half) on home's first page - merged, level, one surface? */
async function joinsCheck() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await importShim("./state.ts");
  const { powos } = await importShim("./bridge.ts");
  const h = await powos.home.get();
  for (const i of h.items) await powos.home.remove(i.key);
  const w = Math.min(6, h.columns || 6);
  // Home's first page (pages are 1-based; the wide layout maps it to the left half).
  const pg = h.pages[0] ?? 1;
  await powos.home.addPanel("agents", pg, { x: 0, y: 0, w, h: 3 });
  await powos.home.addPanel("recents", pg, { x: w - 3, y: 3, w: 3, h: 3 });
  S.page.value = 0;
  await sleep(800);
  const half = (parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--gap")) || 8) / 2;
  const tiles = [...document.querySelectorAll(".page:not(.away) .home-tile")];
  if (tiles.length !== 2) return [`${tiles.length} tiles on the page, not the 2 placed`];
  const [A, B] = tiles.map((t) => ({ t, cell: t.getBoundingClientRect(), face: t.querySelector(":scope > .tile").getBoundingClientRect() })).sort((p, q) => p.cell.top - q.cell.top);
  const near = (a, b) => Math.abs(a - b) <= 1;
  const seamBetween = [...document.querySelectorAll(".page:not(.away) .seam.bridge")].some((e) => {
    const r = e.getBoundingClientRect();
    return near(r.top, A.face.bottom) && near(r.bottom, B.face.top) && near(r.left, Math.max(A.face.left, B.face.left)) && near(r.right, Math.min(A.face.right, B.face.right));
  });
  const gap = B.face.top - A.face.bottom;
  return [
    !A.t.classList.contains("joined") || !B.t.classList.contains("joined") ? "the two aren't merged (no .joined)" : "",
    // The wide one's bottom: where an unjoined edge is (its free half level), not half a gutter lower.
    near(A.face.bottom, A.cell.bottom - half) ? "" : `the wide tile's bottom edge is ${Math.round(A.face.bottom - (A.cell.bottom - half))} px off its row line`,
    gap > 0.5 && !seamBetween ? `a ${Math.round(gap)} px gutter between them along the shared span (not one surface)` : "",
    near(A.face.right, B.face.right) ? "" : `their right edges differ by ${Math.round(A.face.right - B.face.right)} px`,
    document.querySelector(".page:not(.away) .seam.fillet") ? "" : "no rounded inner corner where the group turns",
  ].filter(Boolean);
}

/** The tiles on the page on screen, as "text@left,top,WxH", sorted. */
const tileRects = (page) =>
  page.evaluate(() =>
    [...document.querySelectorAll(".page:not(.away) .home-tile")]
      .map((t) => {
        const b = t.getBoundingClientRect();
        return `${(t.textContent || "").slice(0, 10)}@${Math.round(b.left)},${Math.round(b.top)},${Math.round(b.width)}x${Math.round(b.height)}`;
      })
      .sort(),
  );
const pause = (ms) => new Promise((ok) => setTimeout(ok, ms));
const viewTo = (page, v) => page.setViewport({ ...v, deviceScaleFactor: 1 });
/** The page as hidden / shown (an app in front of home), as the WebView says it. */
const hideAs = (page, hidden) =>
  page.evaluate((h) => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => h });
    Object.defineProperty(document, "visibilityState", { configurable: true, get: () => (h ? "hidden" : "visible") });
    document.dispatchEvent(new Event("visibilitychange"));
  }, hidden);
/** Home's column count: the other's (the wide layout's, [wide]) or its own again. */
const columnsAs = (page, wide) =>
  page.evaluate(async (k) => {
    const S = await importShim("./state.ts");
    if (!window.__cols) window.__cols = S.home.value.columns;
    S.home.value = { ...S.home.value, columns: k ? window.__cols * 2 + 1 : window.__cols };
  }, wide);

/** An app in front at [from]: home hidden, resized there and back (the way back with no resize event), then shown. */
/** The shade-overpull case's tools, on the page (window.__op): waits, what's measured, a finger's drag. */
async function overpullKit() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const until = async (f, what, ms = 15000) => {
    const t0 = performance.now();
    while (!f()) {
      if (performance.now() - t0 > ms) throw new Error(`timed out: ${what}`);
      await sleep(20);
    }
  };
  const frames = (n = 2) => new Promise((ok) => { const step = (k) => (k ? requestAnimationFrame(() => step(k - 1)) : ok()); step(n); });
  const cells = () => [...document.querySelectorAll(".cc3-list .cc3-cell")];
  const shown = () => cells().filter((e) => e.getClientRects().length && Number(getComputedStyle(e).opacity) > 0.05).length;
  const UNDER = ".panel-body.together .cc ~ .notif-bar";
  const under = () => document.querySelector(UNDER)?.getBoundingClientRect().top ?? NaN;
  const row = () => cells().slice(0, 6).map((e) => Math.round(e.getBoundingClientRect().top)).join();
  const still = () => !document.getAnimations().some((a) => a.playState === "running" && a.effect?.target?.closest?.(".notif-panel"));
  const at = { x: 0, y: 0 };
  const P = (type, y) =>
    document.querySelector(".cc > .notif-bar").dispatchEvent(
      new PointerEvent(type, { bubbles: true, clientX: at.x, clientY: y, pointerId: 1, isPrimary: true, pointerType: "mouse", buttons: type === "pointerup" ? 0 : 1 }),
    );
  // A finger down on the control center's header, moved [dy] in six frames, [check]ed there, held still, let go.
  const drag = async (dy, check) => {
    const b = document.querySelector(".cc > .notif-bar").getBoundingClientRect();
    Object.assign(at, { x: b.left + b.width / 2, y: b.top + b.height / 2 });
    P("pointerdown", at.y);
    for (let i = 1; i <= 6; i++) {
      P("pointermove", at.y + (dy * i) / 6);
      await frames(1);
    }
    await frames(2);
    await check?.();
    await sleep(120);
    P("pointermove", at.y + dy + Math.sign(dy));
    P("pointerup", at.y + dy + Math.sign(dy));
    await until(() => !document.querySelector(".cc3-grid.cc-peek"), "the pull let go");
    await frames(2);
    await until(still, "settled after the pull");
  };
  const S = await importShim("./state.ts");
  S.ccV3.value = "v3";
  S.notif.value = true;
  try {
    await until(() => shown() >= 6 && document.querySelector(UNDER), "the row and the notifications' header");
    await until(still, "the panel open and settled");
  } catch (e) {
    return [e.message];
  }
  window.__op = { sleep, frames, shown, under, row, still, drag, n0: shown(), under0: under(), row0: row() };
  return [];
}

/** Part of the way: under the control center follows the finger 1:1, the rest starts to show; let go, all back. */
async function overpullShort() {
  const o = window.__op;
  const fails = [];
  await o.drag(30, () => {
    const d = o.under() - o.under0;
    if (Math.abs(d - 30) > 3) fails.push(`pulled 30 px further, what's under the control center moved ${Math.round(d)} px`);
    if (o.shown() <= o.n0) fails.push(`pulled 30 px further, no more toggles show (${o.shown()})`);
    if (o.row() !== o.row0) fails.push(`the first row moved on the pull: ${o.row0} -> ${o.row()}`);
  });
  if (Math.abs(o.under() - o.under0) > 1) fails.push(`let go short, what's under the control center is ${Math.round(o.under() - o.under0)} px off its place`);
  if (o.shown() !== o.n0) fails.push(`let go short, ${o.shown()} toggles show, not ${o.n0}`);
  return fails;
}

/** All the way: the rest shown and laid out, what's under it below the rest, the row still. */
async function overpullExpand() {
  const o = window.__op;
  await o.drag(260);
  o.h = o.under() - o.under0;
  const fails = [];
  if (!document.querySelector(".cc3-list.whole")) fails.push("pulled 260 px further, the rest isn't shown");
  if (o.h < 40) fails.push(`expanded, what's under the control center moved only ${Math.round(o.h)} px`);
  if (o.row() !== o.row0) fails.push(`the first row moved on the expand: ${o.row0} -> ${o.row()}`);
  return fails;
}

/** Up at the list's end folds it: on the way what's under it follows the finger up; folded, all where it was. */
async function overpullFold() {
  const o = window.__op;
  const fails = [];
  const list = document.querySelector(".panel-body.together .notif-list");
  list.scrollTop = list.scrollHeight;
  await o.frames(2);
  const from = o.under();
  await o.drag(-80, () => {
    const d = o.under() - from;
    if (Math.abs(d + Math.min(80, o.h)) > 3) fails.push(`folding 80 px, what's under the control center moved ${Math.round(d)} px`);
  });
  if (document.querySelector(".cc3-list.whole") || o.shown() !== o.n0) fails.push(`pulled up 80 px, still ${o.shown()} toggles shown`);
  list.scrollTop = 0;
  await o.frames(2);
  if (Math.abs(o.under() - o.under0) > 1) fails.push(`folded, what's under the control center is ${Math.round(o.under() - o.under0)} px off its place`);
  if (o.row() !== o.row0) fails.push(`folded, the first row isn't where it was: ${o.row0} -> ${o.row()}`);
  return fails;
}

/** At rest: no animation in the panel, nothing the pull left inline. */
async function overpullRest() {
  const o = window.__op;
  await o.sleep(400);
  const left = [...document.querySelectorAll(".notif-panel [style]")].filter((e) => e.style.translate || e.style.getPropertyValue("--cc-k"));
  return [...(o.still() ? [] : ["an animation still runs in the panel at rest"]), ...(left.length ? [`the pull left inline values on ${left.length} elements`] : [])];
}

async function backFromApp(page, to, from) {
  await hideAs(page, true);
  await viewTo(page, from);
  await pause(600);
  await page.evaluate(() => {
    window.__eatResize = (e) => e.stopImmediatePropagation();
    addEventListener("resize", window.__eatResize, { capture: true });
  });
  await viewTo(page, to);
  await pause(300);
  await page.evaluate(() => removeEventListener("resize", window.__eatResize, { capture: true }));
  await hideAs(page, false);
  await pause(1200);
}

/** Shown again still at the app's size (its last frame), then the window back at [to] with no resize event. */
async function shownAtAppSize(page, to, from) {
  await hideAs(page, true);
  await viewTo(page, from);
  await pause(300);
  await hideAs(page, false);
  await pause(600);
  await page.evaluate(() => {
    window.__eatResize = (e) => e.stopImmediatePropagation();
    addEventListener("resize", window.__eatResize, { capture: true });
  });
  await viewTo(page, to);
  await pause(1200);
  await page.evaluate(() => removeEventListener("resize", window.__eatResize, { capture: true }));
}

/** Relaid in the other column count while measured at a size, then in its own at that same size (the phone's race). */
async function otherColumns(page, to) {
  await columnsAs(page, true);
  await viewTo(page, { width: to.width, height: to.height - 1 });
  await pause(400);
  await viewTo(page, to);
  await pause(400);
  await columnsAs(page, false);
  await pause(600);
}

/** The relayout case: each way of getting back to [to] must give a fresh layout's tiles and a full-width grid. */
async function relayout(page, to, from) {
  await pause(800);
  const fresh = await tileRects(page);
  if (!fresh.length) return ["no tiles laid out"];
  const steps = [
    [`back from an app at ${from.width}x${from.height}`, () => backFromApp(page, to, from)],
    [`turned ${from.width}x${from.height} and back`, async () => (await viewTo(page, from), await pause(800), await viewTo(page, to), await pause(1200))],
    ["relaid in its own columns at the same size", () => otherColumns(page, to)],
    [`shown at ${from.width}x${from.height}, then back with no resize event`, () => shownAtAppSize(page, to, from)],
  ];
  const bad = [];
  for (const [what, step] of steps) {
    await step();
    const now = await tileRects(page);
    if (now.join() !== fresh.join()) bad.push(`${what}: tiles not where a fresh layout puts them (${now.filter((x) => !fresh.includes(x)).slice(0, 2).join("; ")})`);
  }
  const cells = await page.evaluate(async () => {
    const S = await importShim("./state.ts");
    const g = (await importShim("./ui/grid.tsx")).geometry.value;
    return { cols: S.home.value.columns, span: g.cellW * S.home.value.columns, across: g.width - 2 * g.pad };
  });
  if (Math.abs(cells.span - cells.across) > 1) bad.push(`the grid's cells span ${Math.round(cells.span)} px in ${cells.cols} columns, not its ${Math.round(cells.across)} px width`);
  return bad;
}

/**
 * In the page, unfolded: home is ONE wide page (hosts/wide.ts). The host's layout is backed up before the first wide
 * cells are written; every tile shows where the side-by-side pages had it (x + 7 on the right); a tile placed across
 * the middle stays there; one bar at the foot - the pinned dock left of the search pill, the recent apps right of it.
 */
async function wideMigrated() {
  const S = await importShim("./state.ts");
  const { powos } = await importShim("./bridge.ts");
  const host = (await powos.store.get("home.wide.backup"))?.home;
  if (!host?.items?.length) return ["no backup of the host's layout in the store (home.wide.backup)"];
  const pages = [...host.pages].sort((a, b) => a - b);
  const now = new Map(S.home.value.items.map((i) => [i.key, i.cell ? `${i.cell.x},${i.cell.y}` : "none"]));
  const was = (it) => `${it.cell.x + pages.indexOf(it.page) * (host.columns + 1)},${it.cell.y}`;
  return host.items
    .filter((i) => i.cell && pages.indexOf(i.page) < 2 && now.get(i.key) !== was(i))
    .map((i) => `${i.key} moved: at ${now.get(i.key)}, side by side it was ${was(i)}`);
}

/** In the page, unfolded: a tile placed across the middle of the wide page stays there (one page, not two halves). */
async function wideAcross() {
  const S = await importShim("./state.ts");
  const { powos } = await importShim("./bridge.ts");
  const tile = S.home.value.items.find((i) => i.kind === "widget" && i.cell?.w === 3);
  if (!tile) return ["no 3-wide widget to place across the middle"];
  await powos.home.place(tile.key, { ...tile.cell, x: 5, y: 12 }, 1);
  await new Promise((ok) => setTimeout(ok, 400));
  const c = S.home.value.items.find((i) => i.key === tile.key)?.cell;
  return c?.x === 5 && c.y === 12 ? [] : [`${tile.key} placed across the middle at 5,12 shows at ${c?.x},${c?.y}`];
}

/** In the page: the wide screen's one bar - dock | search pill | recent apps, left to right, on one line. */
async function wideBar() {
  const S = await importShim("./state.ts");
  // Some pinned apps (the mock pins none), the recent ones left for the right end.
  if (!S.dock.value.length) S.setDock([...S.byKey.value.keys()].slice(0, 4));
  await new Promise((ok) => setTimeout(ok, 300));
  const fails = [];
  const box = (q) => document.querySelector(q)?.getBoundingClientRect();
  const [dock, pill, tray] = [box(".home.wide > .dock:not(.dock-tray) .app"), box(".home.wide .bar-pill"), box(".home.wide > .dock-tray .app")];
  const lacks = [[dock, "the dock"], [pill, "the pill"], [tray, "the recent apps"]].filter(([r]) => !r).map(([, n]) => n);
  if (lacks.length) return [`the wide bar lacks ${lacks.join(", ")}`];
  if (!(dock.right <= pill.left && pill.right <= tray.left)) fails.push("the wide bar isn't dock | search | recent apps, left to right");
  const mid = (r) => r.top + r.height / 2;
  if (Math.abs(mid(dock) - mid(pill)) > 4 || Math.abs(mid(tray) - mid(pill)) > 4) fails.push("the wide bar's dock, pill and recent apps aren't on one line");
  return fails;
}

/**
 * In the page, in edit mode (the user, 2026-10-22, three reports): the search bar is ON the grid as a tile like the
 * others, the dock stays in view; moved, it becomes the search widget there (and leaves the foot); resized, it keeps
 * the new size. Folded and unfolded.
 */
async function editSearchCheck() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await importShim("./state.ts");
  const shown = (el) => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility === "visible";
  S.editing.value = true;
  await sleep(400);
  const fails = [];
  const tile = document.querySelector('.home-tile[data-key="panel:search"]');
  if (!shown(tile?.querySelector(".bar-pill"))) fails.push("edit mode: no search bar tile on the grid");
  if (!shown(document.querySelector(".home > .dock .app"))) fails.push("edit mode: the dock isn't in view");
  if (shown(document.querySelector(".home > .bar"))) fails.push("edit mode: the foot's search bar still shows beside its tile");
  return fails;
}

/** In the page, in edit mode after editSearchCheck: the search bar's tile moved and resized becomes the search widget. */
async function editSearchMoved() {
  const S = await importShim("./state.ts");
  const W = await importShim("./ui/searchwidget.tsx");
  const was = W.footSearch.value;
  if (!was) return ["edit mode: no foot search item (searchwidget.tsx footSearch)"];
  const to = { x: 0, y: Math.max(0, was.cell.y - 1), w: 2, h: 1 };
  await W.placeItem("panel:search", to, was.page);
  await new Promise((ok) => setTimeout(ok, 500));
  S.editing.value = false;
  const real = S.home.value.items.find((i) => i.kind === "panel" && i.name === "search");
  const at = JSON.stringify(real?.cell ?? null);
  return at === JSON.stringify(to) ? [] : [`moved and resized to ${JSON.stringify(to)}, the search widget is at ${at}`];
}

/**
 * In the page, edit mode (the user, 2026-10-22): a finger held on empty space then dragged draws the selection
 * rectangle and picks the two app tiles it touches; a quick sideways swipe there draws none (the page swipe's); out of
 * edit mode none either. Mock home only (synthetic pointers on the headless page).
 */
async function marqueeCheck() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await importShim("./state.ts");
  const H = await importShim("./ui/homeselect.ts");
  const G = await importShim("./ui/grid.tsx");
  const fire = (type, x, y) => (type === "pointerdown" ? document.elementFromPoint(x, y) : document.querySelector(".pages")).dispatchEvent(new PointerEvent(type, { pointerId: 7, pointerType: "touch", clientX: x, clientY: y, bubbles: true, isPrimary: true }));
  const empty = (x, y) => document.elementFromPoint(x, y)?.matches?.(".page, .page-track, .pages");
  const n = S.pages.value[S.page.value];
  const apps = S.home.value.items.filter((i) => i.page === n && i.kind === "app" && i.cell);
  const [a, b] = apps.sort((p, q) => p.cell.y - q.cell.y || p.cell.x - q.cell.x);
  if (!b) return ["marquee: the mock's page has no two apps"];
  const ra = document.querySelector(`.home-tile[data-key="${a.key}"]`).getBoundingClientRect();
  const rb = document.querySelector(`.home-tile[data-key="${b.key}"]`).getBoundingClientRect();
  const ch = G.geometry.value.cellH;
  const start = [[ra.left + 4, Math.max(ra.bottom, rb.bottom) + ch / 2], [ra.left + 4, Math.min(ra.top, rb.top) - ch / 2]].find(([x, y]) => empty(x, y));
  if (!start) return ["marquee: no empty spot beside the two apps to start from"];
  const fails = [];
  const draw = async ([x0, y0], [x1, y1], dwell) => {
    fire("pointerdown", x0, y0);
    await sleep(dwell);
    for (let k = 1; k <= 6; k++) fire("pointermove", x0 + ((x1 - x0) * k) / 6, y0 + ((y1 - y0) * k) / 6);
    await sleep(60);
    const drawn = !!document.querySelector(".pages .marquee");
    fire("pointerup", x1, y1);
    await sleep(80);
    return drawn;
  };
  const end = [rb.right - 4, rb.top + rb.height / 2];
  if (await draw(start, end, 260)) fails.push("not editing: a drag on empty space drew a selection rectangle");
  S.editing.value = true;
  await sleep(300);
  if (!(await draw(start, end, 260))) fails.push("edit mode: a held drag on empty space drew no selection rectangle");
  if (document.querySelector(".pages .marquee")) fails.push("edit mode: the selection rectangle stays after the finger lifts");
  if (!(H.chosen.value.includes(a.key) && H.chosen.value.includes(b.key))) fails.push(`edit mode: the rectangle over ${a.key} and ${b.key} picked [${H.chosen.value}]`);
  if (document.querySelectorAll(".home-tile.chosen").length < 2) fails.push("edit mode: the picked tiles aren't marked");
  const picked = H.chosen.value;
  await draw(start, [start[0] + 90, start[1] + 2], 0);
  if (H.chosen.value.join() !== picked.join()) fails.push("edit mode: a quick sideways swipe on empty space changed the picked tiles (it's the page swipe's)");
  return fails;
}

/**
 * In the page, after marqueeCheck (two apps picked): one of them long-pressed and dragged moves both by the same whole
 * cells, the others stay; then a tap on one puts it back (unpicked).
 */
async function partyMoveCheck() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await importShim("./state.ts");
  const H = await importShim("./ui/homeselect.ts");
  const G = await importShim("./ui/grid.tsx");
  const fire = (el, type, x, y) => el.dispatchEvent(new PointerEvent(type, { pointerId: 8, pointerType: "touch", clientX: x, clientY: y, bubbles: true, isPrimary: true }));
  const items = () => S.home.value.items.filter((i) => i.page === S.pages.value[S.page.value] && i.cell);
  const party = items().filter((i) => H.chosen.value.includes(i.key));
  if (party.length < 2) return ["group move: fewer than two picked tiles to move"];
  const rows = G.geometry.value.rows;
  const cellsOf = (c) => Array.from({ length: c.w * c.h }, (_, k) => `${c.x + (k % c.w)},${c.y + Math.floor(k / c.w)}`);
  const taken = new Set(items().filter((i) => !party.includes(i)).flatMap((i) => cellsOf(i.resizable ? i.cell : { ...i.cell, w: 1, h: 1 })));
  const fits = (dy) => party.every((i) => i.cell.y + dy < rows && !taken.has(`${i.cell.x},${i.cell.y + dy}`));
  const dy = [2, 3, 4, 1].find(fits);
  if (!dy) return ["group move: no free row below the picked tiles in the mock"];
  const was = new Map(items().map((i) => [i.key, `${i.cell.x},${i.cell.y}`]));
  const lead = document.querySelector(`.home-tile[data-key="${party[0].key}"]`);
  const r = lead.getBoundingClientRect();
  const [x, y] = [r.left + r.width / 2, r.top + r.height / 2];
  fire(lead, "pointerdown", x, y);
  await sleep(520);
  const pages = document.querySelector(".pages");
  for (let k = 1; k <= 8; k++) fire(pages, "pointermove", x, y + (dy * G.geometry.value.cellH * k) / 8);
  await sleep(60);
  const ghosts = document.querySelectorAll(".carried").length;
  fire(pages, "pointerup", x, y + dy * G.geometry.value.cellH);
  await sleep(500);
  const fails = ghosts < party.length ? [`group move: ${ghosts} carried tiles under the finger for ${party.length} picked`] : [];
  const wanted = (i) => {
    const [x0, y0] = was.get(i.key).split(",").map(Number);
    return party.some((p) => p.key === i.key) ? `${x0},${y0 + dy}` : `${x0},${y0}`;
  };
  fails.push(...items().filter((i) => `${i.cell.x},${i.cell.y}` !== wanted(i)).map((i) => `group move by ${dy} rows: ${i.key} at ${i.cell.x},${i.cell.y}, expected ${wanted(i)}`));
  if (document.querySelector(".carried, .pages .drop-spot")) fails.push("group move: a carried tile or drop spot stays after the drop");
  const tile = document.querySelector(`.home-tile[data-key="${party[0].key}"]`);
  const one = tile.getBoundingClientRect();
  fire(tile, "pointerdown", one.left + 8, one.top + 8);
  fire(tile, "pointerup", one.left + 8, one.top + 8);
  await sleep(100);
  if (H.chosen.value.includes(party[0].key)) fails.push("edit mode: a tap on a picked tile didn't put it back");
  return fails;
}

/**
 * In the page: floating windows on home's pages (ui/desktops.ts) - the host stubbed (the mock has no floating
 * windows), two pages. A window opens on the page on screen; swiping pages hides the other page's windows
 * (floating.desktop's list); a window brought back from the dock (windows.raised) takes home to its page; one let go
 * at a screen edge (windows.edge) moves to the next page with home.
 */
async function desktopsCheck() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await importShim("./state.ts");
  const D = await importShim("./ui/desktops.ts");
  const { powos } = await importShim("./bridge.ts");
  powos.floating = { list: async () => [], restore: async () => true, desktop: async (h) => ((window.__hid = h.join()), true) };
  if (S.pages.value.length < 2) await powos.home.addPanel("recents", Math.max(...S.pages.value) + 1, { x: 0, y: 0, w: 3, h: 3 });
  await sleep(300);
  if (!D.ready()) return ["ui/desktops.ts never started (app.tsx startDesktops)"];
  const [p0, p1] = S.pages.value;
  const win = (id) => ({ id, pkg: `gate.app${id}`, label: `App ${id}`, minimised: false });
  const fails = [];
  const expect = async (what, hid) => {
    await sleep(150);
    if ((window.__hid ?? "") !== hid) fails.push(`${what}: hidden [${window.__hid}], not [${hid}]`);
  };
  S.page.value = 0;
  S.windows.value = [win(101)];
  await expect("a window opened on page 1", "");
  if (D.placed.value[101] !== p0) fails.push(`the window opened on page 1 was put on page ${D.placed.value[101]}, not ${p0}`);
  S.page.value = 1;
  await expect("swiped to page 2", "101");
  S.windows.value = [win(102), win(101)];
  await expect("a window opened on page 2", "101");
  if (D.placed.value[102] !== p1) fails.push(`the window opened on page 2 was put on page ${D.placed.value[102]}, not ${p1}`);
  S.page.value = 0;
  await expect("back on page 1", "102");
  window.__mockEvents.emit("windows.raised", 102);
  await sleep(150);
  if (S.page.value !== 1) fails.push(`a window of page 2 brought back from the dock left home on page ${S.page.value + 1}`);
  await expect("its page shown after windows.raised", "101");
  const kept = await powos.store.get("home.windows");
  if (kept?.[101] !== p0 || kept?.[102] !== p1) fails.push(`not stored per page: ${JSON.stringify(kept)}`);
  S.page.value = 0;
  return fails;
}

/** In the page, after desktopsCheck: a window let go at a screen edge (windows.edge) goes to the next page with home. */
async function desktopsEdge() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await importShim("./state.ts");
  const D = await importShim("./ui/desktops.ts");
  const { powos } = await importShim("./bridge.ts");
  const [, p1] = S.pages.value;
  const fails = [];
  const expect = async (what, hid) => {
    await sleep(150);
    if ((window.__hid ?? "") !== hid) fails.push(`${what}: hidden [${window.__hid}], not [${hid}]`);
  };
  // Window 101 (page 1) let go at the right edge while page 1 shows: it and home go to page 2, never hidden on the way.
  S.page.value = 0;
  await expect("page 1 again", "102");
  const sent = [];
  powos.floating.desktop = async (h) => (sent.push(h.join()), (window.__hid = h.join()), true);
  window.__mockEvents.emit("windows.edge", { id: 101, side: 1 });
  await expect("101 dropped on the right edge", "");
  if (S.page.value !== 1 || D.placed.value[101] !== p1) fails.push(`an edge drop left home on page ${S.page.value + 1}, the window on ${D.placed.value[101]}`);
  if (sent.some((h) => h.split(",").includes("101"))) fails.push(`the dropped window was hidden on its way to the next page (${sent.join(" | ")})`);
  window.__mockEvents.emit("windows.edge", { id: 101, side: 1 });
  await sleep(150);
  if (S.pages.value.length === 2 && S.page.value !== 1) fails.push("a drop at the right edge of the last page moved home");
  window.__mockEvents.emit("windows.edge", { id: 101, side: -1 });
  await expect("101 dropped on the left edge", "102");
  return fails;
}

/**
 * In the page, after desktopsEdge: the dock's taps are a taskbar's (ui/desktops.ts dockTap; the user, 2026-10-22) - the
 * app of the window in front: minimised; minimised, away or under another window: brought back (the host's launch
 * restores it); no window: launched. And home tells the host where its bottom bar starts (windows.area), above which
 * windows open and maximise.
 */
async function dockTapCheck() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await importShim("./state.ts");
  const D = await importShim("./ui/desktops.ts");
  const { powos } = await importShim("./bridge.ts");
  const fails = [];
  const did = [];
  let area = null;
  powos.floating.minimise = async (id) => (did.push(`min ${id}`), true);
  powos.floating.area = async (top) => ((area = top), true);
  const launchWas = powos.apps.launch;
  powos.apps.launch = async (key) => void did.push(`launch ${key}`);
  const win = (id, extra = {}) => ({ id, pkg: `gate.app${id}`, label: `App ${id}`, minimised: false, ...extra });
  const tap = async (key, want, what) => {
    did.length = 0;
    await D.dockTap(key);
    await sleep(50);
    if (did.join() !== want) fails.push(`${what}: [${did.join()}], not [${want}]`);
  };
  try {
    S.windows.value = [win(101), win(102)];
    await tap("a:gate.app101/.Main", "min 101", "its window in front");
    await tap("a:gate.app102/.Main", "launch a:gate.app102/.Main", "its window under another");
    S.windows.value = [win(102), win(101, { minimised: true })];
    await tap("a:gate.app101/.Main", "launch a:gate.app101/.Main", "its window minimised");
    S.windows.value = [win(101, { away: true }), win(102)];
    await tap("a:gate.app101/.Main", "launch a:gate.app101/.Main", "its window on another page");
    await tap("a:gate.app103/.Main", "launch a:gate.app103/.Main", "no window");
    // The dock's own cells tap through dockTap: a pinned app's cell, its window in front, minimises it.
    const cell = document.querySelector('.dock .app[data-key^="a:"]');
    if (!cell) fails.push("no Android app in the dock to tap");
    else {
      const key = cell.dataset.key;
      S.windows.value = [{ id: 201, pkg: key.slice(2).split("/")[0], label: "Docked", minimised: false }];
      await sleep(50);
      did.length = 0;
      const r = cell.getBoundingClientRect();
      const at = { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, bubbles: true, pointerId: 7, button: 0 };
      cell.dispatchEvent(new PointerEvent("pointerdown", at));
      cell.dispatchEvent(new PointerEvent("pointerup", at));
      await sleep(100);
      if (did.join() !== "min 201") fails.push(`a tap on the dock's ${key}, its window in front: [${did.join()}], not [min 201]`);
    }
    dispatchEvent(new Event("resize"));
    await sleep(200);
    const bar = Math.min(...[...document.querySelectorAll(".home > .bar, .home > .dock")].map((e) => e.getBoundingClientRect()).filter((r) => r.height > 0).map((r) => r.top));
    if (area !== null && Math.abs(area - bar) > 1) fails.push(`windows.area told ${area}, the bottom bar starts at ${Math.round(bar)}`);
    if (area === null && D.barTop() === null) fails.push("home found no bottom bar to keep windows above (windows.area never told)");
    if (D.barTop() !== null && (D.barTop() < innerHeight / 2 || D.barTop() > innerHeight)) fails.push(`the bottom bar's top ${D.barTop()} isn't in the lower half of ${innerHeight}`);
  } finally {
    powos.apps.launch = launchWas;
    S.windows.value = [];
  }
  return fails;
}

/** In the page, loaded afresh after desktopsCheck: the stored windows go back on their pages (page 2's hidden). */
async function desktopsReloaded() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await importShim("./state.ts");
  const D = await importShim("./ui/desktops.ts");
  const { powos } = await importShim("./bridge.ts");
  const t0 = performance.now();
  while (!D.ready() && performance.now() - t0 < 5000) await sleep(50);
  // The mock's layout isn't kept across a reload (the phone's is): page 2 again, as desktopsCheck made it.
  const kept = await powos.store.get("home.windows");
  if (S.pages.value.length < 2) await powos.home.addPanel("recents", kept?.[102] ?? 2, { x: 0, y: 0, w: 3, h: 3 });
  await sleep(300);
  powos.floating = { list: async () => [], restore: async () => true, desktop: async (h) => ((window.__hid = h.join()), true) };
  S.page.value = 0;
  S.windows.value = [101, 102].map((id) => ({ id, pkg: `gate.app${id}`, label: `App ${id}`, minimised: false }));
  await sleep(200);
  return window.__hid === "102" ? [] : [`after a reload on page 1, hidden [${window.__hid}], not page 2's [102] (placement not kept: pages ${S.pages.value}, ${JSON.stringify(D.placed.value)})`];
}

async function open(browser, url, name, viewport = { width: 412, height: 915 }) {
  // A context (a window) of its own: tabs side by side in one window are hidden but the front one - no frames.
  const page = await (await browser.createBrowserContext()).newPage();
  await page.setViewport({ ...viewport, deviceScaleFactor: 1 });
  const problems = [];
  const warnings = [];
  await page.setRequestInterception(true);
  page.on("request", (req) => {
    const url = req.url();
    if (!url.startsWith(ORIGIN + "/")) {
      // Off the origin (a mock's socket, a font): never the network, from a gate.
      return url.startsWith("data:") || url.startsWith("blob:") ? req.continue() : req.abort();
    }
    // The shared transpile (see transpiled()): a module's JS, once for every page of the run.
    if (url.includes("__gate_js=1")) {
      const t = file(url.replace(/[?&]__gate_js=1$/, ""));
      if (!t || t.virtual) return req.respond({ status: 404, contentType: "text/plain", body: "" });
      return transpiled(t.path).then(
        (code) => req.respond({ status: 200, contentType: "application/javascript", body: code, headers: { "Cache-Control": "no-store" } }),
        (e) => req.respond({ status: 500, contentType: "text/plain", body: String(e?.message ?? e) }),
      );
    }
    const f = file(url);
    if (f?.virtual) return req.respond({ status: 200, contentType: "text/html", body: appPage() });
    if (!f) return req.respond({ status: 404, contentType: "text/plain", body: "" });
    req.respond({ status: 200, contentType: mime(f.name), body: fs.readFileSync(f.path), headers: { "Cache-Control": "no-store" } });
  });
  page.on("response", (res) => {
    const u = res.url();
    // A module that isn't there: es-module-shims reports it too, this names the file.
    if (res.status() >= 400 && /\.(m?js|tsx?|css)(\?|$)/.test(u) && !u.includes("__gate_js=1")) problems.push(`${res.status()} ${u.replace(ORIGIN + "/", "")}`);
  });
  // Uncaught errors: the boot guard (index.html) records them with their file - these only when it didn't (no guard).
  const uncaught = [];
  page.on("pageerror", (e) => uncaught.push(`uncaught: ${e.message.split("\n")[0]}`));
  page.on("console", (m) => {
    if (m.type() !== "error") return;
    const text = m.text();
    // Module-loading failures es-module-shims logs (its onerror's default is console.error) are failures; the rest of
    // the console's errors are the mock's business - listed, not fatal.
    if (/^powos-shell-error /.test(text)) return;
    if (/does not provide an export|Unsupported Content-Type|Unable to fetch|SyntaxError|ReferenceError|TypeError|before initialization/.test(text))
      problems.push(`console: ${text.split("\n")[0]}`);
    else if (!/Failed to load resource|^JSHandle@|^powos-shell-error /.test(text)) warnings.push(text.split("\n")[0]);
  });
  // The page's module transpile through the gate's shared one (transpiled()): index.html's fetch hook, as it sets it,
  // asks for "<file>?__gate_js=1" - the same sucrase build and options, run once per file for all pages and kept on
  // disk by source hash across runs, instead of once per page (14 pages each transpiling the whole shell). A source
  // the shared transpile fails on falls back to the page's own hook, which reports it as on the phone.
  if (process.env.GATE_SHARED_TX !== "0")
    await page.evaluateOnNewDocument(() => {
      let opts;
      Object.defineProperty(window, "esmsInitOptions", {
        configurable: true,
        get: () => opts,
        set(v) {
          const own = v?.fetch;
          if (own)
            v.fetch = async (url, options) => {
              if (!/\.tsx?(\?|$)/.test(url)) return own(url, options);
              const res = await fetch(url + (url.includes("?") ? "&" : "?") + "__gate_js=1");
              if (!res.ok) return own(url, options);
              return new Response(new Blob([(await res.text()) + "\n//# sourceURL=" + url], { type: "application/javascript" }));
            };
          opts = v;
        },
      });
    });
  // Counts the page's requestAnimationFrame callbacks (the idle check): counted as they run, nothing else changes.
  await page.evaluateOnNewDocument(() => {
    const raf = window.requestAnimationFrame.bind(window);
    window.__gateRaf = 0;
    window.requestAnimationFrame = (cb) => raf((t) => (window.__gateRaf++, cb(t)));
  });
  const started = Date.now();
  await page.goto(url, { waitUntil: "domcontentloaded" }).catch((e) => problems.push(`navigation: ${e.message}`));
  return { page, name, problems, warnings, uncaught, started };
}

/** Waits for the page's ready (or [check]), then collects the boot guard's own record of its errors. */
async function settle(run, check) {
  const { page } = run;
  let ready = false;
  try {
    await page.waitForFunction(check, { timeout: READY_MS, polling: 50 });
    ready = true;
  } catch {}
  const ms = Date.now() - run.started;
  if (ready) await new Promise((r) => setTimeout(r, SETTLE_MS));
  const guard = await page.evaluate(() => window.__powosBoot?.errors ?? []).catch(() => []);
  if (!guard.length) run.problems.push(...run.uncaught);
  for (const e of guard) run.problems.push(`${e.kind}: ${e.message}${e.file ? ` (${e.file}${e.line ? ":" + e.line : ""})` : ""}`);
  const alive = await page.evaluate(() => window.__powosAlive === true).catch(() => false);
  if (!ready || (!alive && run.name.indexOf("app ") !== 0)) run.problems.push(`not ready (window.__powosAlive) within ${ms} ms`);
  // What the page must still have once it's up: a feature gone with a redesign fails here, not in the user's hand.
  if (ready && MUST[run.name]) for (const [sel, what] of MUST[run.name]) if (!(await page.$(sel).catch(() => null))) run.problems.push(`missing ${what} (no ${sel})`);
  if (ready && IDLE_MS > 0 && run.name.indexOf("app ") !== 0) await idle(run);
  run.problems = [...new Set(run.problems)];
  return { ...run, ready, ms };
}

/**
 * Per page, what must be there once it's ready - [selector, what it is]. 2026-10-21: a redesign of the side button's
 * panel dropped its circle-to-crop flow and nothing noticed until the user did.
 */
const MUST = {
  assist: [[".assist-draw", "the circle-to-crop layer over the screen (assist.tsx Draw)"]],
};

/** The idle check (see the top): after the page settled, IDLE_MS of nothing - no rAF, no paint, no endless animation. */
async function idle(run) {
  await run.page.evaluate(() => (window.__powosMockQuiet = true)).catch(() => {});
  await new Promise((r) => setTimeout(r, IDLE_WAIT_MS));
  const t0 = Date.now();
  let found = await idleWindow(run);
  // A minute turned over in the window: the clocks' (time.ts, the lock face, aod) one redraw a minute - again once.
  if (found.length && Math.floor((t0 - 1000) / 60_000) !== Math.floor((Date.now() + 500) / 60_000)) found = await idleWindow(run);
  run.problems.push(...found);
}

async function idleWindow(run) {
  const { page } = run;
  const found = [];
  const cdp = await page.target().createCDPSession();
  const painted = [];
  const layers = new Map();
  cdp.on("LayerTree.layerPainted", (e) => painted.push(e));
  cdp.on("LayerTree.layerTreeDidChange", (e) => e.layers?.forEach((l) => layers.set(l.layerId, l)));
  await cdp.send("LayerTree.enable").catch(() => {});
  const raf0 = await page.evaluate(() => window.__gateRaf).catch(() => 0);
  if (await page.evaluate(() => document.hidden).catch(() => false)) found.push("idle check: the page is hidden in the gate's browser (no frames to count)");
  await new Promise((r) => setTimeout(r, IDLE_MS));
  const { raf, anims } = await page
    .evaluate(() => ({
      raf: window.__gateRaf,
      // Running and endless (an iteration count of Infinity): a finite one ends by itself.
      anims: document
        .getAnimations()
        .filter((a) => a.playState === "running" && a.effect?.getComputedTiming().endTime === Infinity)
        .map((a) => {
          const t = a.effect?.target;
          const cls = t && typeof t.className === "string" ? "." + t.className.trim().split(/\s+/).join(".") : "";
          return `${a.animationName ?? a.constructor.name} on ${t ? t.tagName.toLowerCase() + cls : "?"}`;
        }),
    }))
    .catch(() => ({ raf: raf0, anims: [] }));
  const secs = IDLE_MS / 1000;
  if (raf > raf0) found.push(`not idle: ${raf - raf0} requestAnimationFrame callbacks in ${secs} s after settling (an idle page draws nothing)`);
  if (painted.length) {
    // Which: the painted layers' elements (what to look at), and the areas.
    const what = new Map();
    for (const e of painted) {
      const l = layers.get(e.layerId);
      let name = `layer ${e.layerId}`;
      if (l?.backendNodeId) {
        const d = await cdp.send("DOM.describeNode", { backendNodeId: l.backendNodeId }).catch(() => null);
        const n = d?.node;
        if (n) name = n.localName + (n.attributes?.includes("class") ? "." + n.attributes[n.attributes.indexOf("class") + 1].trim().split(/\s+/).join(".") : "");
      } else if (l && !l.parentLayerId) name = "the root layer";
      const c = e.clip;
      what.set(name, [...(what.get(name) ?? []), `${c.width}x${c.height}@${c.x},${c.y}`]);
    }
    const list = [...what].map(([k, v]) => `${k} (${v.length}x: ${[...new Set(v)].slice(0, 2).join(" ")})`).join("; ");
    found.push(`not idle: ${painted.length} layer paints in ${secs} s after settling - ${list}`);
  }
  if (anims.length) found.push(`not idle: endless animations running - ${[...new Set(anims)].slice(0, 4).join(", ")}`);
  await cdp.detach().catch(() => {});
  return found;
}

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || "/usr/bin/chromium-browser",
  headless: true,
  // Every page drawn as if on screen (the pages run side by side): a backgrounded or occluded one gets no frames, and
  // the idle check would see nothing.
  args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--no-first-run", "--mute-audio",
    "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows", "--disable-background-timer-throttling"],
});
let failed = 0;
try {
  const runs = [];
  if (process.env.SHELL_PAGES !== "0") {
    for (const mode of modes()) {
      const url = `${ORIGIN}/index.html${mode === "home" ? "" : `?mode=${mode}`}`;
      // Ready, or failed: the boot guard (index.html) saw an error before ready - no use waiting out READY_MS.
      runs.push(open(browser, url, mode).then((r) => settle(r, () => window.__powosAlive === true || window.__powosBoot?.failed === true)));
    }
  }
  // The pill (bar.tsx, grow.tsx): every empty pill on home is one --pill-height tall - the foot's, PowOS AI's compose,
  // and the search widget at every size (one row, two rows, narrow), also after it was measured narrow and widened
  // again (2026-10-22: a pill measured narrow kept that height - three rows of placeholder - once wide again).
  if (process.env.SHELL_PAGES !== "0") {
    runs.push(
      open(browser, `${ORIGIN}/index.html`, "pill").then(async (r) => {
        await r.page.waitForFunction(() => window.__powosAlive === true || window.__powosBoot?.failed === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
        // Not up in time (a busy Mac): said as the other pages say it, so push.sh's retry knows it for a timeout.
        if (!(await r.page.evaluate(() => window.__powosAlive === true).catch(() => false))) {
          r.problems.push(`not ready (window.__powosAlive) within ${Date.now() - r.started} ms`);
          return { ...r, ready: false, ms: Date.now() - r.started };
        }
        const out = await r.page
          .evaluate(async () => {
            const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
            const frames = () => new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(ok)));
            const { powos } = await importShim("./bridge.ts");
            const cells = [{ x: 0, y: 3, w: 6, h: 1 }, { x: 0, y: 5, w: 6, h: 2 }, { x: 0, y: 1, w: 2, h: 1 }];
            for (const c of cells) await Promise.race([powos.home.addPanel("search", 0, c), sleep(800)]).catch(() => {});
            await sleep(600);
            const token = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--pill-height"));
            const where = (p) => (p.closest(".search-face") ? `the search widget (${p.closest(".home-tile")?.getBoundingClientRect().height | 0} px cell)` : p.closest(".ai-compose") ? "PowOS AI's compose" : p.closest(".home > .bar") ? "home's search" : "a pill");
            const check = (when) => {
              const bad = [];
              for (const p of document.querySelectorAll(".pill")) {
                const g = p.querySelector(".grow");
                if (!g || g.value || !p.getClientRects().length) continue;
                if (Math.abs(p.clientHeight - token) > 1) bad.push(`${where(p)} is ${p.clientHeight} px tall empty${when}, not --pill-height ${token} px`);
              }
              return bad;
            };
            const fails = check("");
            if (!document.querySelector(".search-face .pill")) fails.push("no search widget mounted to check (powos.home.addPanel)");
            // Measured while narrow (a fold, a relayout: the field measures as its text changes), then wide again.
            const S = await importShim("./state.ts");
            for (const p of document.querySelectorAll(".pill")) p.style.width = "1px";
            await frames();
            S.query.value = "x";
            await frames();
            S.query.value = "";
            await frames();
            for (const p of document.querySelectorAll(".pill")) p.style.width = "";
            await frames();
            await sleep(300);
            return [...fails, ...check(" after it was measured narrow and widened again")];
          })
          .catch((e) => [`evaluate: ${e.message.split("\n")[0]}`]);
        r.problems.push(...out);
        return { ...r, ready: true, ms: Date.now() - r.started };
      }),
    );
  }
  // Merged tiles touching over PART of an edge (grid.tsx joins/seams; the user's steam-over-fetch, 2026-10-22): a wide
  // widget over a half-width one is ONE surface - the gutter along the shared span filled by a seam exactly between the
  // two faces, an inner-corner fillet where the group turns - and the wide one's free edge stays level with an unjoined
  // edge (half a gutter in from its row line: extending it whole was the ragged step). Folded and unfolded.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 412, height: 915 }], ["unfolded", { width: 900, height: 1000 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `joins-${label}`, viewport).then((r) => whenReady(r, () => r.page.evaluate(joinsCheck))));
  // Floating windows live on home's pages (ui/desktops.ts; the user's design, 2026-10-22): page switch hides and
  // shows them, and the placement survives the page loading afresh.
  if (process.env.SHELL_PAGES !== "0")
    runs.push(
      open(browser, `${ORIGIN}/index.html`, "desktops", { width: 900, height: 1000 }).then(async (r) => {
        const s = await whenReady(r, () => r.page.evaluate(desktopsCheck));
        if (!s.problems.length) s.problems.push(...(await r.page.evaluate(desktopsEdge).catch((e) => [`evaluate: ${e.message.split("\n")[0]}`])));
        if (!s.problems.length) s.problems.push(...(await r.page.evaluate(dockTapCheck).catch((e) => [`evaluate: ${e.message.split("\n")[0]}`])));
        if (s.problems.length) return s;
        await r.page.reload().catch(() => {});
        return whenReady(r, () => r.page.evaluate(desktopsReloaded));
      }),
    );
  // Edit mode: the search bar a tile on the grid, the dock in view (the user, 2026-10-22). Folded and unfolded.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `edit-search-${label}`, viewport).then((r) => whenReady(r, async () => [...(await r.page.evaluate(editSearchCheck)), ...(await r.page.evaluate(editSearchMoved))])));
  // Edit mode: a rectangle drawn on empty space picks tiles, picked tiles move together (the user, 2026-10-22).
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `home-select-${label}`, viewport).then((r) => whenReady(r, async () => {
        const fails = await r.page.evaluate(marqueeCheck);
        return fails.length ? fails : r.page.evaluate(partyMoveCheck);
      })));
  // Unfolded home is one wide page with one bar (hosts/wide.ts, home.tsx; the user, 2026-10-22), migrated from the two
  // side-by-side pages without moving a tile.
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html`, "wide-home", { width: 821, height: 883 }).then((r) => whenReady(r, async () => [...(await r.page.evaluate(wideMigrated)), ...(await r.page.evaluate(wideAcross)), ...(await r.page.evaluate(wideBar))])));
  // Home after an app at another size (Broforce in landscape, 2026-10-22: back on home the widgets were tiny and squashed
  // at the top). Laid out at [from] while hidden and shown again at [to], turned there and back, and relaid in its own
  // column count after the other's at the same size: the tiles must sit where a fresh layout at [to] puts them, and the
  // grid's cells span its width in home's column count. Folded portrait <-> landscape, and unfolded <-> folded.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, to, from] of [
      ["landscape", { width: 404, height: 900 }, { width: 900, height: 404 }],
      ["fold", { width: 404, height: 900 }, { width: 900, height: 1000 }],
      ["unfold", { width: 900, height: 1000 }, { width: 404, height: 900 }],
    ])
      runs.push(open(browser, `${ORIGIN}/index.html`, `relayout-${label}`, to).then((r) => whenReady(r, () => relayout(r.page, to, from))));
  // The control center's rearranging (ui/reorder.ts, control.tsx Controls): in edit mode a toggle held and carried onto
  // the first slot of the row lands there, is saved (the store holds it), and is still there after the panel shut and
  // opened again and after a reload; a carry cancelled (the system took the pointer) changes nothing. Every step waits
  // on the state it needs, never on time - CC_THROTTLE (e.g. 6) slows the page's CPU to check that it holds.
  if (process.env.SHELL_PAGES !== "0") {
    const ccOrder = () => [...document.querySelectorAll(".cc3-list [data-key]")].filter((e) => e.getClientRects().length).map((e) => e.dataset.key);
    runs.push(
      open(browser, `${ORIGIN}/index.html?mode=shade`, "cc-reorder").then(async (r) => {
        const rate = Number(process.env.CC_THROTTLE || 1);
        if (rate > 1) await (await r.page.target().createCDPSession()).send("Emulation.setCPUThrottlingRate", { rate }).catch(() => {});
        await r.page.waitForFunction(() => window.__powosAlive === true || window.__powosBoot?.failed === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
        const out = await r.page
          .evaluate(async (orderSrc) => {
            const order = new Function(`return (${orderSrc})`)();
            const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
            // Until [f] holds (or [ms] pass: then the step fails with [what]).
            const until = async (f, what, ms = 15000) => {
              const t0 = performance.now();
              while (!f()) {
                if (performance.now() - t0 > ms) throw new Error(`timed out: ${what}`);
                await sleep(20);
              }
            };
            const frames = (n = 2) => new Promise((ok) => { const step = (k) => (k ? requestAnimationFrame(() => step(k - 1)) : ok()); step(n); });
            const S = await importShim("./state.ts");
            const X = await importShim("./ui/ccexpand.ts");
            const { powos } = await importShim("./bridge.ts");
            const P = (el, type, x, y) => el.dispatchEvent(new PointerEvent(type, { bubbles: true, clientX: x, clientY: y, pointerId: 9, isPrimary: true, pointerType: "touch" }));
            const mid = (el) => { const b = el.getBoundingClientRect(); return [b.left + b.width / 2, b.top + b.height / 2]; };
            const item = (k) => document.querySelector(`.cc3-list [data-key="${k}"]`);
            const fails = [];
            try {
              S.ccV3.value = "v3";
              S.notif.value = true;
              await until(() => order().length >= 3, "the row of toggles");
              X.ccEditing.value = true;
              await frames();
              const before = order();
              const k0 = before[2];
              const lift = async () => {
                const [x, y] = mid(item(k0));
                P(item(k0), "pointerdown", x, y);
                await until(() => document.querySelector(".cc3-list .carried"), "the lift (a long press)");
                return [x, y];
              };
              // Carried part of the way, then cancelled: nothing changes.
              let [x, y] = await lift();
              let [tx, ty] = mid(item(before[0]));
              P(item(k0), "pointermove", (x + tx) / 2, (y + ty) / 2);
              await until(() => order().indexOf(k0) < 2, "the row making room", 5000).catch(() => {});
              P(item(k0), "pointercancel", tx, ty);
              await until(() => !document.querySelector(".cc3-list .carried"), "the copy gone after a cancel");
              await until(() => order().join() === before.join(), "the order back after a cancel", 5000).catch(() => fails.push(`a cancelled carry changed the order: ${before.join(",")} -> ${order().join(",")}`));
              if (document.querySelector(".cc .lifted")) fails.push("a cancelled carry left its faint item behind");
              // Carried onto the first slot, a step at a time (each move after the row made room), and let go.
              [x, y] = await lift();
              [tx, ty] = mid(item(before[0]));
              P(item(k0), "pointermove", (x + tx) / 2, (y + ty) / 2);
              await until(() => order().indexOf(k0) <= 1, "the row making room (slot 1)").catch((e) => fails.push(e.message));
              await frames();
              [tx, ty] = mid(item(before[0]));
              P(item(k0), "pointermove", tx, ty);
              await until(() => order()[0] === k0, "the row making room (slot 0)", 5000).catch(() => {});
              P(item(k0), "pointerup", tx, ty);
              await until(() => !document.querySelector(".cc3-list .carried"), "the copy gone after landing");
              if (order()[0] !== k0) fails.push(`carried ${k0} onto the first slot, it landed at ${order().indexOf(k0)} (${order().join(",")})`);
              // Saved: the store has it first among the row's.
              const savedFirst = async () => {
                const l = await powos.store.get("controls.layout");
                return (l?.order ?? []).filter((id) => before.includes(id))[0];
              };
              const t0 = performance.now();
              while ((await savedFirst()) !== k0 && performance.now() - t0 < 10000) await sleep(50);
              if ((await savedFirst()) !== k0) fails.push(`saved order has ${await savedFirst()} first, not ${k0}`);
              // The further pull reveals the rest under the row: the row's toggles don't move at all.
              const revealAndFold = async () => {
                X.ccEditing.value = false;
                const still = () => !document.getAnimations().some((an) => an.playState === "running" && an.effect?.target?.closest?.(".cc"));
                await until(still, "the row settled after the drop");
                const rowRects = () => order().slice(0, 6).map((k) => { const b = item(k).getBoundingClientRect(); return `${k}@${Math.round(b.left)},${Math.round(b.top)}`; }).join(" ");
                const first = rowRects();
                // Each step waits on the state it needs: the list rendered in its new state (its .whole class, set by
                // the render), then two frames (layout, then the ResizeObserver/FLIP pass after it), then no animation.
                const rendered = async (whole, what) => {
                  await until(() => !!document.querySelector(".cc3-list.whole") === whole, what);
                  await frames(2);
                  await until(still, `${what}: settled`);
                };
                X.setExpanded(true);
                await rendered(true, "the rest revealed");
                if (order().length <= 6) fails.push(`the further pull shows only ${order().length} toggles`);
                if (rowRects() !== first) fails.push(`the first row moved on the further pull: ${first} -> ${rowRects()}`);
                X.setExpanded(false);
                await rendered(false, "folded again");
                if (order().length > 6) fails.push(`folded, ${order().length} toggles still show`);
              };
              await revealAndFold();
              // Shut and opened again: still there.
              S.notif.value = false;
              await until(() => !document.querySelector(".notif-panel.shown"), "the panel shut", 5000).catch(() => {});
              S.notif.value = true;
              await until(() => order().length >= 3, "the row again");
              await frames();
              if (order()[0] !== k0) fails.push(`after the panel shut and opened again, ${k0} is at ${order().indexOf(k0)} (${order().join(",")})`);
              return { fails, k0 };
            } catch (e) {
              return { fails: [...fails, e.message] };
            }
          }, ccOrder.toString())
          .catch((e) => ({ fails: [`evaluate: ${e.message.split("\n")[0]}`] }));
        r.problems.push(...(out.fails ?? []));
        // The page loaded afresh (as another of the shade, home, Quick Tools reads it): the same order.
        if (out.k0) {
          await r.page.reload().catch(() => {});
          await r.page.waitForFunction(() => window.__powosAlive === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
          const first = await r.page
            .evaluate(async (orderSrc) => {
              const order = new Function(`return (${orderSrc})`)();
              const S = await importShim("./state.ts");
              S.notif.value = true;
              const t0 = performance.now();
              while (order().length < 3 && performance.now() - t0 < 15000) await new Promise((ok) => setTimeout(ok, 50));
              await new Promise((ok) => setTimeout(ok, 300));
              return order()[0];
            }, ccOrder.toString())
            .catch(() => null);
          if (first !== out.k0) r.problems.push(`the page loaded afresh shows ${first} first, not the rearranged ${out.k0}`);
        }
        return { ...r, ready: true, ms: Date.now() - r.started };
      }),
    );
  }
  // The shade's further pull (ccexpand.ts; the user, 2026-10-22: only "no notifications" moved, the rest stood still):
  // driven through gesture.ts as a finger (a mouse's pointer events on the panel), the whole panel follows it - what's
  // under the control center moves down by the finger's travel and the rest's toggles show under the row, the row
  // itself still - let go short it goes back, past it the rest stays shown, a pull up folds it; nothing runs at rest.
  if (process.env.SHELL_PAGES !== "0")
    runs.push(
      open(browser, `${ORIGIN}/index.html?mode=shade`, "shade-overpull").then(async (r) => {
        await r.page.waitForFunction(() => window.__powosAlive === true || window.__powosBoot?.failed === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
        const fails = [];
        for (const step of [overpullKit, overpullShort, overpullExpand, overpullFold, overpullRest]) {
          const out = await r.page.evaluate(step).catch((e) => [`evaluate: ${e.message.split("\n")[0]}`]);
          fails.push(...(out ?? []));
          if (fails.length) break;
        }
        r.problems.push(...fails);
        return { ...r, ready: true, ms: Date.now() - r.started };
      }),
    );
  // The pet (ui/pet.tsx): home with local.pet installed, driven through what the user does - shown, touched, each
  // state, a talk bubble, a deploy note, a move - so an error in its effects and timers (2026-10-21: a TDZ in the hop
  // timer's effect threw on every show) fails here; the plain home run never mounts it (the mock has no local.pet).
  if (process.env.SHELL_PAGES !== "0" && process.env.GATE_PET !== "0" && fs.existsSync(path.join(ROOT, "ui/pet.tsx"))) {
    runs.push(
      open(browser, `${ORIGIN}/index.html`, "pet").then(async (r) => {
        await r.page.waitForFunction(() => window.__powosAlive === true || window.__powosBoot?.failed === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
        const out = await r.page
          .evaluate(async () => {
            const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
            const fails = [];
            const P = await importShim("./apps/pages.ts");
            P.installedApps.value = [...P.installedApps.value, { id: "local.pet", name: "Pet", version: "0.1.0", database: "local-pet", tier: 0, manifest: "{}" }];
            await sleep(600);
            // Off by default (the module's enabled; no SpacetimeDB here): installed but off must render nothing.
            if (document.querySelector(".pet")) return ["the pet rendered while it's off (enabled false)"];
            window.__pet?.on?.(true);
            await sleep(600);
            const pet = document.querySelector(".pet");
            if (!pet) return ["the pet didn't mount with local.pet installed"];
            const at = pet.getBoundingClientRect();
            const touch = (el, x, y) => {
              for (const t of ["pointerdown", "pointerup"]) el.dispatchEvent(new PointerEvent(t, { bubbles: true, clientX: x, clientY: y, pointerId: 7, isPrimary: true }));
            };
            // A touch elsewhere on home (the timers that wait for one), then each state, the hooks a review uses.
            touch(document.body, 20, 400);
            await sleep(200);
            for (const st of ["idle", "looking", "working", "worried", "sleepy", "hungry", "eating", "happy", "listening"]) {
              window.__pet?.force(st);
              await sleep(120);
            }
            window.__pet?.force(null);
            window.__mockEvents?.emit("ai.mail", [{ id: "gate-pet", from: "deploy", text: "Clock got a gate check", time: Date.now() / 1000 }]);
            await sleep(300);
            window.__pet?.carry?.();
            await sleep(300);
            // A tap on the pet itself (talk: the mock recognizer), and a touch away (the bubble goes).
            touch(pet, at.left + at.width / 2, at.top + at.height / 2);
            await sleep(400);
            touch(document.body, 20, 300);
            await sleep(400);
            if (!document.querySelector(".pet")) fails.push("the pet went away after being used");
            return fails;
          })
          .catch((e) => [`evaluate: ${e.message.split("\n")[0]}`]);
        r.problems.push(...out);
        const guard = await r.page.evaluate(() => window.__powosBoot?.errors ?? []).catch(() => []);
        for (const e of guard) r.problems.push(`${e.kind}: ${e.message}${e.file ? ` (${e.file}${e.line ? ":" + e.line : ""})` : ""}`);
        if (!guard.length) r.problems.push(...r.uncaught);
        r.problems = [...new Set(r.problems)];
        return { ...r, ready: true, ms: Date.now() - r.started };
      }),
    );
  }
  for (const app of apps()) {
    runs.push(
      open(browser, `${ORIGIN}/__gate_app.html`, `app ${app.id}`).then(async (r) => {
        // Each entry as island.tsx / appscreen.tsx import it: through es-module-shims (the import map).
        await r.page
          .evaluate(async (id, entries) => {
            await new Promise((ok) => (window.importShim ? ok() : addEventListener("load", ok)));
            const out = [];
            for (const e of entries) {
              try {
                await window.importShim(`./_app/${id}/${e}`);
              } catch (err) {
                out.push(`${e}: ${err?.message ?? err}`);
              }
            }
            window.__gateApp = out;
          }, app.id, app.entries)
          .catch((e) => r.problems.push(`evaluate: ${e.message}`));
        const s = await settle(r, () => Array.isArray(window.__gateApp));
        const out = await r.page.evaluate(() => window.__gateApp ?? []).catch(() => []);
        s.problems.push(...out.map((o) => `module: ${o}`));
        if (!app.entries.length) s.warnings.push("no page or widget entries in its manifest");
        return s;
      }),
    );
  }
  for (const r of await Promise.all(runs)) {
    if (r.problems.length) {
      failed++;
      for (const p of r.problems) console.log(`FAIL ${r.name}: ${p}`);
    } else console.log(`ok   ${r.name} (${r.ms} ms)`);
    for (const w of r.warnings.slice(0, 3)) console.log(`     ${r.name} console: ${w.slice(0, 200)}`);
  }
} finally {
  await browser.close();
}
process.exit(failed ? 1 : 0);

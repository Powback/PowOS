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
/** Every puppeteer-side wait (launch, newPage's target wait, goto, waitFor*): its fixed 30 s defaults scaled with the
 * load like READY_MS (f30) - a starved Mac (load ~15 from training runs) timed out before any case ran. */
const PUPPETEER_MS = Math.max(30000, READY_MS * 2);
/** Names the startup call that failed: a bare "Timed out after waiting 30000ms" (rxjs, util.js) says nothing (f30). */
const step = (name, promise) => promise.catch((e) => { e.message = `[${name}] ${e.message}`; throw e; });
/** After ready: errors this soon after the first render are boot errors too (an effect throwing, a lazy import). */
const SETTLE_MS = Number(process.env.SETTLE_MS || 400);
const IDLE_MS = Number(process.env.IDLE_MS ?? 2000);
const IDLE_WAIT_MS = Number(process.env.IDLE_WAIT_MS || 3000);
/** GATE_ONLY: a regex on the run names ("search-launcher|relayout"); the rest are skipped (a case worked on alone). */
const ONLY = process.env.GATE_ONLY ? new RegExp(process.env.GATE_ONLY) : null;
/**
 * GATE_THROTTLE: every page's CPU slowed that many times (CDP Emulation.setCPUThrottlingRate) - a loaded Mac's gate
 * (two gates at --cpu-shares 256, frames late against the clock) on demand: a case must pass at 6.
 */
const THROTTLE = Number(process.env.GATE_THROTTLE || 1);
const SKIP = Symbol("skipped");

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

/**
 * Side docks keep usable icons, reserve home space, and calculate drops on the vertical axis. [part]: "home" (home's
 * page: no launcher of its own since the launcher is one overlay, pull.tsx), "launcher" (the overlay's page,
 * index.html?mode=pull: the launcher keeps its width and its pill at the bottom beside a side dock), "all" (desktop).
 */
async function dockPositionCheck(position, part = "all") {
  const S = await importShim("./state.ts");
  const D = await importShim("./ui/dockdrop.ts");
  S.setDock(S.apps.value.slice(0, 4).map(a => a.key));
  const fails = [];
  function setPosition() {
    const mode = S.dockMode.value;
    // Folded and unfolded home: the bottom bar unless chosen (a side dock never appears by default).
    const expected = mode === "desktop" ? "left" : "bottom";
    if (S.dockPosition.value !== expected) fails.push(`wrong default dock position in ${mode}: ${S.dockPosition.value}`);
    const all = { mobile: S.mobileDockPlacement, unfolded: S.unfoldedDockPlacement, desktop: S.desktopDockPlacement };
    const others = Object.entries(all).filter(([m]) => m !== mode).map(([, p]) => p);
    const before = others.map(p => p.value);
    S.dockPlacement.value = position;
    if (others.some((p, i) => p.value !== before[i])) fails.push("changing dock position changed another mode");
    if (localStorage.getItem(`powos.dock.position.${mode}`) !== position) fails.push("position not saved");
  }
  // In the page: page.evaluate serialises this function only, so the launcher check lives inside it.
  async function dockLauncherCheck(position) {    const S = await importShim("./state.ts");    S.drawer.value = 1;    await new Promise(r => setTimeout(r, 450));    const clip = document.querySelector(".launcher-clip").getBoundingClientRect();    const bar = document.querySelector(".home > .bar").getBoundingClientRect();    const fails = [];    if (clip.left > 20 || clip.right < innerWidth - 20) fails.push("launcher loses width beside dock");    if (bar.bottom > innerHeight + 1 || bar.top < 0) fails.push(`launcher search is off screen: top=${bar.top}, bottom=${bar.bottom}, viewport=${innerHeight}`);    if (bar.bottom < innerHeight - 60) fails.push(`${position} dock leaves launcher search above the bottom edge`);    return fails;  }
  async function launcherDockCheck(dock, position) {    const side = position !== "bottom";    const fails = side ? await dockLauncherCheck(position) : await openedFor(450);    const r = dock.getBoundingClientRect();    fails.push(...(side ? sideColumnFails(r, position) : r.width < r.height ? ["launcher's bottom dock is vertical"] : []));    const o = getComputedStyle(dock).opacity;    if (o !== "1") fails.push(`launcher's dock not shown open: opacity ${o}`);    return fails;  }  async function openedFor(ms) { (await importShim("./state.ts")).drawer.value = 1; await new Promise(r => setTimeout(r, ms)); return []; }  function sideColumnFails(r, position) {    const fails = [];    const pill = document.querySelector(".home > .bar").getBoundingClientRect();    if (r.width > 80 || r.height < 200 || r.top < 0 || r.bottom > pill.top + 1) fails.push("launcher's side dock is not a column above the pill");    const cells = [...document.querySelectorAll(".drawer-clip .app")].map(n => Object.assign(n.getBoundingClientRect().toJSON(), { what: `${n.parentElement?.className}/${n.textContent}` })).filter(c => c.width > 0 && c.left >= 0 && c.right <= innerWidth);    const under = cells.find(c => position === "left" ? c.left < r.right - 1 : c.right > r.left + 1);    if (under) fails.push(`launcher's list runs under its side dock (${under.what} at ${Math.round(under.left)}..${Math.round(under.right)}, dock ${Math.round(r.left)}..${Math.round(r.right)})`);    return fails;  }
  setPosition();
  await new Promise(r => setTimeout(r, 250)); const dock = document.querySelector(".home > .dock");
  if (!dock) return [...fails, `${part}: no dock`]; if (part === "launcher") return [...fails, ...(await launcherDockCheck(dock, position))];
  const rect = dock.getBoundingClientRect();
  const cells = [...dock.querySelectorAll(".dock-page:first-child > .app")].map(n => n.getBoundingClientRect());
  if (cells.length < 4) fails.push("missing pinned icons");
  function checkVertical() {
    if (![rect.width <= 80, rect.height >= 200, rect.top >= 0, rect.bottom <= document.querySelector(".home > .bar").getBoundingClientRect().top + 1].every(Boolean)) fails.push("dock is not vertical inside viewport");
    const invalid = (r, i) => r.width < 40 || r.height < 40 || (i > 0 && r.top < cells[i-1].bottom - 1);
    if (cells.some(invalid)) fails.push("icons overlap or are too small");
    const stage = document.querySelector(".home > .stage > .home-content").getBoundingClientRect();
    const overlaps = position === "left" ? stage.left < rect.right - 1 : stage.right > rect.left + 1;
    if (overlaps) fails.push("side dock overlaps home");
    const target = cells[2];
    const aim = D.aimDock({app:S.apps.value[5].key}, target.left + target.width/2, target.top + target.height/2);
    if (aim?.slot !== 2) fails.push(`vertical drop targets slot ${aim?.slot}, expected 2`);
  }
  if (part !== "launcher") await homeDock();
  if (part === "home") return fails;
  async function homeDock() {
    if (position !== "bottom") checkVertical();
    else if (rect.width < rect.height) fails.push("bottom dock is vertical");
    const windows = await importShim("./ui/desktops.ts");
    if (windows.barTop() < innerHeight / 2) fails.push("dock collapses window work area");
  }
  async function dockSettled() {
    if (position === "bottom") return new Promise(r => setTimeout(r, 450));
    for (let t = 0; t < 120 && getComputedStyle(dock).opacity !== "0"; t++) await new Promise(r => setTimeout(r, 50));
  }
  S.drawer.value = 1;
  // The dock fades out on its own transition: wait for it to settle (opacity 0, up to 6 s), not a fixed delay a
  // throttled or loaded run overshoots (2026-10-28: desktop-left / inner-left failed only under load).
  await dockSettled();
  checkLauncher(); if (position !== "bottom" && getComputedStyle(dock).opacity !== "0") fails.push("side dock covers launcher");
  function checkLauncher() {
    const desktop = document.documentElement.dataset.mode === "desktop";
    const clip = document.querySelector(desktop ? ".launcher" : ".launcher-clip").getBoundingClientRect();
    const bar = document.querySelector(".home > .bar").getBoundingClientRect();
    if (!desktop && (clip.left > 20 || clip.right < innerWidth - 20)) fails.push("launcher loses width beside dock");
    if (bar.bottom > innerHeight + 1 || bar.top < 0) fails.push(`launcher search is off screen: top=${bar.top}, bottom=${bar.bottom}, viewport=${innerHeight}`);
    if (position !== "bottom" && bar.bottom < innerHeight - 60) fails.push("side dock leaves launcher search above the bottom edge");
  }
  return fails;
}

/** Chrome controls stay within a narrow window and dispatch only their scoped actions. */
async function windowChromeCheck() {
  const B = (await importShim("./bridge.ts")).powos;
  const actions = [];
  B.chrome.action = async (name) => { actions.push(name); };
  const fail = [];
  for (const button of document.querySelectorAll("[data-action]")) {
    const r = button.getBoundingClientRect();
    if (r.x < 0 || r.right > innerWidth || r.width < 30) fail.push(`clipped control ${button.dataset.action}`);
    button.click();
  }
  if (actions.join() !== "minimise,maximise,close") fail.push(`window actions: ${actions}`);
  window.__mockEvents.emit("chrome.changed", {kind:"window", title:"Document", maximised:true});
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  if (!document.querySelector('[aria-label="Restore"]')) fail.push("maximised window has no Restore control");
  return fail;
}

async function statusChromeCheck() {
  const B = (await importShim("./bridge.ts")).powos;
  const actions = [];
  B.chrome.action = async (name) => { actions.push(name); };
  const fail = [];
  window.__mockEvents.emit("chrome.changed", {kind:"status", battery:74, charging:true, network:"wifi", left:44});
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  for (const button of document.querySelectorAll(".status-chrome button")) button.click();
  if (actions.join() !== "notifications,controls") fail.push(`status actions: ${actions}`);
  if (!document.querySelector("time") || !document.body.textContent.includes("74%")) fail.push("missing clock/battery");
  if (document.querySelector(".status-clock").getBoundingClientRect().x < 44) fail.push("clock covers cutout");
  for (const button of document.querySelectorAll(".status-chrome button")) {
    const css = getComputedStyle(button);
    if (css.backgroundImage !== "none" || css.boxShadow !== "none") fail.push("status bar has decorative effects");
  }
  return fail;
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
  } else f = p === "dev/search-check.js" ? new URL("./search-check.js", import.meta.url) : path.join(ROOT, p);
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
  r.problems.push(...(await checkOnce(r, check).catch((e) => [`evaluate: ${e.message.split("\n")[0]}`])));
  return { ...r, ready: true, ms: Date.now() - r.started };
}

/**
 * [check], again once if the page's context went from under it - not an assertion of the check's, the evaluate lost:
 * "Promise was collected" (2026-10-23, relayout-unfold on a loaded gate: the awaited promise gone with no result) or a
 * context destroyed by a navigation. Retried on the page loaded afresh (the first try may have left its state behind:
 * a search widget placed, edit mode on - the retry then failed on that, not on the code); a second loss is the failure.
 */
const GONE = /Promise was collected|Execution context was destroyed|Cannot find context with specified id/;
async function checkOnce(r, check) {
  try {
    return await check();
  } catch (e) {
    if (!GONE.test(e?.message ?? "")) throw e;
    await r.page.reload().catch(() => {});
    await r.page.waitForFunction(() => window.__powosAlive === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
    return check();
  }
}

/** In the page: steam (6x3) over fetch (3x3, flush right) on home's first page - a straight stack: ONE clean rectangle
 * (the user's 2026-10-28 "looks ugly af if the widgets arent the same width"), fetch shown 6 wide, outer edges on the
 * row and column lines, the shared side a seam, no inner corner. */
async function joinsCheck() {
  const S = await window.__gw.mod("./state.ts");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const h = await powos.home.get();
  for (const i of h.items) await powos.home.remove(i.key);
  const w = Math.min(6, h.columns || 6);
  // Home's first page (pages are 1-based; the wide layout maps it to the left half).
  const pg = h.pages[0] ?? 1;
  await powos.home.addPanel("agents", pg, { x: 0, y: 0, w, h: 3 });
  await powos.home.addPanel("recents", pg, { x: w - 3, y: 3, w: 3, h: 3 });
  S.page.value = 0;
  // Both laid out and joined, at rest (the tiles' own moves and the seams after them).
  const placed = () => [...document.querySelectorAll(".page:not(.away) .home-tile")];
  await window.__gw.until(() => placed().length === 2 && placed().every((t) => t.classList.contains("joined")) && window.__gw.still());
  await window.__gw.steady(() => placed().map((t) => t.querySelector(":scope > .tile")?.getBoundingClientRect().toJSON()));
  const half = (parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--gap")) || 8) / 2;
  const tiles = [...document.querySelectorAll(".page:not(.away) .home-tile")];
  if (tiles.length !== 2) return [`${tiles.length} tiles on the page, not the 2 placed`];
  const [A, B] = tiles.map((t) => ({ t, cell: t.getBoundingClientRect(), face: t.querySelector(":scope > .tile").getBoundingClientRect() })).sort((p, q) => p.cell.top - q.cell.top);
  const near = (a, b) => Math.abs(a - b) <= 1;
  // Outer edges: half a gutter in from the cell box, as a single tile's. The shared side: the faces meet (a seam).
  const inset = (x) => ["top", "right", "bottom", "left"].filter((k) => !near(Math.abs(x.face[k] - x.cell[k]), half));
  return [
    !A.t.classList.contains("joined") || !B.t.classList.contains("joined") ? "the two aren't merged (no .joined)" : "",
    near(A.face.left, B.face.left) && near(A.face.right, B.face.right) ? "" : `not one width: left edges differ by ${Math.round(A.face.left - B.face.left)} px, right by ${Math.round(A.face.right - B.face.right)} px`,
    ...inset(A).filter((k) => k !== "bottom").map((k) => `the wide tile's ${k} edge is off its grid line`),
    ...inset(B).filter((k) => k !== "top").map((k) => `the stacked tile's ${k} edge is off its grid line`),
    near(A.face.bottom, A.cell.bottom) && near(B.face.top, B.cell.top) && near(A.cell.bottom, B.cell.top) ? "" : `the shared side isn't a seam on the row line (${Math.round(B.face.top - A.face.bottom)} px between the faces)`,
    document.querySelector(".page:not(.away) .seam.fillet") ? "a rounded inner corner in a straight stack (it should be one rectangle)" : "",
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
/**
 * The relayout case's waits, on the page's state (not a time): [v] the window's size there (innerWidth/innerHeight;
 * then frames: its resize event is dispatched by then), home's tiles at rest (no animation, the same rects over
 * frames). [like]: until the tiles are those rects, at most 3 s, then at rest - the comparison after it is the check.
 */
const restAt = (page, v, like = null) =>
  page.evaluate(
    async (w, h, like) => {
      const G = window.__gw;
      const rects = () =>
        [...document.querySelectorAll(".page:not(.away) .home-tile")]
          .map((t) => {
            const b = t.getBoundingClientRect();
            return `${(t.textContent || "").slice(0, 10)}@${Math.round(b.left)},${Math.round(b.top)},${Math.round(b.width)}x${Math.round(b.height)}`;
          })
          .sort()
          .join();
      if (w) await G.until(() => innerWidth === w && innerHeight === h);
      await G.frames(2);
      if (like !== null) await G.until(() => rects() === like);
      await G.until(() => G.still());
      await G.steady(rects, 4);
    },
    v?.width ?? 0,
    v?.height ?? 0,
    like,
  );
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
    const S = await window.__gw.mod("./state.ts");
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
  // The notifications list: always there, even empty (the emulator has no notifications, so their count bar is absent).
  // tools/phone/verify/shade-overpull.sh reads the same node - keep them the same.
  const UNDER = ".panel-body.together > .notif-own .notif-items";
  const under = () => document.querySelector(UNDER)?.getBoundingClientRect().top ?? NaN;
  const row = () => cells().slice(0, 6).map((e) => Math.round(e.getBoundingClientRect().top)).join();
  // The panel's own edge on screen (its frost's bottom), and the last thing in it (the gap under that).
  const edge = () => document.querySelector(".notif-panel")?.getBoundingClientRect().bottom ?? NaN;
  const last = () => {
    const els = [...document.querySelectorAll(".panel-body.together .notif-items > *")];
    return els.length ? Math.max(...els.map((e) => e.getBoundingClientRect().bottom)) : NaN;
  };
  const gap = () => edge() - last();
  // Time-driven ones only: the list's edge fades (shell.css scroll-fade) are scroll-driven, "running" for good -
  // window.__gw.documentAnimations already excludes those (friction f125).
  const still = () => !window.__gw.documentAnimations(".notif-panel").length;
  const at = { x: 0, y: 0, el: null };
  const P = (type, y) =>
    at.el.dispatchEvent(
      new PointerEvent(type, { bubbles: true, clientX: at.x, clientY: y, pointerId: 1, isPrimary: true, pointerType: "mouse", buttons: type === "pointerup" ? 0 : 1 }),
    );
  // A finger down on the control center's header ([from]; [mid]: half way first), moved [dy] in six frames, [check]ed, let go.
  const drag = async (dy, check, mid, from = ".cc > .notif-bar") => {
    const el = document.querySelector(from), b = el.getBoundingClientRect();
    Object.assign(at, { el, x: b.left + b.width / 2, y: b.top + Math.min(b.height / 2, 24) });
    P("pointerdown", at.y);
    if (mid) await window.__op.toHalf((y) => P("pointermove", at.y + y), dy, mid);
    for (let i = 1; i <= 6; i++) {
      P("pointermove", at.y + (dy * i) / 6);
      await frames(1);
    }
    await frames(2).then(() => check?.());
    await sleep(120);
    P("pointermove", at.y + dy + Math.sign(dy));
    P("pointerup", at.y + dy + Math.sign(dy));
    await until(() => !document.querySelector(".cc3-grid.cc-peek"), "the pull let go");
    await frames(2);
    await until(still, "settled after the pull");
    await window.__gw.steady(() => [row(), under(), edge(), gap()], 4);
  };
  const S = await window.__gw.mod("./state.ts");
  S.ccV3.value = "v3";
  // The phone opens folded (ccexpand.ts expandedByDefault): these scenes measure the whole view, so expand it first.
  (await window.__gw.mod("./ui/ccexpand.ts")).ccExpanded.value = true;
  S.notif.value = true;
  try {
    await until(() => shown() >= 6 && document.querySelector(UNDER), "the row and the notifications' header");
    await until(still, "the panel open and settled");
    // Its open eases --q and ends the ride on a timer: still() can hold before that begins (a late frame) - so also
    // nothing riding and every measure steady over frames, else the rest marks are taken mid-open.
    await until(() => !document.querySelector(".notif-panel.riding"), "the open's ride over");
    if (!(await window.__gw.steady(() => [row(), under(), edge(), gap()], 4))) throw new Error("timed out: the panel at rest");
  } catch (e) {
    return [e.message];
  }
  window.__op = { sleep, frames, shown, under, row, still, drag, edge, gap, n0: shown(), under0: under(), row0: row(), edge0: edge(), gap0: gap() };
  return [];
}

/** The shade-overpull case's card tools (window.__op): the control center's card and the notifications' own panel under it. */
async function overpullCard() {
  const o = window.__op;
  const q = (sel) => document.querySelector(`.panel-body.together > ${sel}`)?.getBoundingClientRect();
  // (ccexpand.ts moves the two as one: the seam between them, and the panel's bottom - it runs down to the screen's bottom.)
  o.cardTop = () => q(".cc")?.top ?? NaN;
  o.seam = () => (q(".notif-own")?.top ?? NaN) - (q(".cc")?.bottom ?? NaN);
  o.ownBottom = () => q(".notif-own")?.bottom ?? NaN;
  o.rowTop = () => document.querySelector(".cc3-list .cc3-cell")?.getBoundingClientRect().top ?? NaN;
  Object.assign(o, { seam0: o.seam(), rowTop0: o.rowTop(), cardTop0: o.cardTop() });
  return [];
}

/** The shade-overpull case's half-way tools (window.__op): the finger to k about 0.5 ([toHalf]), what's checked there. */
async function overpullHalf() {
  const o = window.__op;
  const ccK = () => Number(document.querySelector(".cc3-grid")?.style.getPropertyValue("--cc-k") || NaN);
  // A step a frame [move]d toward [dy]'s side until the pull's k (the grid's --cc-k) is about half way, [mid] there.
  o.toHalf = async (move, dy, mid) => {
    for (let y = 0; Math.abs(y) < 600; ) {
      y += Math.sign(dy) * 3;
      move(y);
      await o.frames(1);
      if (dy > 0 ? ccK() >= 0.45 : ccK() <= 0.55) {
        await o.frames(2);
        return mid(ccK());
      }
    }
    return mid(ccK()); // (never half way: checked where it got to - a fail, not a silent skip)
  };

  /**
   * Half way (k about 0.5), down or back up: every stack the pull drives is partly unfolded - its rest's visible part
   * (the rest's bottom on screen under the top card's) neither none nor all of it - and the top card's "+N" partly faded:
   * both follow the finger, not switched at the settle.
   */
  o.midPull = (fails, way) => {
    return (k) => {
      const stacks = [...document.querySelectorAll(".panel-body.together .notif-stack.pulled")];
      if (!stacks.length) return fails.push(`${way} half way (k ${k.toFixed(2)}), no notification stack follows the pull`);
      for (const st of stacks) {
        const rest = st.querySelector(":scope > .notif-rest"), card = st.querySelector(":scope > .notif");
        const full = rest.firstElementChild.scrollHeight;
        const f = (rest.getBoundingClientRect().bottom - card.getBoundingClientRect().bottom) / full;
        if (!(f > 0.1 && f < 0.9)) fails.push(`${way} half way (k ${k.toFixed(2)}), a stack is ${Math.round(f * 100)}% unfolded (not between)`);
        o.restWhole(fails, `${way} half way (k ${k.toFixed(2)})`, rest, card); o.inFlow(fails, `${way} half way (k ${k.toFixed(2)})`, st);
        const badge = card.querySelector(".notif-more");
        const op = badge ? Number(getComputedStyle(badge).opacity) : NaN;
        if (!(op > 0.05 && op < 0.95)) fails.push(`${way} half way (k ${k.toFixed(2)}), the top card's +N badge's opacity is ${op} (not between 0 and 1)`);
        o.headLook(fails, way, k, card);
        o.half[way] = [...(o.half[way] ?? []), o.topPart(st)];
      }
    };
  };
  o.half = {};
  // Every card keeps its full width and its own opaque material at every frame: the rest never fades, never insets.
  o.restWhole = (fails, at, rest, card) => {
    const ro = Number(getComputedStyle(rest).opacity), rw = rest.getBoundingClientRect().width, cw = card.getBoundingClientRect().width;
    if (ro !== 1) fails.push(`${at}, a stack's rest is faded (opacity ${ro}, want 1)`);
    if (Math.abs(rw - cw) > 1) fails.push(`${at}, a stack's rest is ${Math.round(rw)} px wide, its top card ${Math.round(cw)} px`);
  };
  // The group header look morphs too: the icon's partly faded half way; and the part above the rest (head band + card)
  // is the height it has settled - no layout change mid-pull, none at the settle ([settled] compares after it).
  o.headLook = (fails, way, k, card) => {
    const icon = card.querySelector(".notif-icon");
    const io = icon ? Number(getComputedStyle(icon).opacity) : NaN;
    if (icon && !(io > 0.05 && io < 0.95)) fails.push(`${way} half way (k ${k.toFixed(2)}), the top card's icon opacity is ${io} (not between 0 and 1)`);
  };
  // What sits above a stack's rest (the head and the top card), in px.
  o.topPart = (st) => st.querySelector(":scope > .notif-rest").offsetTop; // (not the rect: a folding rest is translated)
  // After the settle: each stack's [topPart] within 2 px of what it was half way (the layout didn't jump on the commit).
  o.settled = (fails, way) => {
    const now = [...document.querySelectorAll(".panel-body.together .notif-stack")].map(o.topPart);
    (o.half[way] ?? []).forEach((h, i) => {
      if (now[i] !== undefined && Math.abs(now[i] - h) >= 2) fails.push(`${way}: a stack's top part was ${h.toFixed(1)} px half way and ${now[i].toFixed(1)} px settled (a jump)`);
    });
  };
  return [];
}

/**
 * The shade's layout by width (notifications.tsx wideShade): unfolded two columns side by side - the notifications
 * left, the control center right, each its own scroll, in the one frost panel; folded the one stacked list.
 */
async function shadeLayout() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  (await window.__gw.mod("./state.ts")).notif.value = true;
  for (let t = 0; t < 150 && !document.querySelector(".notif-panel.shown .cc"); t++) await sleep(20);
  await sleep(400);
  const body = document.querySelector(".notif-panel .panel-body");
  const box = (el) => el.getBoundingClientRect();
  // Folded: the one list, the controls in it.
  // The control center's card and the notifications' own panel are two siblings (the redesign split them): the card
  // with its header and toggles, the panel right under it on its own frost to the screen's bottom, nothing overlapping.
  const foldedSplit = () => {
    const card = body.querySelector(":scope > .cc"), own = body.querySelector(":scope > .notif-own");
    if (!card) return ["folded: no control center card in the panel"];
    if (!own) return ["folded: no notifications panel of its own under the card"];
    const [bc, bo] = [box(card), box(own)];
    return [
      [card.querySelector(".cc3-cell"), "folded: the card shows no toggle"],
      [card.querySelector(".cc-main, .cc3-list") && bc.height > 0, "folded: the card has no header/toggle content"],
      [!own.querySelector(".cc"), "folded: the controls are inside the notifications' panel"],
      [bo.top >= bc.bottom - 1, `folded: the notifications overlap the card (${Math.round(bo.top)} < ${Math.round(bc.bottom)})`],
      [bo.top - bc.bottom <= 24, `folded: the notifications aren't directly under the card (${Math.round(bo.top - bc.bottom)} px gap)`],
      [bo.bottom >= innerHeight - 1, `folded: the notifications' panel ends ${Math.round(innerHeight - bo.bottom)} px above the screen's bottom`],
    ].filter(([ok]) => !ok).map(([, why]) => why);
  };
  const folded = () => [
    ...(body.classList.contains("two") ? [`folded (${innerWidth}px): two columns`] : []),
    ...foldedSplit(),
  ];
  // Unfolded: side by side, tops level, both a real width, each its own content and its own scroll.
  const columns = (n, c) => {
    const [bn, bc] = [box(n), box(c)];
    const scrolls = (el) => ["auto", "scroll"].includes(getComputedStyle(el).overflowY);
    return [
      [bn.right <= bc.left + 1, `notifications not left of the controls (${bn.right} > ${bc.left})`],
      [Math.abs(bn.top - bc.top) <= 2, `columns' tops differ (${bn.top} vs ${bc.top})`],
      [Math.min(bn.width, bc.width) >= 300, `a column too narrow (${bn.width}, ${bc.width})`],
      [c.querySelector(".cc") && !n.querySelector(".cc"), "the controls aren't (only) in the right column"],
      [n.querySelector(".notif-items"), "the notifications aren't in the left column"],
      [scrolls(n) && scrolls(c), "a column doesn't scroll on its own"],
      [box(document.querySelector(".notif-panel")).width >= innerWidth - 40, "the panel isn't the screen's width"],
    ].filter(([ok]) => !ok).map(([, why]) => why);
  };
  if (!body) return ["no panel body"];
  if (innerWidth < 700) return folded();
  const n = body.querySelector(":scope > .notif-col"), c = body.querySelector(":scope > .cc-col");
  return body.classList.contains("two") && n && c ? columns(n, c) : [`unfolded (${innerWidth}px): not two columns`];
}

/**
 * Over-pull (the control center is shown whole by default on a phone): a pull further ON THE CARD stretches - the card
 * and the notifications under it follow the finger damped (a subtle rubber band, at most 20 px; from the notifications
 * only their list moves, gesture.ts listOver), the toggles stay as they are; let go,
 * all springs back. The notifications' panel keeps reaching the screen's bottom and the seam to the card does not open.
 */
async function overpullShort() {
  const o = window.__op;
  const fails = [];
  const want = 20 * (1 - Math.exp(-30 / 100));
  await o.drag(30, () => {
    const d = o.under() - o.under0;
    if (d < 3) fails.push(`pulled 30 px further, what's under the control center moved ${Math.round(d)} px (no stretch)`);
    if (d > 12) fails.push(`pulled 30 px further, what's under the control center moved ${Math.round(d)} px (no damping)`);
    if (Math.abs(d - want) > 4) fails.push(`pulled 30 px further, the stretch is ${Math.round(d)} px, not about ${Math.round(want)}`);
    // The card follows too, not only what's under it: its first row and its top moved by the same.
    if (Math.abs(o.rowTop() - o.rowTop0 - d) > 2) fails.push(`pulled 30 px further, the card's row moved ${Math.round(o.rowTop() - o.rowTop0)} px, what's under it ${Math.round(d)} px`);
    if (Math.abs(o.cardTop() - o.cardTop0 - d) > 2) fails.push(`pulled 30 px further, the card's top moved ${Math.round(o.cardTop() - o.cardTop0)} px, not ${Math.round(d)}`);
    if (o.shown() !== o.n0) fails.push(`pulled 30 px further, ${o.shown()} toggles show, not ${o.n0} (an over-pull shows no more)`);
    // The notifications' own panel runs on to the screen's bottom, and no gap opens between it and the card.
    if (o.ownBottom() < innerHeight - 1) fails.push(`pulled 30 px further, the notifications' panel ends ${Math.round(innerHeight - o.ownBottom())} px above the screen's bottom`);
    if (Math.abs(o.seam() - o.seam0) > 2) fails.push(`pulled 30 px further, the seam between the card and the notifications went ${Math.round(o.seam0)} -> ${Math.round(o.seam())} px`);
  });
  if (Math.abs(o.under() - o.under0) > 1) fails.push(`let go, what's under the control center is ${Math.round(o.under() - o.under0)} px off its place (no spring back)`);
  if (Math.abs(o.rowTop() - o.rowTop0) > 1) fails.push(`let go, the card's row is ${Math.round(o.rowTop() - o.rowTop0)} px off its place`);
  if (o.shown() !== o.n0) fails.push(`let go, ${o.shown()} toggles show, not ${o.n0}`);
  return fails;
}

/**
 * All the way, from the compact row: the rest shown and laid out, what's under it moved down to where the whole view
 * had it, the row still, every stack unfolded. Pulled from the NOTIFICATIONS' list (the user, 2026-10-28: folded, a
 * down-pull on the notifications expands the control center as one on the card does - gesture.ts ccShowWay).
 */
async function overpullExpand() {
  const o = window.__op;
  const fails = [];
  await o.drag(260, null, o.midPull(fails, "pulling down"), ".panel-body.together > .notif-own .notif-list");
  o.settled(fails, "pulling down");
  if (!document.querySelector(".cc3-list.whole")) fails.push("pulled 260 px further, the rest isn't shown");
  if (Math.abs(o.under() - o.under0) > 1) fails.push(`expanded again, what's under the control center is ${Math.round(o.under() - o.under0)} px off the whole view's place`);
  if (o.shown() !== o.n0) fails.push(`expanded again, ${o.shown()} toggles show, not ${o.n0}`);
  if (o.row() !== o.row0) fails.push(`the first row moved on the expand: ${o.row0} -> ${o.row()}`);
  if (o.ownBottom() < innerHeight - 1) fails.push(`expanded, the notifications' panel ends ${Math.round(innerHeight - o.ownBottom())} px above the screen's bottom`);
  // The notifications show everything too (the user, 2026-10-24): every grouped stack unfolded into its cards.
  const stacks = [...document.querySelectorAll(".panel-body.together .notif-stack")];
  if (!stacks.length) fails.push("no grouped notifications in the shade to unfold");
  else if (stacks.some((g) => !g.classList.contains("open"))) fails.push(`expanded, ${stacks.filter((g) => !g.classList.contains("open")).length} of ${stacks.length} notification stacks stay folded`);
  return fails;
}

/**
 * The phone checks in the expanded Tools (ui/tests.ts; the user, 2026-10-24): the runner's state as the control's word,
 * a tap stops them (the test pill's x: verify.stop) and another resumes them (verify.go all), the shade staying open.
 */
async function overpullTests() {
  const cell = () => document.querySelector('.cc3-list [data-key="powos.tests"]');
  const word = () => cell()?.querySelector(".cc3-word")?.textContent ?? "";
  const pressed = () => cell()?.querySelector("button")?.getAttribute("aria-pressed");
  if (!(await window.__gw.until(() => cell(), 8000))) return ["expanded, no tests control in the controls (the mock's runner waits)"];
  const fails = [];
  const tap = async (want, on) => {
    cell().querySelector("button").click();
    if (!(await window.__gw.until(() => word() === want && pressed() === on))) fails.push(`tapped the tests control: it says "${word()}" (pressed ${pressed()}), not "${want}"`);
    // Over the runner's next answers (asked every 3 s), not flipped back.
    await window.__gw.sleep(3500);
    if (word() !== want) fails.push(`tapped the tests control: "${want}" went back to "${word()}"`);
  };
  if (word() !== "tests wait") fails.push(`the tests control says "${word()}", not "tests wait" (the mock's runner waits)`);
  await tap("tests paused", "false");
  await tap("tests wait", "true");
  if (!document.querySelector(".notif-panel.shown")) fails.push("a tap on the tests control closed the shade");
  return fails;
}

/**
 * A swipe up on the card folds it to one compact row (no half state): on the way what's under it follows the finger
 * up; folded, only the first six toggles show, no launchers, the notifications' panel right under the card and still
 * down to the screen's bottom, the row where it was.
 */
async function overpullFold() {
  const o = window.__op;
  const fails = [];
  const from = o.under();
  await o.drag(-80, () => {
    const d = o.under() - from;
    if (d > -20 || d < -83) fails.push(`folding 80 px, what's under the control center moved ${Math.round(d)} px (not with the finger)`);
    if (o.ownBottom() < innerHeight - 1) fails.push(`folding 80 px, the notifications' panel ends ${Math.round(innerHeight - o.ownBottom())} px above the screen's bottom`);
  }, o.midPull(fails, "folding back up"));
  o.settled(fails, "folding back up");
  o.n1 = o.shown();
  o.under1 = o.under();
  o.h = from - o.under1;
  if (document.querySelector(".cc3-list.whole") || o.n1 !== 6) fails.push(`pulled up 80 px, ${o.n1} toggles shown, not the one compact row of 6`);
  if (o.h < 40) fails.push(`folded, what's under the control center came up only ${Math.round(o.h)} px`);
  const launch = document.querySelector(".panel-body.together .cc3-launchers");
  if (launch && launch.getClientRects().length) fails.push("folded, the launchers still show under the row (not compact)");
  if (document.querySelector(".panel-body.together .notif-stack.open")) fails.push("folded, notification stacks stay unfolded");
  if (Math.abs(o.seam() - o.seam0) > 2) fails.push(`folded, the seam between the card and the notifications is ${Math.round(o.seam())} px, not ${Math.round(o.seam0)}`);
  if (o.ownBottom() < innerHeight - 1) fails.push(`folded, the notifications' panel ends ${Math.round(innerHeight - o.ownBottom())} px above the screen's bottom`);
  if (o.row() !== o.row0) fails.push(`folded, the first row isn't where it was: ${o.row0} -> ${o.row()}`);
  return fails;
}

/**
 * Opening and closing (the host's pull: shade.drag q, then shade.settle): the panel's edge comes down with the
 * pull - its frost no taller than the pull so far - and go back up with the close; settled, all where it was.
 */
async function panelTracksFinger() {
  const o = window.__op;
  const fails = [];
  const ev = window.__mockEvents;
  if (!ev) return ["no mock events to drive the shade's pull"];
  const top = document.querySelector(".notif-panel").getBoundingClientRect().top;
  const full = o.edge0 - Math.max(0, top);
  const seen = [];
  for (const q of [0.25, 0.5, 0.75]) {
    ev.emit("shade.drag", { q });
    // Until the panel stands where the pull put it (--q eases there), not a time.
    await window.__gw.settled(() => true, ".notif-panel");
    await window.__gw.steady(() => [o.edge()], 4);
    const e = o.edge();
    seen.push(Math.round(e));
    if (e > o.edge0 - (1 - q) * full * 0.6) fails.push(`pulled to ${q}, the panel's edge is already at ${Math.round(e)} of ${Math.round(o.edge0)} (a static slab)`);
  }
  if (!(seen[0] < seen[1] && seen[1] < seen[2])) fails.push(`the panel's edge didn't follow the pull down: ${seen.join(" -> ")}`);
  ev.emit("shade.settle", { open: true });
  await window.__gw.until(() => Math.abs(o.edge() - o.edge0) <= 1 && o.still());
  await window.__gw.steady(() => [o.edge()], 4);
  if (Math.abs(o.edge() - o.edge0) > 1) fails.push(`settled open, the panel's edge is ${Math.round(o.edge() - o.edge0)} px off its place`);
  return fails;
}

/** At rest: no animation in the panel, nothing the pull left inline. */
async function overpullRest() {
  const o = window.__op;
  const inline = () => [...document.querySelectorAll(".notif-panel, .notif-panel [style]")].filter((e) => e.style.translate || e.style.getPropertyValue("--cc-k") || e.style.getPropertyValue("--cc-lift") || e.style.transition);
  await window.__gw.until(() => o.still() && !inline().length);
  const left = inline();
  return [...(o.still() ? [] : ["an animation still runs in the panel at rest"]), ...(left.length ? [`the pull left inline values on ${left.length} elements`] : [])];
}

async function backFromApp(page, to, from, fresh) {
  await hideAs(page, true);
  await viewTo(page, from);
  await restAt(page, from);
  await page.evaluate(() => {
    window.__eatResize = (e) => e.stopImmediatePropagation();
    addEventListener("resize", window.__eatResize, { capture: true });
  });
  await viewTo(page, to);
  // At [to] and its resize event eaten (dispatched in the frames restAt waits), only then listened to again.
  await restAt(page, to);
  await page.evaluate(() => removeEventListener("resize", window.__eatResize, { capture: true }));
  await hideAs(page, false);
  await restAt(page, null, fresh);
}

/** Shown again still at the app's size (its last frame), then the window back at [to] with no resize event. */
async function shownAtAppSize(page, to, from, fresh) {
  await hideAs(page, true);
  await viewTo(page, from);
  await restAt(page, from);
  await hideAs(page, false);
  await restAt(page, from);
  await page.evaluate(() => {
    window.__eatResize = (e) => e.stopImmediatePropagation();
    addEventListener("resize", window.__eatResize, { capture: true });
  });
  await viewTo(page, to);
  await restAt(page, to, fresh);
  await page.evaluate(() => removeEventListener("resize", window.__eatResize, { capture: true }));
}

/** Relaid in the other column count while measured at a size, then in its own at that same size (the phone's race). */
async function otherColumns(page, to, fresh) {
  await columnsAs(page, true);
  await viewTo(page, { width: to.width, height: to.height - 1 });
  await restAt(page, { width: to.width, height: to.height - 1 });
  await viewTo(page, to);
  await restAt(page, to);
  await columnsAs(page, false);
  await restAt(page, null, fresh);
}

/**
 * Stale wide (2026-10-28, the cover screen in the desktop layout after the AI overlay): home resized to a desktop size
 * (wide), hidden, back at [to] with that resize event eaten, then shown. hosts/wide.ts measures the viewport again on
 * every show and read: home at a portrait [to] must not stay wide.
 */
async function staleWide(page, to) {
  const isWide = () => page.evaluate(() => !!document.querySelector(".home.wide"));
  const desk = { width: 1280, height: 800 };
  await viewTo(page, desk);
  await restAt(page, desk);
  if (!(await isWide())) return [`home isn't wide at ${desk.width}x${desk.height} (the scene's premise)`];
  await hideAs(page, true);
  await page.evaluate(() => {
    window.__eatResize = (e) => e.stopImmediatePropagation();
    addEventListener("resize", window.__eatResize, { capture: true });
  });
  await viewTo(page, to);
  await restAt(page, to);
  await page.evaluate(() => removeEventListener("resize", window.__eatResize, { capture: true }));
  await hideAs(page, false);
  await restAt(page, null);
  return (await isWide()) ? [`home stayed wide at ${to.width}x${to.height} after a desktop size, a resize dropped while hidden and a show`] : [];
}

/** The relayout case: each way of getting back to [to] must give a fresh layout's tiles and a full-width grid. */
async function relayout(page, to, from) {
  await viewTo(page, to);
  // A fresh layout: laid out and at rest (on a busy Mac the first tiles still moved in 800 ms after ready).
  await page.evaluate(() => window.__gw.until(() => document.querySelector(".page:not(.away) .home-tile")));
  await restAt(page, to);
  const fresh = await tileRects(page);
  if (!fresh.length) return ["no tiles laid out"];
  const like = fresh.join();
  const steps = [
    [`back from an app at ${from.width}x${from.height}`, () => backFromApp(page, to, from, like)],
    [`turned ${from.width}x${from.height} and back`, async () => (await viewTo(page, from), await restAt(page, from), await viewTo(page, to), await restAt(page, to, like))],
    ["relaid in its own columns at the same size", () => otherColumns(page, to, like)],
    [`shown at ${from.width}x${from.height}, then back with no resize event`, () => shownAtAppSize(page, to, from, like)],
  ];
  const bad = [];
  for (const [what, step] of steps) {
    await step();
    const now = await tileRects(page);
    if (now.join() !== fresh.join()) bad.push(`${what}: tiles not where a fresh layout puts them (${now.filter((x) => !fresh.includes(x)).slice(0, 2).join("; ")})`);
  }
  const cells = await page.evaluate(async () => {
    const S = await window.__gw.mod("./state.ts");
    const g = (await window.__gw.mod("./ui/grid.tsx")).geometry.value;
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
  const S = await window.__gw.mod("./state.ts");
  const { powos } = await window.__gw.mod("./bridge.ts");
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
  const S = await window.__gw.mod("./state.ts");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const tile = S.home.value.items.find((i) => i.kind === "widget" && i.cell?.w === 3);
  if (!tile) return ["no 3-wide widget to place across the middle"];
  await powos.home.place(tile.key, { ...tile.cell, x: 5, y: 12 }, 1);
  const cell = () => S.home.value.items.find((i) => i.key === tile.key)?.cell;
  await window.__gw.until(() => cell()?.x === 5 && cell()?.y === 12);
  const c = S.home.value.items.find((i) => i.key === tile.key)?.cell;
  return c?.x === 5 && c.y === 12 ? [] : [`${tile.key} placed across the middle at 5,12 shows at ${c?.x},${c?.y}`];
}

/** In the page: the wide screen's one bar - dock | search pill | recent apps, left to right, on one line. */
async function wideBar() {
  const S = await window.__gw.mod("./state.ts");
  S.dockPlacement.value = "bottom";
  await window.__gw.frames(2);
  // Some pinned apps (the mock pins none), the recent ones left for the right end.
  if (!S.dock.value.length) S.setDock([...S.byKey.value.keys()].slice(0, 4));
  const fails = [];
  const box = (q) => document.querySelector(q)?.getBoundingClientRect();
  const parts = [".home.wide > .dock:not(.dock-tray) .app", ".home.wide > .bar .bar-pill", ".home.wide > .dock-tray .app"];
  await window.__gw.settled(() => parts.every((q) => box(q)));
  await window.__gw.steady(() => parts.map((q) => box(q)?.toJSON()));
  const [dock, pill, tray] = parts.map(box);
  const lacks = [[dock, "the dock"], [pill, "the pill"], [tray, "the recent apps"]].filter(([r]) => !r).map(([, n]) => n);
  if (lacks.length) return [`the wide bar lacks ${lacks.join(", ")}`];
  if (!(dock.right <= pill.left && pill.right <= tray.left)) fails.push("the wide bar isn't dock | search | recent apps, left to right");
  const mid = (r) => r.top + r.height / 2;
  if (Math.abs(mid(dock) - mid(pill)) > 4 || Math.abs(mid(tray) - mid(pill)) > 4) fails.push("the wide bar's dock, pill and recent apps aren't on one line");
  return fails;
}

/**
 * Unfolded, the launcher opens above the bar like a desktop's start menu (the user, 2026-10-24): the dock, the pill and
 * the recent apps stay where they were, shown and tappable, and the drawer ends at the bar's top.
 */
async function wideLauncherBar() {
  // (Defined in here: the check runs in the page.)
  const seen = (el) => { let o = 1; for (let e = el; e; e = e.parentElement) o *= +getComputedStyle(e).opacity; return o; };
  const topmost = (el, r) => { const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return !!hit && (el.contains(hit) || hit.contains(el)); };
  /** With the launcher open, a part of the wide bar ([q], at [b] before): where it was, not faded, the topmost there. */
  const barPartOpen = (q, b) => {
    const el = document.querySelector(q), r = el?.getBoundingClientRect();
    if (!r) return [`launcher open: ${q} is gone`];
    return [
      [Math.abs(r.left - b.left) <= 1 && Math.abs(r.top - b.top) <= 1, `launcher open: ${q} moved ${Math.round(r.left - b.left)},${Math.round(r.top - b.top)} px`],
      [seen(el) >= 0.9, `launcher open: ${q} faded (${seen(el).toFixed(2)})`],
      [topmost(el, r), `launcher open: ${q} isn't tappable (something over it)`],
    ].filter(([ok]) => !ok).map(([, why]) => why);
  };
  const S = await window.__gw.mod("./state.ts");
  const parts = [".home.wide > .dock:not(.dock-tray) .app", ".home.wide > .bar .bar-pill", ".home.wide > .dock-tray .app"];
  const box = (q) => document.querySelector(q)?.getBoundingClientRect();
  const clip = () => box(".home.wide .launcher-clip");
  const before = parts.map(box);
  if (before.some((r) => !r)) return ["the wide bar lacks a part before the launcher opens"];
  S.drawer.value = 1;
  await window.__gw.settled(() => document.querySelector(".home.open"));
  await window.__gw.steady(() => [...parts.map((q) => box(q)?.toJSON()), clip()?.toJSON()]);
  if (!document.querySelector(".home.open")) return ["the wide launcher didn't open"];
  const fails = [];
  parts.forEach((q, i) => fails.push(...barPartOpen(q, before[i])));
  const top = Math.min(...parts.map((q) => box(q)?.top ?? Infinity));
  if (clip() && clip().bottom > top + 2) fails.push(`launcher open: the drawer runs ${Math.round(clip().bottom - top)} px into the bar`);
  S.drawer.value = 0;
  await window.__gw.settled(() => !document.querySelector(".home.open"));
  return fails;
}

/**
 * Desktop-size home (1280x800), the launcher open, its search typing: the keyboard comes up (the page 40% shorter, as
 * the IME makes it) and keys are typed - the field stays the focused one and the drawer isn't mounted again (the user,
 * 2026-10-28: desktop mode's launcher search dismissed the keyboard as they typed). Runs from node (viewport + keys).
 */
async function launcherKeyboardKeepsFocus(page) {
  const start = await page.evaluate(async () => {
    const S = await window.__gw.mod("./state.ts");
    S.drawer.value = 1;
    await window.__gw.settled(() => document.querySelector(".home.open"));
    const field = document.querySelector(".home > .bar textarea");
    const drawer = document.querySelector(".home .launcher-clip");
    if (!field || !drawer) return `the open launcher lacks ${field ? "its drawer" : "its search field"}`;
    const kb = (window.__kb = { field, drawer, wide: !!document.querySelector(".home.wide"), blurs: [] });
    field.addEventListener("blur", (e) => kb.blurs.push(e.relatedTarget ? `${e.relatedTarget.tagName.toLowerCase()}.${e.relatedTarget.className}` : "none"));
    field.focus();
    await window.__gw.frames(2);
    return document.activeElement === field ? "" : "the search field didn't take the focus";
  });
  if (start) return [`launcher keyboard: ${start}`];
  const held = (when) =>
    page.evaluate(async (w) => {
      await window.__gw.frames(2);
      const kb = window.__kb;
      const fails = [];
      if (document.activeElement !== kb.field) fails.push(`launcher keyboard, ${w}: the search field lost the focus (to ${document.activeElement?.tagName.toLowerCase() ?? "nothing"}${kb.blurs.length ? `; blurs to ${kb.blurs.join(", ")}` : ""})`);
      if (!kb.field.isConnected) fails.push(`launcher keyboard, ${w}: the search field was mounted again`);
      if (!kb.drawer.isConnected || document.querySelector(".home .launcher-clip") !== kb.drawer) fails.push(`launcher keyboard, ${w}: the drawer was mounted again`);
      if (!!document.querySelector(".home.wide") !== kb.wide) fails.push(`launcher keyboard, ${w}: home's wide layout flipped to ${!kb.wide}`);
      return fails;
    }, when);
  await viewTo(page, { width: 1280, height: 480 });
  const fails = await held("keyboard up (800 -> 480 px)");
  await page.keyboard.type("term", { delay: 40 });
  fails.push(...(await held("typed with the keyboard up")));
  await viewTo(page, { width: 1280, height: 800 });
  await page.evaluate(async () => {
    const S = await window.__gw.mod("./state.ts");
    S.query.value = "";
    window.__kb.field.blur();
    S.drawer.value = 0;
  });
  return fails;
}

/**
 * The launcher's search tapped with the dock on the side and the pill below it (the user's unfolded home, 2026-10-28:
 * `home dock-right wide pill-below` at 821x883, "the keyboard gets dismissed when I try to use it" - the field blurred to
 * nothing 0.5-1 s after the tap, connected, the window focused). The pill clicked as a finger does (bar.tsx's onClick:
 * the drawer opens, the field takes the focus), then the keyboard's resize; the field must hold the focus for 2 s.
 */
async function launcherKeyboardSide(page, view) {
  const setup = await page.evaluate(async () => {
    const S = await window.__gw.mod("./state.ts");
    const W = await window.__gw.mod("./ui/searchwidget.tsx");
    S.dockTry.value = "right";
    W.footBelow.value = "1";
    await window.__gw.settled(() => document.querySelector(".home.dock-right.pill-below > .bar textarea"));
    // The overlay is only up open: its pill leaves with the panel (shell.css .pull-screen > .bar follows --p).
    if (document.querySelector(".pull-screen")) { S.drawer.value = 1; await new Promise((ok) => setTimeout(ok, 400)); }
    await window.__gw.frames(4);
    const home = document.querySelector(".home");
    const field = document.querySelector(".home > .bar textarea");
    const kb = (window.__kbs = { field, log: [] });
    const tag = (a) => `${a.tagName.toLowerCase()}.${String(a.className).split(" ").join(".")}`;
    const unfocusable = (c) => c.display === "none" || c.visibility !== "visible" || c.contentVisibility !== "visible";
    const chain = (el) => { const out = []; for (let a = el; a; a = a.parentElement) if (a.inert || unfocusable(getComputedStyle(a))) out.push(tag(a)); return out.join(" "); };
    const why = (el) => `ro=${el.readOnly} ti=${el.tabIndex} same=${document.querySelector(".home > .bar textarea") === el} conn=${el.isConnected} active=${document.activeElement ? tag(document.activeElement) : "none"} hidden/inert=[${chain(el)}] home=${document.querySelector(".home")?.className}`;
    const t0 = performance.now();
    field.addEventListener("focus", () => kb.log.push(`${Math.round(performance.now() - t0)}ms focus`));
    field.addEventListener("blur", (e) => kb.log.push(`${Math.round(performance.now() - t0)}ms blur to=${e.relatedTarget ? e.relatedTarget.tagName.toLowerCase() + "." + e.relatedTarget.className : "none"} ${why(field)}`));
    kb.why = () => why(field);
    return home.className;
  });
  const r = await page.evaluate(() => { const b = document.querySelector(".home > .bar .bar-pill").getBoundingClientRect(); return [b.left + b.width / 2, b.top + b.height / 2]; });
  // A finger's tap (the phone's touch path through home's gestures), not a mouse click.
  const cdp = await page.target().createCDPSession();
  await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 });
  const touch = (type, pts) => cdp.send("Input.dispatchTouchEvent", { type, touchPoints: pts });
  await touch("touchStart", [{ x: r[0], y: r[1] }]);
  await new Promise((ok) => setTimeout(ok, 60));
  await touch("touchEnd", []);
  // The keyboard up as the phone's host reports it (the WebView keeps its size): "keyboard.inset" every frame of its
  // slide, then "system.insets" with its height (~40% of the screen).
  const kbPx = Math.round(view.height * 0.4);
  await page.evaluate(async (h) => {
    for (let y = 0; y <= h; y += h / 10) (window.__mockEvents.emit("keyboard.inset", Math.round(y)), await window.__gw.frames(1));
    window.__mockEvents.emit("system.insets", { top: 0, bottom: 0, left: 0, right: 0, keyboard: h });
  }, kbPx);
  await new Promise((ok) => setTimeout(ok, 1700));
  const out = await page.evaluate(() => ({ log: window.__kbs.log, held: document.activeElement === window.__kbs.field, now: window.__kbs.why() }));
  await page.evaluate(async () => {
    const S = await window.__gw.mod("./state.ts");
    const W = await window.__gw.mod("./ui/searchwidget.tsx");
    window.__mockEvents.emit("system.insets", { top: 0, bottom: 0, left: 0, right: 0, keyboard: 0 });
    window.__kbs.field.blur();
    S.drawer.value = 0;
    S.dockTry.value = "";
    W.footBelow.value = "";
  });
  const fails = [];
  // The launcher overlay (pull.tsx) is "unfolded" where home is "wide", and its pill is always at its foot (no pill-below).
  if (!/dock-right/.test(setup) || !(/pill-below/.test(setup) || /pull-screen/.test(setup)) || !/wide|unfolded/.test(setup)) fails.push(`launcher keyboard (side dock): home isn't dock-right wide pill-below (${setup})`);
  if (!out.held || out.log.some((l) => l.includes("blur"))) fails.push(`launcher keyboard (side dock, pill below): the search lost the focus within 2 s of the tap (${out.log.join("; ")})`);
  return fails.map((f) => `${f}; at the end: ${out.now}`);
}

/** The user's search widget on the grid (the phone, 2026-10-23): the bar's own pill, parked, keeps the bar's middle. */
async function wideBarParked() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/searchwidget.tsx");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const box = () => document.querySelector(".home.wide > .bar .bar-pill")?.getBoundingClientRect();
  const mid = (r) => r.top + r.height / 2;
  const pill = box();
  await powos.home.addPanel("search", S.pages.value[S.page.value] ?? 1, { x: 5, y: 0, w: 3, h: 1 });
  // Parked and at rest (the bar's own pill keeps its slot), not a time.
  await window.__gw.settled(() => document.querySelector(".home.wide.search-parked") && box());
  await window.__gw.steady(() => box()?.toJSON());
  const parked = document.querySelector(".home.wide.search-parked") && box();
  await W.putBackInBar();
  if (!parked?.width) return ["search widget on the grid: the bar's pill lost its slot"];
  return Math.abs(parked.left - pill.left) > 2 || Math.abs(mid(parked) - mid(pill)) > 2 ? ["search widget on the grid: the bar's pill moved out of the bar's middle"] : [];
}

/**
 * The open launcher: a swipe up over its list scrolls and keeps it open - also from its foot - and never closes it; the
 * home gesture (the host's bottom-edge swipe, "panel.close.*" events) is what closes it: it follows the finger, an
 * early release springs back, a full one shuts it (the user, 2026-10-28: "its home swipe up not general swipe up").
 */
async function closeUpCheck() {
  const S = await window.__gw.mod("./state.ts");
  const fails = [];
  const home = document.querySelector(".home");
  const drag = async (x, y0, dy) => {
    const fire = (type, y, buttons) => home.dispatchEvent(new PointerEvent(type, { pointerId: 11, pointerType: "mouse", clientX: x, clientY: y, buttons, bubbles: true, isPrimary: true }));
    fire("pointerdown", y0, 1);
    for (let d = 15; d <= dy; d += 15) {
      fire("pointermove", y0 - d, 1);
      await new Promise((ok) => setTimeout(ok, 16));
    }
    await new Promise((ok) => setTimeout(ok, 200));
    fire("pointerup", y0 - dy, 0);
    await new Promise((ok) => setTimeout(ok, 700));
  };
  const open = async () => {
    S.drawer.value = 1;
    await window.__gw.settled(() => document.querySelector(".home.open .drawer-list"));
  };
  const { powos } = await window.__gw.mod("./bridge.ts");
  const host = (event, data) => window.__mockEvents.emit(event, data);
  void powos;
  await open();
  const h = home.clientHeight;
  await drag(innerWidth * 0.5, h * 0.8, 120);
  if (!(S.drawer.value > 0)) fails.push("a swipe up over the open launcher's list closed it (it scrolls)");
  await drag(innerWidth * 0.5, h - 12, 160);
  if (!(S.drawer.value > 0)) fails.push("a swipe up from the open launcher's foot strip closed it (only the home gesture does)");
  // The host's home gesture with the panel open: follows, springs back on a short release.
  host("panel.close.begin", { kind: "apps" });
  host("panel.close.drag", { p: 0.5 });
  await new Promise((ok) => setTimeout(ok, 50));
  const mid = (await window.__gw.mod("./ui/gesture.ts")).drawerDrag.value;
  if (!(mid > 0.4 && mid < 0.6)) fails.push(`the panel did not follow the home gesture (openness ${mid}, want ~0.5)`);
  host("panel.close.end", { shut: false });
  await new Promise((ok) => setTimeout(ok, 300));
  if (!(S.drawer.value > 0)) fails.push("a home gesture released early did not leave the launcher open");
  host("panel.close.begin", { kind: "apps" });
  host("panel.close.drag", { p: 1 });
  host("panel.close.end", { shut: true });
  await new Promise((ok) => setTimeout(ok, 500));
  if (S.drawer.value > 0) fails.push("the home gesture released did not close the launcher");
  S.drawer.value = 0;
  return fails;
}

/**
 * In the page: content scrolling under chrome fades out at an edge with more to scroll, never cut (shell.css
 * scroll-fade; the user, 2026-10-24) - the drawer's apps: at the top only the foot fades, part-way both ends, at the end
 * only the top. Then closed again.
 */
async function scrollFadeCheck() {
  const S = await window.__gw.mod("./state.ts");
  S.drawer.value = 1;
  await window.__gw.settled(() => document.querySelector(".home.open .drawer-list"));
  const list = document.querySelector(".home .drawer-list");
  const fails = [];
  if (!list) return ["the open drawer has no app list"];
  if (!/gradient/.test(getComputedStyle(list).maskImage || getComputedStyle(list).webkitMaskImage || "")) fails.push("the drawer's list has no edge mask");
  if (list.scrollHeight - list.clientHeight < 80) fails.push(`the drawer's list doesn't scroll (${list.scrollHeight} in ${list.clientHeight}): nothing to check the fade on`);
  const fade = () => ["--scroll-fade-t", "--scroll-fade-b"].map((v) => Math.round(parseFloat(getComputedStyle(list).getPropertyValue(v)) || 0));
  const at = async (top, want, where) => {
    list.scrollTop = top;
    await window.__gw.steady(fade);
    const [t, b] = fade();
    if (t !== want[0] || b !== want[1]) fails.push(`${where}: the list's edge fades are ${t}/${b} px (top/foot), not ${want.join("/")}`);
  };
  if (!fails.length) {
    await at(0, [0, 24], "at the top");
    await at((list.scrollHeight - list.clientHeight) / 2, [24, 24], "part-way");
    await at(list.scrollHeight, [24, 0], "at the end");
    list.scrollTop = 0;
  }
  S.drawer.value = 0;
  await window.__gw.settled(() => !document.querySelector(".home.open"));
  return fails;
}

/** The folded dock's pinned apps never fade (the user, 2026-10-23): at rest on the pinned page its edges are unmasked. */
async function dockPinnedNoFade() {
  const S = await window.__gw.mod("./state.ts");
  const keys = [...S.byKey.value.keys()];
  if (!S.dock.value.length) S.setDock(keys.slice(0, 4));
  const pages = () => document.querySelector(".home > .dock.paged:not(.dock-tray) .dock-pages");
  // The dock paged and at rest: its scroll and the scroll-driven fade steady over frames.
  await window.__gw.until(pages);
  await window.__gw.steady(() => pages() && [pages().scrollLeft, getComputedStyle(pages()).getPropertyValue("--dock-fade-l"), getComputedStyle(pages()).getPropertyValue("--dock-fade-r")]);
  const el = pages();
  if (!el) return ["the folded dock isn't paged (pinned + recent apps) - nothing to check"];
  const cs = getComputedStyle(el);
  const fade = [cs.getPropertyValue("--dock-fade-l").trim(), cs.getPropertyValue("--dock-fade-r").trim()];
  return el.scrollLeft < 1 && fade.some((v) => v !== "0px") ? [`the pinned dock fades at rest (left ${fade[0]}, right ${fade[1]})`] : [];
}

/**
 * In the page, in edit mode (the user, 2026-10-22, three reports): the search bar is ON the grid as a tile like the
 * others, the dock stays in view; moved, it becomes the search widget there (and leaves the foot); resized, it keeps
 * the new size. Folded and unfolded.
 */
async function editSearchCheck() {
  const S = await window.__gw.mod("./state.ts");
  const shown = (el) => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility === "visible";
  S.editing.value = true;
  // Edit mode in: the search bar's tile on the grid, the foot's bar gone (its fade over).
  const tileOf = () => document.querySelector('.home-tile[data-key="panel:search"]');
  await window.__gw.settled(() => shown(tileOf()?.querySelector(".bar-pill")) && !shown(document.querySelector(".home > .bar")));
  const fails = [];
  const tile = tileOf();
  if (!shown(tile?.querySelector(".bar-pill"))) fails.push("edit mode: no search bar tile on the grid");
  if (!shown(document.querySelector(".home > .dock .app"))) fails.push("edit mode: the dock isn't in view");
  if (shown(document.querySelector(".home > .bar"))) fails.push("edit mode: the foot's search bar still shows beside its tile");
  return fails;
}

/** In the page, in edit mode after editSearchCheck: the search bar's tile moved and resized becomes the search widget. */
async function editSearchMoved() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/searchwidget.tsx");
  await window.__gw.until(() => W.footSearch.value);
  const was = W.footSearch.value;
  if (!was) return [`edit mode: no foot search item (searchwidget.tsx footSearch; editing ${S.editing.value}, a search widget ${W.hasSearchWidget()}, page ${S.page.value})`];
  const to = { x: 0, y: Math.max(0, was.cell.y - 1), w: 2, h: 1 };
  await W.placeItem("panel:search", to, was.page);
  const placed = () => S.home.value.items.find((i) => i.kind === "panel" && i.name === "search");
  await window.__gw.until(() => JSON.stringify(placed()?.cell ?? null) === JSON.stringify(to));
  S.editing.value = false;
  const real = placed();
  const at = JSON.stringify(real?.cell ?? null);
  return at === JSON.stringify(to) ? [] : [`moved and resized to ${JSON.stringify(to)}, the search widget is at ${at}`];
}

/** In the page: the first free 1x1 cell of the page in view, worked out here (not by grid.tsx placeNew), and a tap. */
const addAppHelpers = `window.__aa = {
  firstFree: (S, G, W) => {
    const n = S.pages.value[S.page.value] ?? 1;
    const items = [...S.home.value.items, ...(W.footSearch.value ? [W.footSearch.value] : [])].filter((i) => i.page === n && i.cell);
    const taken = items.map((i) => (i.resizable ? i.cell : { ...i.cell, w: 1, h: 1 }));
    const rows = G.geometry.value.rows, cols = S.home.value.columns;
    for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++)
      if (!taken.some((t) => x >= t.x && x < t.x + t.w && y >= t.y && y < t.y + t.h)) return { page: n, x, y };
    return null;
  },
  tap: (el) => {
    const r = el.getBoundingClientRect(), at = { bubbles: true, pointerId: 7, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2 };
    el.dispatchEvent(new PointerEvent("pointerdown", { ...at, buttons: 1 }));
    el.dispatchEvent(new PointerEvent("pointerup", at));
  },
  // Searched by its name, then tapped: a problem, or where it went (the first free cell, worked out first).
  pick: async (S, G, W, app, all) => {
    const field = document.querySelector(".app-picker textarea");
    field.value = app.label;
    field.dispatchEvent(new Event("input", { bubbles: true }));
    const results = () => [...document.querySelectorAll(".app-picker .drawer-list.results .app")];
    await window.__gw.until(() => results().some((c) => c.dataset.key === app.key) && results().length < all);
    const found = results();
    const want = found.find((c) => c.dataset.key === app.key);
    if (!want || found.length >= all || found.some((c) => !c.textContent.toLowerCase().includes(app.label.toLowerCase())))
      return \`+ app: search "\${app.label}" shows \${found.length} of \${all}, \${want ? "with" : "without"} it\`;
    const spot = window.__aa.firstFree(S, G, W);
    window.__aa.tap(want);
    await window.__gw.until(() => S.home.value.items.some((i) => i.app === app.key));
    await window.__gw.frames(2);
    const item = S.home.value.items.find((i) => i.app === app.key);
    if (!item || item.page !== spot.page || item.cell?.x !== spot.x || item.cell?.y !== spot.y)
      return \`+ app: \${app.label} at \${JSON.stringify(item && { page: item.page, ...item.cell })}, the first free cell is \${JSON.stringify(spot)}\`;
    if (!document.querySelector(".app-picker")) return "+ app: the picker closed after one pick";
    return { app: app.key, ...spot };
  },
}`;

/**
 * In the page, in edit mode (the user, 2026-10-23): "+ app" opens the drawer's list with its search; typing narrows it;
 * a tap puts the app on the page in view at its first free cell, and the picker stays for the next. Two picked.
 */
async function addAppCheck() {
  const S = await window.__gw.mod("./state.ts");
  const G = await window.__gw.mod("./ui/grid.tsx");
  const W = await window.__gw.mod("./ui/searchwidget.tsx");
  S.page.value = 0;
  S.editing.value = true;
  const addAct = () => [...document.querySelectorAll(".edit-sheet .edit-act")].find((b) => b.textContent.trim() === "+ app");
  // The sheet up and painted: its open effect (editsheet.tsx, after paint: appPicker = false) has run - a click before
  // it (a late frame) had the picker shut again at once.
  await window.__gw.settled(addAct);
  const act = addAct();
  if (!act) return ['edit bar: no "+ app"'];
  act.click();
  await window.__gw.until(() => document.querySelectorAll(".app-picker .grid.az .app").length >= 10);
  const all = document.querySelectorAll(".app-picker .grid.az .app").length;
  if (all < 10) return [`+ app: the drawer's A-Z list has ${all} apps (${S.apps.value.length} installed, the picker ${document.querySelector(".app-picker") ? "open" : "not open"})`];
  const on = (a) => S.home.value.items.some((i) => i.app === a.key || i.apps?.some((x) => x.app === a.key));
  const free = S.apps.value.filter((a) => !on(a) && S.apps.value.filter((b) => b.label === a.label).length === 1).slice(0, 2);
  const placed = [];
  for (const app of free) {
    const got = await window.__aa.pick(S, G, W, app, all);
    if (typeof got === "string") return [got];
    placed.push(got);
  }
  document.querySelector(".app-picker .sheet-done").click();
  S.editing.value = false;
  await window.__gw.settled(() => !document.querySelector(".app-picker"));
  localStorage.setItem("gate.addApp", JSON.stringify(placed));
  return placed.length === 2 ? [] : [`+ app: only ${placed.length} apps free to add`];
}

/** In the page, reloaded after addAppCheck: both apps still where they were placed. */
async function addAppReloaded() {
  const S = await window.__gw.mod("./state.ts");
  const placed = JSON.parse(localStorage.getItem("gate.addApp") ?? "[]");
  const missing = () => placed.filter((p) => !S.home.value.items.some((i) => i.app === p.app && i.page === p.page && i.cell?.x === p.x && i.cell?.y === p.y));
  await window.__gw.until(() => !missing().length);
  const lost = missing();
  return lost.length ? [`+ app after a reload: ${lost.map((p) => p.app).join(", ")} not where placed (${JSON.stringify(placed)})`] : [];
}

/**
 * App creation, live (the user, 2026-10-24: "show the app icon early with a spinner... when you open it, you can see
 * the work in progress"): a mock build from scratch (ui/appbuild.tsx's chat-driven pendingApp) - the placeholder
 * appears the moment the thread starts, its progress advances as mock tool-call events land, tapping it shows the
 * being-built view, and once it's installed the placeholder gives way to the real app in the same settle (never a
 * frame with both, never a frame with neither).
 */
async function pendingAppCheck() {
  const S = await window.__gw.mod("./state.ts");
  const B = await window.__gw.mod("./ui/appbuild.tsx");
  const P = await window.__gw.mod("./apps/pages.ts");
  const fails = [];
  // The launcher (the overlay's page) open, as the user sees the placeholder in it.
  S.drawer.value = 1;
  S.chat.value = { busy: true, items: [{ kind: "user", text: "a shopping list" }], thread: { dir: "/tmp/gate-app", title: "a shopping list", kind: "app" } };
  await window.__gw.settled(() => document.querySelector(".pending-app"));
  if (!document.querySelector(".pending-app")) fails.push("app creation: no placeholder in the drawer at the start");
  if (B.pendingApp.value?.status !== "running") fails.push(`app creation: pendingApp.status is ${B.pendingApp.value?.status} at the start, not "running"`);
  S.chat.value = { ...S.chat.value, items: [...S.chat.value.items, { kind: "tool", name: "Bash", hint: "powos app new shop", ok: true }] };
  await window.__gw.settled(() => B.pendingApp.value?.steps.some((s) => s.state === "done"));
  if (!B.pendingApp.value?.steps.some((s) => s.state === "done")) fails.push("app creation: a finished mock tool call never marks a step done");
  document.querySelector(".pending-app")?.click();
  await window.__gw.settled(() => document.querySelector(".pending-build"));
  if (!document.querySelector(".pending-build .pending-steps .pending-step")) fails.push("app creation: tapping the placeholder shows no being-built view (progress bar + step list)");
  document.body.click();
  P.installedApps.value = [...P.installedApps.value, { id: "local.shop", name: "Shop", version: "0.1.0", database: "local-shop", tier: 0, manifest: "{}" }];
  S.chat.value = { ...S.chat.value, busy: false, items: [...S.chat.value.items, { kind: "tool", name: "Bash", hint: "powos app install /tmp/gate-app", ok: true }] };
  await window.__gw.settled(() => !document.querySelector(".pending-app"));
  if (document.querySelector(".pending-app")) fails.push("app creation: the placeholder is still up once the app is installed - no in-place swap");
  P.installedApps.value = P.installedApps.value.filter((a) => a.id !== "local.shop");
  S.chat.value = { busy: false, items: [] };
  return fails;
}

/**
 * Widget creation, live (docs/COMPOSER.md; ui/creationwidgets.tsx): a mock `creation` row from scratch (as
 * lib/apps/powos-compose writes to powos-registry) - a placeholder reserves a spot on home at once, its progress
 * advances as mock step events land, tapping it shows the being-built view, and once it's done the real widget is
 * placed at THAT SAME reserved spot (no jump) with the placeholder gone in the same settle.
 */
async function pendingWidgetCheck() {
  const S = await window.__gw.mod("./state.ts");
  const R = await window.__gw.mod("./apps/registry.ts");
  const Bridge = await window.__gw.mod("./bridge.ts");
  const C = await window.__gw.mod("./ui/creationwidgets.tsx");
  const cid = "widget:gate-test-123456";
  const tile = () => document.querySelector(`.home-tile[data-key="creation:${cid}"]`);

  async function started() {
    S.page.value = 0;
    R.creationRows.value = {
      creations: [{ id: cid, kind: "widget", title: "a test widget", status: "running", step: "Choosing what it uses", stepIndex: 0, stepCount: 2, error: "", appId: "" }],
      steps: [
        { id: `${cid}:0`, creationId: cid, idx: 0, label: "Choosing what it uses", state: "active" },
        { id: `${cid}:1`, creationId: cid, idx: 1, label: "Installing", state: "pending" },
      ],
      logs: [],
    };
    await window.__gw.settled(() => tile());
    const fails = [];
    if (!tile()) fails.push("widget creation: no placeholder tile reserved on home at the start");
    const spot = C.reservedSpotFor(cid);
    if (!spot) fails.push("widget creation: no spot reserved for the running creation");
    return { fails, spot };
  }

  async function advanced() {
    R.creationRows.value = { ...R.creationRows.value, steps: R.creationRows.value.steps.map((s) => ({ ...s, state: s.idx === 0 ? "done" : "active" })) };
    await window.__gw.settled(() => tile()?.querySelector(".pending-bar-fill")?.style.width && tile().querySelector(".pending-bar-fill").style.width !== "0%");
    const fill = tile()?.querySelector(".pending-bar-fill")?.style.width;
    return fill && fill !== "0%" ? [] : ["widget creation: progress never advances on a mock step event"];
  }

  async function buildingViewShown() {
    tile()?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await window.__gw.settled(() => document.querySelector(".pending-build"));
    const ok = document.querySelector(".pending-build .pending-steps .pending-step");
    document.body.click();
    return ok ? [] : ["widget creation: tapping the placeholder shows no being-built view"];
  }

  async function swappedInPlace(spot) {
    let added = null;
    const origAdd = Bridge.powos.home.addPanel;
    Bridge.powos.home.addPanel = (...a) => ((added = a), Promise.resolve());
    R.creationRows.value = { ...R.creationRows.value, creations: [{ ...R.creationRows.value.creations[0], status: "done", appId: "local.gate-test/main" }] };
    await window.__gw.settled(() => !tile());
    Bridge.powos.home.addPanel = origAdd;
    const fails = [];
    if (tile()) fails.push("widget creation: the placeholder is still up once it's done - no in-place swap");
    if (!added || added[0] !== "app:local.gate-test/main") fails.push(`widget creation: the real widget wasn't placed once done (addPanel args ${JSON.stringify(added)})`);
    if (added && spot && (added[1] !== spot.page || JSON.stringify(added[2]) !== JSON.stringify(spot.cell)))
      fails.push(`widget creation: the real widget landed at page ${added[1]} ${JSON.stringify(added[2])}, not the reserved spot ${spot.page} ${JSON.stringify(spot.cell)} - a jump`);
    return fails;
  }

  const { fails: f1, spot } = await started();
  const fails = [...f1, ...(await advanced()), ...(await buildingViewShown()), ...(await swappedInPlace(spot))];
  R.creationRows.value = { creations: [], steps: [], logs: [] };
  return fails;
}

/**
 * In the page: a folder opens as a morph (the user, 2026-10-23: "so jarring") - moving at first (the sheet drawn at the
 * tile, easing out), then at rest with nothing left inline and no animation running, home's pages faded behind a
 * page-sized frost; closed, it shrinks back and goes.
 */
async function folderMorphCheck() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await window.__gw.mod("./state.ts");
  S.page.value = S.pages.value.length;
  await window.__gw.settled(() => document.querySelector(".page.library .lib-card"));
  const card = document.querySelector(".page.library .lib-card");
  if (!card) return ["morph: no library card to open"];
  // Waits on the state, not on time (a busy gate: frames lag the clock, a transition starts late and ends late).
  const until = async (f, ms = 3000) => { for (const t0 = performance.now(); !f() && performance.now() - t0 < ms; ) await sleep(0); };
  card.click();
  await until(() => document.querySelector(".folder-view .folder-bg"));
  const bg = document.querySelector(".folder-view .folder-bg");
  const fails = [];
  if (!bg || !bg.style.transition.includes("transform")) fails.push("morph: opening, the sheet doesn't ease from the tile (no transform transition)");
  const v = document.querySelector(".folder-view.open");
  if (!v) return [...fails, "morph: the folder isn't open"];
  const inline = () => [...v.querySelectorAll("[style]")].filter((e) => e.style.transform || e.style.transition);
  await until(() => !inline().length);
  const left = inline();
  if (left.length) fails.push(`morph: at rest ${left.length} parts keep an inline transform or transition`);
  // The sheet's own (an icon still loading pulses: icon-wait, not the morph's); documentAnimations already
  // excludes a scroll-driven one under the sheet, which otherwise "runs" forever and never settles (friction f125).
  const running = window.__gw.documentAnimations(".folder-view.open").filter((a) => a.animationName !== "icon-wait").length;
  if (running) fails.push(`morph: at rest ${running} animations still running in the sheet`);
  if (!v.querySelector(".folder-focus.tile")) fails.push("morph: no page-sized frost behind the sheet");
  if (getComputedStyle(document.querySelector(".page-track > .page")).opacity !== "0") fails.push("morph: home's pages still show behind the open folder");
  return fails;
}

/** In the page, after folderMorphCheck (a folder open): centred; closed, it shrinks back and goes. */
async function folderCloseCheck() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await window.__gw.mod("./state.ts");
  const sheet = document.querySelector(".folder-view .folder-sheet").getBoundingClientRect();
  const fails = Math.abs(sheet.left + sheet.width / 2 - innerWidth / 2) > 4 ? ["morph: the sheet isn't centred"] : [];
  const until = async (f, ms = 3000) => { for (const t0 = performance.now(); !f() && performance.now() - t0 < ms; ) await sleep(0); };
  S.folder.value = null;
  await until(() => !document.querySelector(".folder-view.open"));
  if (!document.querySelector(".folder-view:not(.open)")) fails.push("morph: closing, the sheet doesn't shrink back (gone at once)");
  const faceShown = () => [...document.querySelectorAll(".home-tile.folder .folder-face")].every((f) => getComputedStyle(f).opacity !== "0");
  const sheetIcons = () => [...document.querySelectorAll(".folder-view .folder-grid .app-icon")].slice(0, 4).some((i) => getComputedStyle(i).opacity !== "0");
  let blank = false;
  for (const t0 = performance.now(); document.querySelector(".folder-view") && performance.now() - t0 < 3000; blank ||= !faceShown() && !sheetIcons()) await new Promise(requestAnimationFrame);
  if (blank) fails.push("morph: closing, a frame with neither the tile's icons nor the sheet's (empty tile)");
  await requestAnimationFrame(() => {});
  if (document.querySelector(".folder-view")) fails.push("morph: closed, the folder view is still there after 3 s");
  else if (!faceShown()) fails.push("morph: closed, a folder tile's face is still hidden");
  return fails;
}

/**
 * In the page: home's last page is the app library (the user, 2026-10-23) - every installed app in exactly one of its
 * folders (the user's own as they are, a category's for the rest), a card for each.
 */
async function libraryCheck() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await window.__gw.mod("./state.ts");
  const L = await window.__gw.mod("./ui/library.tsx");
  S.page.value = S.pages.value.length;
  // Until the track's slide is through (frames lag the clock on a busy gate), at most 3 s.
  const expectedLeft = () => document.querySelector(".pages").getBoundingClientRect().left;
  const at = () => (document.querySelector(".page-track > .page.library")?.getBoundingClientRect().left ?? 1e9) - expectedLeft();
  for (const t0 = performance.now(); Math.abs(at()) > 2 && performance.now() - t0 < 3000; ) await sleep(20);
  const lib = document.querySelector(".page-track > .page.library");
  if (!lib || lib !== document.querySelector(".page-track").lastElementChild) return ["the app library isn't home's last page"];
  const r = lib.getBoundingClientRect();
  const fails = Math.abs(r.left - expectedLeft()) > 2 ? [`swiped to the last page, the app library is at x ${Math.round(r.left)}, not on screen`] : [];
  const seen = L.library.value.flatMap((f) => f.apps.map((a) => a.app));
  const twice = seen.filter((k, i) => seen.indexOf(k) !== i);
  // One per name: an app whose name another shows already is that one.
  const names = new Set(L.library.value.flatMap((f) => f.apps.map((a) => a.label.trim().toLowerCase())));
  const missing = S.apps.value.filter((a) => !seen.includes(a.key) && !names.has(a.label.trim().toLowerCase())).map((a) => a.key);
  if (twice.length || missing.length) fails.push(`the library: ${missing.length} apps in no folder (${missing.slice(0, 3)}), ${twice.length} in two (${twice.slice(0, 3)})`);
  if (lib.querySelectorAll(".lib-card").length !== L.library.value.length) fails.push("the library shows a different number of folders than it has");
  return fails;
}

/** In the page, on the app library (after libraryCheck): no search bar of its own; an app installed or removed shows or goes at once. */
async function libraryLiveCheck() {
  const S = await window.__gw.mod("./state.ts");
  const L = await window.__gw.mod("./ui/library.tsx");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const lib = document.querySelector(".page.library");
  const fails = [];
  // No search field of its own (the user, 2026-10-29: "We don't need that search apps bar on top of the folder page").
  if (lib.querySelector(".lib-search, input")) fails.push("the library page has a search bar of its own");
  const list = powos.apps.list;
  const fake = { key: "a:org.gate.chess/.Main", label: "Gate Chess", icon: "", kind: "android", category: 0 };
  powos.apps.list = async () => [...(await list()), fake];
  window.__mockEvents.emit("apps.changed", null);
  const folderOf = () => L.library.value.find((f) => f.apps.some((a) => a.app === fake.key))?.key;
  await window.__gw.until(() => folderOf() === "lib:games");
  if (L.library.value.find((f) => f.apps.some((a) => a.app === fake.key))?.key !== "lib:games") fails.push("an app installed (Android category game) isn't in the library's Games folder");
  powos.apps.list = list;
  window.__mockEvents.emit("apps.changed", null);
  await window.__gw.until(() => !folderOf());
  if (L.library.value.some((f) => f.apps.some((a) => a.app === fake.key))) fails.push("an app removed stays in the library");
  return fails;
}

/** In the page, on the app library: an app held in a folder card and dragged to the screen's side turns to a real page and lands on home where it's let go. */
async function libraryDragCheck() {
  const S = await window.__gw.mod("./state.ts");
  const G = await window.__gw.mod("./ui/grid.tsx");
  const fire = (el, type, x, y) => el.dispatchEvent(new PointerEvent(type, { pointerId: 13, pointerType: "touch", clientX: x, clientY: y, bubbles: true, isPrimary: true }));
  const onHome = new Set(S.home.value.items.map((i) => i.app).filter(Boolean));
  const card = [...document.querySelectorAll(".page.library .lib-card")].find((c) => !c.dataset.key.startsWith("folder:"));
  card?.click();
  // Open and at rest: the morph's inline moves cleared (folderview.tsx rest()).
  const view = () => document.querySelector(".folder-view.open");
  await window.__gw.until(() => view() && !view().querySelector('[style*="transform"], [style*="transition"]') && window.__gw.still(".folder-view"));
  const el = [...document.querySelectorAll(".folder-view.open .folder-grid .app")].find((e) => !onHome.has(e.dataset.key));
  if (!el) return ["the library's folder opened shows no app that isn't on home already, to drag"];
  const key = el.dataset.key;
  const r = el.getBoundingClientRect();
  const pages = document.querySelector(".pages");
  fire(el, "pointerdown", r.left + r.width / 2, r.top + r.height / 2);
  // The long press (grid.tsx LONG_PRESS_MS) lifted it: carried.
  await window.__gw.until(() => document.querySelector(".carried"));
  const g = G.geometry.value;
  fire(pages, "pointermove", g.left + 4, r.top);
  // Held at the side until home turns from the library to a page, and the track's slide is over.
  await window.__gw.until(() => S.page.value < S.pages.value.length);
  await window.__gw.steady(() => document.querySelector(".page-track")?.getBoundingClientRect().left);
  if (S.page.value >= S.pages.value.length) return [`held at the side, the app library didn't turn to a home page (page ${S.page.value})`];
  const spot = G.placeNewCells(1, 1);
  const [x, y] = [g.left + g.pad + (spot.cell.x + 0.5) * g.cellW, g.top + g.pad + (spot.cell.y + 0.5) * g.cellH];
  for (let k = 1; k <= 4; k++) fire(pages, "pointermove", g.left + 4 + ((x - g.left - 4) * k) / 4, r.top + ((y - r.top) * k) / 4);
  await window.__gw.frames(2);
  fire(pages, "pointerup", x, y);
  const cellOf = () => S.home.value.items.find((i) => i.app === key)?.cell;
  await window.__gw.until(() => cellOf()?.x === spot.cell.x && cellOf()?.y === spot.cell.y);
  const c = cellOf();
  const at = c ? `${c.x},${c.y}` : "not on home";
  return at === `${spot.cell.x},${spot.cell.y}` ? [] : [`${key} dragged from the library to ${spot.cell.x},${spot.cell.y} is ${at}`];
}

/**
 * In the page (the user, 2026-10-23, the 4th report: as a widget, search "no longer works with the pull-up launcher"):
 * by default the pill is in the bar and "+ widget" lists it; the drawer opened from it has the bar's pill to type in.
 */
async function searchDefaultCheck() {
  const S = await window.__gw.mod("./state.ts");
  const A = await window.__gw.mod("./ui/appwidget.tsx");
  const fails = [];
  const shown = (el) => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility === "visible" && +getComputedStyle(el).opacity > 0.5;
  if (S.home.value.items.some((i) => i.kind === "panel" && i.name === "search")) fails.push("the mock home starts with the search widget on the grid");
  if (!shown(document.querySelector(".home > .bar .bar-pill"))) fails.push("default: no search pill in the bar");
  S.editing.value = true;
  A.picker.value = true;
  await window.__gw.until(() => /search bar/.test(document.body.innerText));
  if (!/search bar/.test(document.body.innerText)) fails.push('"+ widget" doesn\'t list the search bar');
  A.picker.value = false;
  S.editing.value = false;
  // Out of edit mode and at rest: the bar's pill back (what the next check starts from).
  await window.__gw.settled(() => shown(document.querySelector(".home > .bar .bar-pill")));
  return fails;
}

/** A pull up from [el] (a mouse drag: home's gesture path for a desktop browser), then the drawer's state. */
async function pullUpFrom(el) {
  const r = el.getBoundingClientRect();
  // Right of the middle: the left half's pull-up can be PowOS AI's panel (state.ts pullPanels), not the drawer.
  const [x, y] = [r.left + r.width * 0.8, r.top + r.height / 2];
  const fire = (type, dy, buttons) => el.dispatchEvent(new PointerEvent(type, { pointerId: 9, pointerType: "mouse", clientX: x, clientY: y - dy, buttons, bubbles: true, isPrimary: true }));
  fire("pointerdown", 0, 1);
  // The first move already past SLOP (10 px): on a tile, pointerdown starts the long press (grid.tsx LONG_PRESS_MS,
  // a 420 ms timer) and only a move past SLOP cancels it. A first move inside SLOP left it armed; on a loaded gate the
  // next one came 800 ms later, after the lift ("pulled up from the widget: the drawer didn't open", editing on).
  // A real finger's moves come as input, ahead of timers.
  for (let dy = 15; dy <= 225; dy += 30) {
    fire("pointermove", dy, 1);
    await new Promise((ok) => setTimeout(ok, 16));
  }
  fire("pointerup", 225, 0);
  // Home's page: the launcher is the overlay (pull.tsx) - home asks the host for it (homeAsks).
  if (window.__asked) return void (await window.__gw.settled(() => window.__asked.length));
  // Until it's open and come to rest - the bar's pill over it faded in (drawerWithPill's checks), at most 3 s.
  const bar = () => document.querySelector(".home > .bar");
  await window.__gw.settled(() => document.querySelector(".home.open") && bar() && +getComputedStyle(bar()).opacity >= 0.9);
  await window.__gw.steady(() => [document.querySelector(".home .launcher-clip")?.getBoundingClientRect().bottom, bar()?.querySelector(".bar-pill")?.getBoundingClientRect().top]);
}

/**
 * The drawer is open with the bar's pill on screen, over the drawer's window (not under an app row). On home's page
 * (homeAsks): home asked the host for the launcher overlay - with its search focused when [search].
 */
function drawerWithPill(where, search) {
  if (window.__asked) return window.__sp.overlayAsked(where, search);
  const pill = document.querySelector(".home > .bar .bar-pill")?.getBoundingClientRect();
  const clip = document.querySelector(".home .launcher-clip")?.getBoundingClientRect();
  const bar = document.querySelector(".home > .bar");
  const fails = [];
  if (!document.querySelector(".home.open")) return [`${where}: the drawer didn't open`];
  if (!pill?.width || +getComputedStyle(bar).opacity < 0.9) fails.push(`${where}: the open drawer has no search pill`);
  else if (clip && clip.bottom > pill.top + 2) fails.push(`${where}: the drawer's window runs ${Math.round(clip.bottom - pill.top)} px under the pill`);
  return fails;
}

/** Closes the drawer (Back's way) and waits for it to settle. */
async function closeDrawerNow() {
  const S = await window.__gw.mod("./state.ts");
  S.closeDrawer?.();
  if (S.drawer.value) S.drawer.value = 0;
  await window.__gw.settled(() => !S.drawer.value && !document.querySelector(".home.open"));
}

/**
 * In the page: the search widget, wherever it sits, drives the pull-up launcher as the bar's pill does - pulled up
 * from or tapped, in the bar and on the grid; put back (the tile's button), it's the bar's again. Folded and unfolded.
 */
async function searchLauncherCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/searchwidget.tsx");
  const fails = [];
  const { pullUpFrom, drawerWithPill, closeDrawerNow, searchPutBack, searchToDock } = window.__sp;
  await pullUpFrom(document.querySelector(".home > .bar .bar-pill"));
  fails.push(...drawerWithPill("pulled up from the bar"));
  await closeDrawerNow();
  // Moved onto the grid (edit mode, as a finger does: placeItem).
  S.editing.value = true;
  await window.__gw.until(() => W.footSearch.value);
  const was = W.footSearch.value;
  if (!was) return [...fails, "edit mode: no search tile to move"];
  await W.placeItem("panel:search", { ...was.cell, y: Math.max(0, was.cell.y - 1) }, was.page);
  S.editing.value = false;
  // Until the widget is on the grid and the bar's pill faded out (a fade: on a busy gate it hadn't ended in 500 ms).
  const widget = () => document.querySelector('.home-tile[data-key="panel:search"] .bar-pill');
  await window.__gw.settled(() => widget() && +getComputedStyle(document.querySelector(".home > .bar")).opacity <= 0.1);
  const tile = widget();
  if (!tile) return [...fails, "moved: no search widget on the grid"];
  if (+getComputedStyle(document.querySelector(".home > .bar")).opacity > 0.1) fails.push("moved: the bar's pill still shows beside the widget");
  await pullUpFrom(tile);
  fails.push(...drawerWithPill("pulled up from the widget"));
  await closeDrawerNow();
  tile.click();
  // Home's pill is only the launcher's face: the overlay's field types (search-launcher-overlay checks that side).
  await window.__gw.settled(() => window.__asked.length);
  fails.push(...drawerWithPill("tapped on the widget", true));
  if (document.activeElement?.closest?.(".home > .bar, .home-tile")?.querySelector("textarea") === document.activeElement) fails.push("tapped on the widget: home's own field took the typing, not the launcher's");
  await closeDrawerNow();
  return [...fails, ...(await searchPutBack()), ...(await searchToDock())];
}

/** Still in edit mode, folded, after the drop under the dock: the pill stays where it was put, under the dock (not
 *  back on top as a grid tile - the user, 2026-10-28). */
async function pillBelowDockInEdit(W, wide) {
  if (wide) return [];
  const bar = document.querySelector(".home > .bar");
  await window.__gw.settled(() => getComputedStyle(bar).visibility === "visible");
  const p = bar.querySelector(".bar-pill").getBoundingClientRect();
  // The dock's icons, not its box: the box has transparent padding under the icons that the pill may sit in.
  const icons = [...document.querySelectorAll(".home > .dock:not(.dock-tray) .app-icon")].map((e) => e.getBoundingClientRect()).filter((r) => r.height);
  const d = { bottom: Math.max(...icons.map((r) => r.bottom), -Infinity) };
  const fails = W.footSearch.value ? ["edit mode after the drop under the dock: the pill is a grid tile again"] : [];
  if (getComputedStyle(bar).visibility !== "visible" || p.top < d.bottom - 1)
    fails.push(`edit mode after the drop under the dock: the pill isn't below the dock (pill top ${p.top}, dock bottom ${d.bottom})`);
  return fails;
}

/**
 * The user's own move (2026-10-23, 5th report): edit mode, the search bar's tile carried down onto the dock and let
 * go - the pill is in the foot under the dock (folded), back in the bar (unfolded), and the drawer still has it.
 */
async function searchToDock() {
  const S = await window.__gw.mod("./state.ts");
  const G = await window.__gw.mod("./ui/grid.tsx");
  const W = await window.__gw.mod("./ui/searchwidget.tsx");
  const wide = !!document.querySelector(".home.wide");
  W.footBelow.value = "";
  S.editing.value = true;
  // Folded the dock's row (under the dock); wide the one bar's middle (no "under" there).
  const foot = wide ? ".home > .edit-sheet" : ".home > .dock:not(.dock-tray)";
  await window.__gw.settled(() => document.querySelector('.home-tile[data-key="panel:search"]') && W.footSearch.value && document.querySelector(foot));
  const tile = document.querySelector('.home-tile[data-key="panel:search"]')?.getBoundingClientRect();
  const to = document.querySelector(foot)?.getBoundingClientRect();
  if (!tile || !W.footSearch.value || !to) return ["edit mode: no search tile or foot to drag it to"];
  const at = (type, x, y) => new PointerEvent(type, { pointerId: 11, pointerType: "touch", clientX: x, clientY: y, bubbles: true, isPrimary: true });
  G.startCarry({ item: W.footSearch.value }, at("pointerdown", tile.left + 20, tile.top + 10), { x: 20, y: 10 });
  window.dispatchEvent(at("pointermove", to.left + to.width / 2, to.top + to.height / 2));
  await window.__gw.frames(2);
  window.dispatchEvent(at("pointerup", to.left + to.width / 2, to.top + to.height / 2));
  await window.__gw.until(() => W.footBelow.value === (wide ? "" : "1") && !W.hasSearchWidget());
  const fails = [];
  fails.push(...(await window.__sp.pillBelowDockInEdit(W, wide)));
  S.editing.value = false;
  await window.__gw.settled(() => !document.querySelector(".carried"));
  if (W.footBelow.value !== (wide ? "" : "1")) fails.push(`dragged onto the foot: footBelow is "${W.footBelow.value}"`);
  if (W.hasSearchWidget()) fails.push("dragged onto the foot: the search widget stayed on the grid");
  await window.__sp.pullUpFrom(document.querySelector(".home > .bar .bar-pill"));
  fails.push(...window.__sp.drawerWithPill("pulled up after the drop on the foot"));
  await window.__sp.closeDrawerNow();
  W.footBelow.value = "";
  return fails;
}

/** Home's page (homeAsks): what home asked the host's launcher overlay for, since the last pull or tap. */
function overlayAsked(where, search) {
  const asked = window.__asked.splice(0);
  if (!asked.length) return [`${where}: the launcher overlay wasn't asked to open`];
  if (asked[0].kind !== "apps") return [`${where}: the launcher overlay was asked for ${asked[0].kind}, not the apps`];
  return search && !asked[0].how?.search ? [`${where}: the launcher overlay wasn't asked to focus its search`] : [];
}

/** Home's page: the host's launcher overlay recorded, not opened (Bridge.pull.open; the browser gate has no host). */
async function homeAsks() {
  const { powos } = await window.__gw.mod("./bridge.ts");
  window.__asked = [];
  powos.pull.open = async (kind, how) => (window.__asked.push({ kind, how }), true);
}

/**
 * The launcher overlay's side of a tap on home's pill or search widget (pull.begin { search } then pull.end { open }
 * from the host): it opens with its pill on screen and its own field focused, typing.
 */
async function overlaySearchCheck() {
  window.__mockEvents.emit("pull.begin", { kind: "apps", search: true });
  window.__mockEvents.emit("pull.end", { open: true });
  const field = () => document.querySelector(".home > .bar textarea");
  const bar = () => document.querySelector(".home > .bar");
  await window.__gw.settled(() => document.querySelector(".home.open") && +getComputedStyle(bar()).opacity >= 0.9 && document.activeElement === field());
  const fails = window.__sp.drawerWithPill("opened from home's pill");
  if (!field() || document.activeElement !== field()) fails.push("opened from home's pill: the launcher's field isn't the one typing");
  return fails;
}

/** The tile's "put back in bar": the widget leaves the grid, the bar has the pill at rest again. */
async function searchPutBack() {
  const S = await window.__gw.mod("./state.ts");
  S.editing.value = true;
  S.selected.value = "panel:search";
  const putBack = () => [...document.querySelectorAll(".tile-actions button")].find((b) => b.textContent.trim() === "put back in bar");
  await window.__gw.until(putBack);
  const button = putBack();
  if (!button) return ["edit mode: the search widget has no \"put back in bar\""];
  button.click();
  const onGrid = () => S.home.value.items.some((i) => i.kind === "panel" && i.name === "search");
  await window.__gw.until(() => !onGrid());
  S.editing.value = false;
  await window.__gw.settled(() => +getComputedStyle(document.querySelector(".home > .bar")).opacity >= 0.9);
  const fails = [];
  if (S.home.value.items.some((i) => i.kind === "panel" && i.name === "search")) fails.push("put back: the search widget is still on the grid");
  if (+getComputedStyle(document.querySelector(".home > .bar")).opacity < 0.9) fails.push("put back: no pill in the bar");
  return fails;
}

/**
 * In the page, edit mode (the user, 2026-10-22): a finger held on empty space then dragged draws the selection
 * rectangle and picks the two app tiles it touches; a quick sideways swipe there draws none (the page swipe's); out of
 * edit mode none either. Mock home only (synthetic pointers on the headless page).
 */
async function marqueeCheck() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await window.__gw.mod("./state.ts");
  const H = await window.__gw.mod("./ui/homeselect.ts");
  const G = await window.__gw.mod("./ui/grid.tsx");
  const { held } = await window.__gw.mod("./ui/gesture.ts");
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
  // [dwell]: the finger held that long first (homeselect.ts MARQUEE_DWELL, 180 ms: a timer - a late one fires late, so
  // in edit mode the hold waits until it armed, held, as a finger would); then rendered frames, never a time.
  const draw = async ([x0, y0], [x1, y1], dwell) => {
    fire("pointerdown", x0, y0);
    await sleep(dwell);
    if (dwell && S.editing.value) await window.__gw.until(() => held.value);
    for (let k = 1; k <= 6; k++) fire("pointermove", x0 + ((x1 - x0) * k) / 6, y0 + ((y1 - y0) * k) / 6);
    await window.__gw.frames(2);
    const drawn = !!document.querySelector(".pages .marquee");
    fire("pointerup", x1, y1);
    await window.__gw.frames(2);
    return drawn;
  };
  const end = [rb.right - 4, rb.top + rb.height / 2];
  if (await draw(start, end, 260)) fails.push("not editing: a drag on empty space drew a selection rectangle");
  S.editing.value = true;
  await window.__gw.settled(() => document.querySelector(".edit-sheet"));
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
  const S = await window.__gw.mod("./state.ts");
  const H = await window.__gw.mod("./ui/homeselect.ts");
  const G = await window.__gw.mod("./ui/grid.tsx");
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
  // The long press (grid.tsx LONG_PRESS_MS) lifted it.
  await window.__gw.until(() => document.querySelector(".carried"));
  const pages = document.querySelector(".pages");
  for (let k = 1; k <= 8; k++) fire(pages, "pointermove", x, y + (dy * G.geometry.value.cellH * k) / 8);
  await window.__gw.until(() => document.querySelectorAll(".carried").length >= party.length);
  const ghosts = document.querySelectorAll(".carried").length;
  fire(pages, "pointerup", x, y + dy * G.geometry.value.cellH);
  const wantedAll = () => items().every((i) => { const [x0, y0] = was.get(i.key).split(",").map(Number); return `${i.cell.x},${i.cell.y}` === (party.some((p) => p.key === i.key) ? `${x0},${y0 + dy}` : `${x0},${y0}`); });
  await window.__gw.until(() => wantedAll() && !document.querySelector(".carried, .pages .drop-spot"));
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
  await window.__gw.until(() => !H.chosen.value.includes(party[0].key));
  if (H.chosen.value.includes(party[0].key)) fails.push("edit mode: a tap on a picked tile didn't put it back");
  return fails;
}

/**
 * In the page, edit mode (the user, 2026-10-22): two apps tapped (picked), "group into folder" makes one folder in the
 * first one's place with both in it, opened at once; its name is edited and kept (store home.folders); closed, a tap on
 * the tile opens it again (out of edit mode).
 */
async function folderCreateCheck() {
  const S = await window.__gw.mod("./state.ts");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const tap = (el) => {
    const r = el.getBoundingClientRect();
    for (const type of ["pointerdown", "pointerup"]) el.dispatchEvent(new PointerEvent(type, { pointerId: 9, pointerType: "touch", clientX: r.left + 8, clientY: r.top + 8, bubbles: true, isPrimary: true }));
  };
  const n = S.pages.value[S.page.value];
  const [a, b] = S.home.value.items.filter((i) => i.page === n && i.kind === "app" && i.cell).sort((p, q) => p.cell.y - q.cell.y || p.cell.x - q.cell.x);
  if (!b) return ["folder: the mock's page has no two apps"];
  S.editing.value = true;
  await window.__gw.settled(() => document.querySelector(".edit-sheet"));
  for (const k of [a.key, b.key]) tap(document.querySelector(`.home-tile[data-key="${k}"]`));
  await window.__gw.until(() => document.querySelector(".chosen-actions .group-folder"));
  const button = document.querySelector(".chosen-actions .group-folder");
  if (!button) return ["folder: two apps picked show no \"group into folder\""];
  button.click();
  const made = () => S.home.value.items.find((i) => i.kind === "folder" && i.apps.some((x) => x.key === a.key));
  await window.__gw.until(() => made() && document.querySelector(".folder-view.open .folder-name") && document.querySelectorAll(`.home-tile[data-key="${made().key}"] .folder-face img, .home-tile[data-key="${made().key}"] .folder-face span`).length === 2);
  const f = S.home.value.items.find((i) => i.kind === "folder" && i.apps.some((x) => x.key === a.key));
  if (!f) return ["folder: \"group into folder\" made no folder of the two apps"];
  const fails = [];
  if (f.apps.length !== 2 || !f.apps.some((x) => x.key === b.key)) fails.push(`folder: holds [${f.apps.map((x) => x.key)}], not ${a.key} and ${b.key}`);
  if (`${f.cell.x},${f.cell.y}` !== `${a.cell.x},${a.cell.y}`) fails.push(`folder: at ${f.cell.x},${f.cell.y}, not where ${a.key} was (${a.cell.x},${a.cell.y})`);
  if (document.querySelectorAll(`.home-tile[data-key="${f.key}"] .folder-face img, .home-tile[data-key="${f.key}"] .folder-face span`).length !== 2) fails.push("folder: its tile doesn't show its two apps' icons");
  if (!document.querySelector(".folder-view.open .folder-name")) fails.push("folder: not opened after it was made (no popover with its name)");
  return fails;
}

/** In the page, after folderCreateCheck (the folder open): its name edited is kept; closed, a tap on it opens it again. */
async function folderNameCheck() {
  const S = await window.__gw.mod("./state.ts");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const tap = (el) => {
    const r = el.getBoundingClientRect();
    for (const type of ["pointerdown", "pointerup"]) el.dispatchEvent(new PointerEvent(type, { pointerId: 11, pointerType: "touch", clientX: r.left + 8, clientY: r.top + 8, bubbles: true, isPrimary: true }));
  };
  const f = S.home.value.items.find((i) => i.key === S.folder.value);
  const name = document.querySelector(".folder-view .folder-name");
  const fails = [];
  name.value = "Gate test";
  name.dispatchEvent(new Event("change", { bubbles: true }));
  await window.__gw.until(async () => (await powos.store.get("home.folders"))?.[f.key] === "Gate test");
  if ((await powos.store.get("home.folders"))?.[f.key] !== "Gate test") fails.push("folder: its name isn't kept (store home.folders)");
  S.folder.value = null;
  S.editing.value = false;
  // Closed (its morph shrank back and went) and out of edit mode, before the tap.
  await window.__gw.settled(() => !document.querySelector(".folder-view") && !document.querySelector(".edit-sheet"));
  tap(document.querySelector(`.home-tile[data-key="${f.key}"]`));
  await window.__gw.until(() => document.querySelector(".folder-view.open")?.dataset.key === f.key);
  if (document.querySelector(".folder-view.open")?.dataset.key !== f.key) fails.push("folder: a tap on its tile doesn't open it");
  else if (document.querySelector(".folder-view .folder-name")?.value !== "Gate test") fails.push("folder: opened again, its name is gone");
  return fails;
}

/**
 * In the page, after folderCreateCheck (the folder open, two apps): one app held and dragged out onto a free cell is on
 * home there, out of the folder; the folder, left with one app, goes away - that app in its place.
 */
async function folderDissolveCheck() {
  const S = await window.__gw.mod("./state.ts");
  const G = await window.__gw.mod("./ui/grid.tsx");
  const fire = (el, type, x, y) => el.dispatchEvent(new PointerEvent(type, { pointerId: 10, pointerType: "touch", clientX: x, clientY: y, bubbles: true, isPrimary: true }));
  const f = S.home.value.items.find((i) => i.key === S.folder.value);
  const el = document.querySelector(".folder-view.open .folder-grid .app");
  if (!f || !el) return ["folder: not open for the drag-out"];
  const out = f.apps.find((x) => x.key === el.dataset.key);
  const rest = f.apps.find((x) => x !== out);
  const g = G.geometry.value;
  const spot = G.placeNewCells(1, 1);
  if (spot.page !== S.pages.value[S.page.value]) return ["folder: no free cell on the page to drag an app out to"];
  const free = [spot.cell.x, spot.cell.y];
  const r = el.getBoundingClientRect();
  fire(el, "pointerdown", r.left + r.width / 2, r.top + r.height / 2);
  await window.__gw.until(() => document.querySelector(".carried"));
  const [tx, ty] = [g.left + g.pad + (free[0] + 0.5) * g.cellW, g.top + g.pad + (free[1] + 0.5) * g.cellH];
  const pages = document.querySelector(".pages");
  for (let k = 1; k <= 8; k++) fire(pages, "pointermove", r.left + ((tx - r.left) * k) / 8, r.top + ((ty - r.top) * k) / 8);
  await window.__gw.frames(2);
  fire(pages, "pointerup", tx, ty);
  const where = (key) => {
    const c = S.home.value.items.find((i) => i.key === key && i.kind === "app")?.cell;
    return c ? `${c.x},${c.y}` : "nowhere on home";
  };
  await window.__gw.until(() => where(out.key) === `${free[0]},${free[1]}` && !S.home.value.items.some((i) => i.key === f.key) && where(rest.key) === `${f.cell.x},${f.cell.y}`);
  const fails = [];
  if (where(out.key) !== `${free[0]},${free[1]}`) fails.push(`folder: ${out.key} dragged out to ${free} is at ${where(out.key)}`);
  if (S.home.value.items.some((i) => i.key === f.key)) fails.push("folder: left with one app, it's still there");
  if (where(rest.key) !== `${f.cell.x},${f.cell.y}`) fails.push(`folder: the app left (${rest.key}) is at ${where(rest.key)}, not the folder's place ${f.cell.x},${f.cell.y}`);
  return fails;
}

/**
 * In the page: floating windows on home's pages (ui/desktops.ts) - the host stubbed (the mock has no floating
 * windows), two pages. A window opens on the page on screen; swiping pages hides the other page's windows
 * (floating.desktop's list); a window brought back from the dock (windows.raised) moves to the page on screen; one let go
 * at a screen edge (windows.edge) moves to the next page with home.
 */
async function desktopsCheck() {
  const S = await window.__gw.mod("./state.ts");
  const D = await window.__gw.mod("./ui/desktops.ts");
  const { powos } = await window.__gw.mod("./bridge.ts");
  powos.floating = { list: async () => [], restore: async () => true, desktop: async (h) => ((window.__hid = h.join()), true) };
  if (S.pages.value.length < 2) await powos.home.addPanel("recents", Math.max(...S.pages.value) + 1, { x: 0, y: 0, w: 3, h: 3 });
  await window.__gw.until(() => D.ready() && S.pages.value.length >= 2);
  if (!D.ready()) return ["ui/desktops.ts never started (app.tsx startDesktops)"];
  const [p0, p1] = S.pages.value;
  const win = (id) => ({ id, pkg: `gate.app${id}`, label: `App ${id}`, minimised: false });
  const fails = [];
  // Until the host was told that hidden list (at most 3 s), and still so two frames on.
  const expect = async (what, hid) => {
    await window.__gw.until(() => (window.__hid ?? "") === hid);
    await window.__gw.frames(2);
    if ((window.__hid ?? "") !== hid) fails.push(`${what}: hidden [${window.__hid}], not [${hid}]`);
  };
  // The wide part (900 px: the wide home, often one page of tiles): an empty desktop always follows the last page, and
  // the app library is a desktop of its own (not page 1's). In here: page.evaluate sends this function alone.
  const desktopsWide = async () => {
    const last = S.pages.value[S.pages.value.length - 1];
    if (S.home.value.items.some((i) => i.page === last)) fails.push(`no empty desktop after the last page (pages ${S.pages.value})`);
    S.page.value = S.pages.value.length;
    S.windows.value = [win(103), win(102), win(101)];
    await expect("a window opened on the app library", "101,102");
    if (D.placed.value[103] !== -2) fails.push(`a window opened on the app library was put on page ${D.placed.value[103]}, not the library's (-2)`);
    S.windows.value = [win(102), win(101)];
  };
  // Its app opened on page 1 (windows.raised): the window comes to page 1, home stays there; then back on page 2.
  const raisedHere = async () => {
    window.__mockEvents.emit("windows.raised", 102);
    await window.__gw.until(() => D.placed.value[102] === p0);
    if (S.page.value !== 0) fails.push(`a window of page 2 brought back on page 1 took home to page ${S.page.value + 1}`);
    if (D.placed.value[102] !== p0) fails.push(`a window of page 2 brought back on page 1 stayed on page ${D.placed.value[102]}, not ${p0}`);
    await expect("brought back on page 1: shown there", "");
    D.moveTo(102, p1);
    await expect("102 back on page 2", "102");
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
  await desktopsWide();
  S.page.value = 0;
  await expect("back on page 1", "102");
  const kept = await powos.store.get("home.windows");
  if (kept?.[101] !== p0 || kept?.[102] !== p1) fails.push(`not stored per page: ${JSON.stringify(kept)}`);
  await raisedHere();
  return fails;
}

/** A coalesced final move must not turn a full swipe into a cancelled page switch. */
async function desktopReleaseCheck() {
  const S = await window.__gw.mod("./state.ts");
  const G = await window.__gw.mod("./ui/gesture.ts");
  const handlers = G.homeGestures();
  const target = document.querySelector(".page-track");
  const width = document.querySelector(".pages").clientWidth;
  const failures = [];
  S.windows.value = [];
  S.notif.value = false;
  S.drawer.value = 0;
  for (const kind of ["touch", "mouse"]) {
    S.page.value = 0;
    const point = (x) => ({ clientX: x, clientY: 200 });
    const start = point(width * 0.8), move = point(width * 0.7), end = point(width * 0.45);
    if (kind === "touch") {
      handlers.onTouchStart({ touches: [start], target });
      handlers.onTouchMove({ touches: [move], cancelable: false });
      await new Promise((resolve) => setTimeout(resolve, 300));
      handlers.onTouchEnd({ changedTouches: [end] });
    } else {
      handlers.onPointerDown({ ...start, pointerType: "mouse", target });
      handlers.onPointerMove({ ...move, pointerType: "mouse", buttons: 1 });
      await new Promise((resolve) => setTimeout(resolve, 300));
      handlers.onPointerUp({ ...end, pointerType: "mouse" });
    }
    if (S.page.value !== 1) failures.push(`${kind}: release crossed the page threshold but stayed on page ${S.page.value}`);
  }
  // The release rule (2026-10-28): [name, x moves as [dx, ms-after-start], dy at end, expected page from page 0].
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const logged = [];
  const info = console.info;
  console.info = (...a) => (logged.push(a.join(" ")), info(...a));
  const swipe = async (name, steps, dyEnd, want) => {
    logged.length = 0;
    S.page.value = 0;
    S.notif.value = false;
    S.drawer.value = 0;
    await sleep(350);
    const x0 = width * 0.8;
    handlers.onTouchStart({ touches: [{ clientX: x0, clientY: 300 }], target });
    let t = 0;
    for (const [dx, ms] of steps) {
      await sleep(ms - t);
      t = ms;
      handlers.onTouchMove({ touches: [{ clientX: x0 + dx, clientY: 300 + (dyEnd * dx) / steps[steps.length - 1][0] }], cancelable: false });
    }
    handlers.onTouchEnd({ changedTouches: [{ clientX: x0 + steps[steps.length - 1][0], clientY: 300 + dyEnd }] });
    if (S.page.value !== want) failures.push(`${name}: page ${S.page.value}, wanted ${want} (${logged.join(" | ")} w=${width} drag=${JSON.stringify(steps)} dyEnd=${dyEnd})`);
  };
  const d = width;
  await swipe("22% slow drag commits", [[-d * 0.08, 200], [-d * 0.16, 400], [-d * 0.22, 600], [-d * 0.22, 650]], 0, 1);
  await swipe("short fast flick commits", [[-12, 20], [-30, 40], [-60, 60]], 0, 1);
  await swipe("short slow drag cancels", [[-20, 200], [-40, 400], [-60, 600], [-60, 700]], 0, 0);
  await swipe("flick back cancels", [[-d * 0.4, 100], [-d * 0.4 + 10, 110], [-d * 0.4 + 30, 120], [-d * 0.4 + 60, 130]], 0, 0);
  await swipe("diagonal 20deg swipe pages", [[-d * 0.2, 100], [-d * 0.4, 200]], d * 0.4 * Math.tan((20 * Math.PI) / 180), 1);
  S.page.value = 0;
  return failures;
}

/** In the page, after desktopsCheck: a window let go at a screen edge (windows.edge) goes to the next page with home. */
async function desktopsEdge() {
  const S = await window.__gw.mod("./state.ts");
  const D = await window.__gw.mod("./ui/desktops.ts");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const [, p1] = S.pages.value;
  const fails = [];
  // Until the host was told that hidden list (at most 3 s), and still so two frames on.
  const expect = async (what, hid) => {
    await window.__gw.until(() => (window.__hid ?? "") === hid);
    await window.__gw.frames(2);
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
  // Unfolded, past the last page with tiles there is always the empty desktop: the drop takes the window there.
  window.__mockEvents.emit("windows.edge", { id: 101, side: 1 });
  await window.__gw.until(() => S.page.value === 2 && D.placed.value[101] === S.pages.value[2]);
  if (S.page.value !== 2 || D.placed.value[101] !== S.pages.value[2]) fails.push(`a drop at the right edge of page 2 left home on page ${S.page.value + 1}, the window on ${D.placed.value[101]} (pages ${S.pages.value})`);
  for (let i = 0; i < 3 && S.page.value > 0; i++) {
    const was = S.page.value;
    window.__mockEvents.emit("windows.edge", { id: 101, side: -1 });
    await window.__gw.until(() => S.page.value < was);
  }
  await expect("101 dropped on the left edge back to page 1", "102");
  return fails;
}

/**
 * In the page, after desktopsEdge: the dock's taps are a taskbar's (ui/desktops.ts dockTap; the user, 2026-10-22) - the
 * app of the window in front: minimised; minimised, away or under another window: brought back (the host's launch
 * restores it); no window: launched. And home tells the host where its bottom bar starts (windows.area), above which
 * windows open and maximise.
 */
async function dockTapCheck() {
  const S = await window.__gw.mod("./state.ts");
  const D = await window.__gw.mod("./ui/desktops.ts");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const fails = [];
  const did = [];
  let area = null;
  powos.floating.minimise = async (id) => (did.push(`min ${id}`), true);
  powos.floating.area = async (top) => ((area = top), true);
  const launchWas = powos.apps.launch;
  powos.apps.launch = async (key) => void did.push(`launch ${key}`);
  // As the host lists them: a window showing has its bounds (device px). One without bounds isn't showing (a
  // translucent task left in freeform) and is nobody's front (dockTap, e9e9e5aa).
  const win = (id, extra = {}) => ({ id, pkg: `gate.app${id}`, label: `App ${id}`, minimised: false, bounds: [0, 0, 400, 300], ...extra });
  const tap = async (key, want, what) => {
    did.length = 0;
    await D.dockTap(key);
    await window.__gw.until(() => did.join() === want);
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
    S.windows.value = [win(105, { bounds: undefined }), win(101)];
    await tap("a:gate.app101/.Main", "min 101", "its window in front, under a listed task that isn't showing");
    // A PowOS (Linux) app's window: its task is PowOS's own package, the host names the app (app: "l:...").
    S.windows.value = [win(104, { pkg: "com.powos.app", app: "l:org.kde.dolphin" })];
    await tap("l:org.kde.dolphin", "min 104", "a Linux app's window in front");
    S.windows.value = [win(104, { pkg: "com.powos.app", app: "l:org.kde.dolphin", minimised: true })];
    await tap("l:org.kde.dolphin", "launch l:org.kde.dolphin", "a Linux app's window minimised");
    // The dock's own cells tap through dockTap: a pinned app's cell, its window in front, minimises it.
    const cell = document.querySelector('.dock .app[data-key^="a:"]');
    if (!cell) fails.push("no Android app in the dock to tap");
    else {
      const key = cell.dataset.key;
      S.windows.value = [{ id: 201, pkg: key.slice(2).split("/")[0], label: "Docked", minimised: false, bounds: [0, 0, 400, 300] }];
      await window.__gw.frames(2);
      did.length = 0;
      const r = cell.getBoundingClientRect();
      const at = { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, bubbles: true, pointerId: 7, button: 0 };
      cell.dispatchEvent(new PointerEvent("pointerdown", at));
      cell.dispatchEvent(new PointerEvent("pointerup", at));
      await window.__gw.until(() => did.join() === "min 201");
      if (did.join() !== "min 201") fails.push(`a tap on the dock's ${key}, its window in front: [${did.join()}], not [min 201]`);
    }
    dispatchEvent(new Event("resize"));
    const barNow = () => Math.min(...[...document.querySelectorAll(".home > .bar, .home.dock-bottom > .dock")].map((e) => e.getBoundingClientRect()).filter((r) => r.height > 0).map((r) => r.top));
    await window.__gw.until(() => area !== null && Math.abs(area - barNow()) <= 1);
    const bar = Math.min(...[...document.querySelectorAll(".home > .bar, .home.dock-bottom > .dock")].map((e) => e.getBoundingClientRect()).filter((r) => r.height > 0).map((r) => r.top));
    if (area !== null && Math.abs(area - bar) > 1) fails.push(`windows.area told ${area}, the bottom bar starts at ${Math.round(bar)}`);
    if (area === null && D.barTop() === null) fails.push("home found no bottom bar to keep windows above (windows.area never told)");
    if (D.barTop() !== null && (D.barTop() < innerHeight / 2 || D.barTop() > innerHeight)) fails.push(`the bottom bar's top ${D.barTop()} isn't in the lower half of ${innerHeight}`);
  } finally {
    powos.apps.launch = launchWas;
    S.windows.value = [];
  }
  return fails;
}

/**
 * In the page, after dockTapCheck: a RUNNING app's long-press menu (apps.tsx AppMenu) starts with its window actions -
 * close first (desktops.ts closeApp: its tasks removed; a Steam game/Steam through the host's clean "apps.close"),
 * then minimise or restore its top-most window, then with 2+ windows each of them (a tap: restored to the front).
 * Not running: none of them.
 */
async function appMenuCheck() {
  const S = await window.__gw.mod("./state.ts");
  const R = await window.__gw.mod("./ui/running.ts");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const fails = [];
  const did = [];
  const was = { min: powos.floating.minimise, restore: powos.floating.restore, remove: powos.tasks.remove, list: powos.tasks.list, close: powos.apps.close, running: R.running.value };
  powos.floating.minimise = async (id) => (did.push(`min ${id}`), true);
  powos.floating.restore = async (id) => (did.push(`restore ${id}`), true);
  powos.tasks.remove = async (id) => (did.push(`remove ${id}`), true);
  let tasks = [];
  powos.tasks.list = async () => tasks;
  powos.apps.close = async (key) => (did.push(`close ${key}`), key === "l:gate.game");
  const win = (id, extra = {}) => ({ id, pkg: "gate.menu", label: "Menu App", minimised: false, bounds: [0, 0, 400, 300], ...extra });
  const items = () => [...document.querySelectorAll(".menu .menu-item")].map((b) => b.textContent);
  const at = new DOMRect(100, 200, 60, 60);
  const check = async (key, { windows, run, want, what, tap, wantDid }) => {
    S.menu.value = null;
    S.windows.value = windows;
    R.running.value = run ? { [key]: "running" } : {};
    await window.__gw.frames(1);
    S.menu.value = { app: { key, label: "Menu App", icon: "", kind: key.startsWith("l:") ? "linux" : "android" }, at };
    await window.__gw.until(() => items().length > 0);
    const got = items().slice(0, want.length);
    if (got.join("|") !== want.join("|")) fails.push(`${what}: the menu starts [${items().join(", ")}], not [${want.join(", ")}]`);
    if (!tap) return;
    did.length = 0;
    const b = [...document.querySelectorAll(".menu .menu-item")].find((x) => x.textContent === tap);
    if (!b) return void fails.push(`${what}: no "${tap}" in the menu`);
    b.click();
    await window.__gw.until(() => did.join() === wantDid);
    if (did.join() !== wantDid) fails.push(`${what}: "${tap}" did [${did.join()}], not [${wantDid}]`);
    if (S.menu.value) fails.push(`${what}: the menu stayed open after "${tap}"`);
  };
  try {
    const A = "a:gate.menu/.Main";
    await check(A, { windows: [], run: false, want: ["pin to dock"], what: "not running" });
    tasks = [{ id: 301, key: A }, { id: 302, key: "a:other/.Main" }];
    await check(A, { windows: [], run: true, want: ["close", "pin to dock"], what: "running full screen (folded)", tap: "close", wantDid: "remove 301" });
    tasks = [];
    await check(A, { windows: [win(101)], run: true, want: ["close", "minimise", "pin to dock"], what: "one window showing", tap: "minimise", wantDid: "min 101" });
    await check(A, { windows: [win(101)], run: true, want: ["close"], what: "one window, close", tap: "close", wantDid: "remove 101" });
    await check(A, { windows: [win(101, { minimised: true })], run: true, want: ["close", "restore", "pin to dock"], what: "one window minimised", tap: "restore", wantDid: "restore 101" });
    await check(A, { windows: [win(101), win(102, { label: "Other" }), win(103, { pkg: "gate.else" })], run: true, want: ["close", "minimise", "Menu App", "Other", "pin to dock"], what: "two windows", tap: "Other", wantDid: "restore 102" });
    await check("l:gate.game", { windows: [win(104, { pkg: "com.powos.app", app: "l:gate.game" })], run: true, want: ["close", "minimise"], what: "a Steam game's window", tap: "close", wantDid: "close l:gate.game" });
    await check("l:gate.tool", { windows: [win(105, { pkg: "com.powos.app", app: "l:gate.tool" })], run: true, want: ["close"], what: "a Linux app's window", tap: "close", wantDid: "close l:gate.tool,remove 105" });
  } finally {
    S.menu.value = null;
    S.windows.value = [];
    R.running.value = was.running;
    Object.assign(powos.floating, { minimise: was.min, restore: was.restore });
    Object.assign(powos.tasks, { remove: was.remove, list: was.list });
    powos.apps.close = was.close;
  }
  return fails;
}

/**
 * In the page: a touch inside a floating window is the app's (ui/gesture.ts startGesture, desktops.ts inWindow) - a
 * swipe up there never opens the launcher, down never the shade; the same swipe outside every window still does.
 */
async function windowTouchCheck() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await window.__gw.mod("./state.ts");
  const home = document.querySelector(".home");
  const fails = [];
  const dpr = devicePixelRatio;
  const box = [100, 100, Math.round(innerWidth * 0.6), Math.round(innerHeight * 0.6)];
  S.windows.value = [{ id: 301, pkg: "gate.win", label: "Win", minimised: false, bounds: box.map((v) => Math.round(v * dpr)) }];
  const swipe = async (x, y0, y1) => {
    const t = (y) => [new Touch({ identifier: 9, target: home, clientX: x, clientY: y })];
    home.dispatchEvent(new TouchEvent("touchstart", { touches: t(y0), changedTouches: t(y0), bubbles: true, cancelable: true }));
    for (let i = 1; i <= 8; i++) {
      const y = y0 + ((y1 - y0) * i) / 8;
      home.dispatchEvent(new TouchEvent("touchmove", { touches: t(y), changedTouches: t(y), bubbles: true, cancelable: true }));
      await sleep(16);
    }
    home.dispatchEvent(new TouchEvent("touchend", { touches: [], changedTouches: t(y1), bubbles: true, cancelable: true }));
    // The swipe handled and whatever it started at rest (a drawer or shade that opened would show by then).
    await window.__gw.settled();
  };
  try {
    await swipe(box[0] + 100, box[1] + 300, box[1] + 20);
    if (S.drawer.value > 0) fails.push(`a swipe up inside a floating window opened the launcher (${S.drawer.value})`);
    await swipe(box[0] + 100, box[1] + 40, box[1] + 320);
    if (S.notif.value) fails.push("a swipe down inside a floating window pulled the shade down");
    S.notif.value = false;
    S.closeDrawer?.();
  } finally {
    S.windows.value = [];
  }
  return fails;
}

/**
 * In the page: a web window (ui/webwindows.tsx; Android app content under home's pixels) - its title bar drags only the
 * window, a sideways swipe on it or its body never turns home's page (the user, 2026-10-30: "when i try to move the
 * window it moves the whole page"), it is in the claim-free regions, and its page is masked over its body (the widgets
 * under it never paint over the app) with a higher window's title bar kept.
 */
async function webWindowCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  // One finger from [a] to [b] (client px), as the phone sends it: pointer events (the title bar's drag) AND touch
  // events (home's swipes, gesture.ts homeGestures - a control's pointer stopPropagation doesn't stop those). The gate's
  // Chromium has no touch input, so Preact bound home's onTouchStart under its own name ("TouchStart", not a DOM
  // event there): each touch event goes out under both names, whichever is bound.
  const drag = async (el, a, b) => {
    const send = (kind, k) => {
      const [x, y] = [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k];
      el.dispatchEvent(new PointerEvent(`pointer${kind}`, { pointerId: 11, pointerType: "touch", isPrimary: true, clientX: x, clientY: y, bubbles: true }));
      const t = [new Touch({ identifier: 11, target: el, clientX: x, clientY: y })];
      const name = { down: "Start", move: "Move", up: "End" }[kind];
      const init = { touches: kind === "up" ? [] : t, changedTouches: t, bubbles: true, cancelable: true };
      for (const type of [`touch${name.toLowerCase()}`, `Touch${name}`]) el.dispatchEvent(new TouchEvent(type, init));
    };
    send("down", 0);
    for (let i = 1; i <= 10; i++) (send("move", i / 10), await sleep(16));
    send("up", 1);
    await window.__gw.settled();
  };
  const turned = (what) => (S.page.value === 0 ? [] : [`${what} turned the page (0 -> ${S.page.value})`]);
  const was = S.page.value;
  const fails = [];
  try {
    // The first home page, with a page after it (desktopsCheck added one): a swipe there could turn it.
    S.page.value = 0;
    await window.__gw.settled();
    W.webWins.value = [{ id: 901, key: "a:gate.ww", label: "Gate", page: S.pages.value[0], x: 400, y: 120, w: 360, h: 300 }];
    await new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(ok)));
    const el = document.querySelector('.webwindow[data-wwid="901"]');
    if (!el) return ["web window: no .webwindow element on the page on screen"];
    const r = el.querySelector(".webwindow-title").getBoundingClientRect();
    await drag(el.querySelector(".webwindow-title"), [r.left + 60, r.top + 18], [r.left - 240, r.top + 18]);
    fails.push(...turned("dragging a web window's title bar"));
    const x = W.webWins.value.find((w) => w.id === 901)?.x;
    if (x !== 100) fails.push(`dragging the title bar 300 px left moved the window to x=${x} (want 100)`);
    const b = el.querySelector(".webwindow-body").getBoundingClientRect();
    await drag(el.querySelector(".webwindow-body"), [b.left + 320, b.top + 80], [b.left + 20, b.top + 80]);
    fails.push(...turned("a sideways swipe on a web window's body"));
    // The control: the same swipe there with no window does turn the page (else this check proves nothing).
    W.webWins.value = [];
    await window.__gw.settled();
    const under = document.elementFromPoint(b.left + 320, b.top + 80) ?? document.querySelector(".page");
    await drag(under, [b.left + 320, b.top + 80], [b.left + 20, b.top + 80]);
    if (S.page.value === 0) fails.push(`the control swipe (no window there, on .${under.className}) didn't turn the page either`);
  } finally {
    W.webWins.value = [];
    S.page.value = was;
  }
  return fails;
}

/**
 * In the page: two overlapping web windows - their page masked over the bodies (subtract) from three images: both
 * bodies and the top window's title bar cut back in (it is DOM over the lower app). ui/webwindows.tsx pageMask.
 */
async function webWindowMaskCheck() {
  // The user, 2026-10-30: "nobody asked for the cutoff" - a web window is a card over home (the host draws it above
  // home's surface); the page under it is never masked or cut, and the window's element is invisible (its model).
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const page = S.pages.value[S.page.value] ?? 1;
  // The page under a window isn't cut, the window's element paints nothing, a minimised one has none.
  const uncut = (el, pageEl) => {
    const fails = [];
    const mask = getComputedStyle(pageEl).maskImage || "none";
    if (mask !== "none" || pageEl.style.mask) fails.push(`web windows: their page is masked ("${mask}") - nothing under a window may be cut`);
    const paints = (c) => c.backgroundColor !== "rgba(0, 0, 0, 0)" || c.boxShadow !== "none";
    if ([el, ...el.querySelectorAll("*")].some((e) => paints(getComputedStyle(e)))) fails.push("web window: its element paints (the host draws the window; the page's element must be invisible)");
    if (document.querySelector('.webwindow[data-wwid="904"]')) fails.push("a minimised web window still has its element on the page");
    return fails;
  };
  // Full screen fills the work area (above the dock), and restores the frame it had.
  const near = (a, b) => Math.abs(a - b) <= 1;
  const fills = (m, a) => !!m?.restore && near(m.w, a.right - a.left) && near(m.h, a.bottom - a.top);
  const maximise = () => {
    const fails = [];
    W.toggleMaximise(903);
    const a = W.workArea();
    const m = W.webWins.value.find((w) => w.id === 903);
    if (!fills(m, a)) fails.push(`full screen: ${JSON.stringify(m)} doesn't fill the work area ${JSON.stringify(a)}`);
    W.toggleMaximise(903);
    const r = W.webWins.value.find((w) => w.id === 903);
    if (r?.restore || r?.w !== 360 || r?.h !== 300) fails.push(`restore: ${JSON.stringify(r)} isn't back at 360x300`);
    return fails;
  };
  try {
    W.webWins.value = [
      { id: 903, key: "a:gate.ww", label: "Gate", page, x: 400, y: 120, w: 360, h: 300 },
      { id: 904, key: "a:gate.ww2", label: "Gate 2", page, x: 160, y: 200, w: 300, h: 240, minimised: true },
    ];
    await new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(ok)));
    const el = document.querySelector('.webwindow[data-wwid="903"]');
    const pageEl = el?.closest(".page");
    if (!pageEl) return ["web windows: not on the page on screen"];
    return [...uncut(el, pageEl), ...maximise()];
  } finally {
    W.webWins.value = [];
  }
}

/** In the page, loaded afresh after desktopsCheck: the stored windows go back on their pages (page 2's hidden). */
async function desktopsReloaded() {
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const S = await window.__gw.mod("./state.ts");
  const D = await window.__gw.mod("./ui/desktops.ts");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const t0 = performance.now();
  while (!D.ready() && performance.now() - t0 < 5000) await sleep(50);
  // The mock's layout isn't kept across a reload (the phone's is): page 2 again, as desktopsCheck made it.
  const kept = await powos.store.get("home.windows");
  if (S.pages.value.length < 2) await powos.home.addPanel("recents", kept?.[102] ?? 2, { x: 0, y: 0, w: 3, h: 3 });
  await window.__gw.until(() => S.pages.value.length >= 2);
  powos.floating = { list: async () => [], restore: async () => true, desktop: async (h) => ((window.__hid = h.join()), true) };
  S.page.value = 0;
  S.windows.value = [101, 102].map((id) => ({ id, pkg: `gate.app${id}`, label: `App ${id}`, minimised: false }));
  await window.__gw.until(() => window.__hid === "102");
  return window.__hid === "102" ? [] : [`after a reload on page 1, hidden [${window.__hid}], not page 2's [102] (placement not kept: pages ${S.pages.value}, ${JSON.stringify(D.placed.value)})`];
}

// Boot slots: at most GATE_BOOTS pages booting at once (default from the Mac's free CPU: 3..12). ~30 pages booting
// together on a Mac at load ~20 (training runs + builds) timed every page out at READY_MS though the shell loads
// (friction f30, 2026-10-23). A page's ready clock starts when it gets its slot; the slot frees when it's ready or
// failed (or READY_MS passed), so the checks after boot still run side by side.
const os = await import("node:os");
const BOOTS = Number(process.env.GATE_BOOTS) || Math.max(3, Math.min(12, Math.round(os.cpus().length - os.loadavg()[0] + 4)));
let booting = 0;
const bootQueue = [];
const bootSlot = () => new Promise((ok) => (booting < BOOTS ? (booting++, ok()) : bootQueue.push(ok)));
const bootDone = () => (bootQueue.length ? bootQueue.shift()() : booting--);

async function open(browser, url, name, viewport = { width: 412, height: 915 }) {
  if (ONLY && !ONLY.test(name)) throw SKIP;
  // A context (a window) of its own: tabs side by side in one window are hidden but the front one - no frames.
  const context = await step(`${name}: createBrowserContext`, browser.createBrowserContext());
  const page = await step(`${name}: newPage`, context.newPage());
  // puppeteer's own 30 s defaults (goto, waitFor*) are fixed too: scale them with the load like READY_MS (f30).
  page.setDefaultTimeout(PUPPETEER_MS);
  page.setDefaultNavigationTimeout(PUPPETEER_MS);
  await step(`${name}: setViewport`, page.setViewport({ ...viewport, deviceScaleFactor: 1 }));
  if (THROTTLE > 1) await step(`${name}: throttle`, page.target().createCDPSession().then((c) => c.send("Emulation.setCPUThrottlingRate", { rate: THROTTLE })));
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
  // The page's last console lines + pageerrors + failed requests, printed under a "not ready" FAIL (the missing evidence
  // when nothing booted: a JS error before __powosAlive, or just slow).
  const tail = [];
  const note = (t) => (tail.push(t.slice(0, 300)), tail.length > 12 && tail.shift());
  page.on("pageerror", (e) => note(`pageerror: ${String(e.stack ?? e.message).split("\n").slice(0, 4).join(" | ")}`));
  page.on("requestfailed", (q) => note(`requestfailed: ${q.url().slice(-80)} ${q.failure()?.errorText ?? ""}`));
  page.on("console", (m) => {
    note(`console.${m.type()}: ${m.text()}`);
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
  // The checks' waits (window.__gw), on every page before its scripts. A check waits on the STATE its assertion needs,
  // never a fixed time: on a loaded Mac (two gates at --cpu-shares 256) frames lag the clock - a slide hadn't begun
  // 500 ms in, a transition started a frame late ended late. until(f, ms = checkMs): until f() (may be async) holds
  // or ms pass - true if it held; the assertion after it is the one that fails. checkMs is READY_MS (gate.sh's
  // load-scaled boot budget), not a fixed 3000 - at 1-min load 25 a fixed 3000 ms failed checks like
  // dockTapCheck's tap() though the app was fine, the same cause READY_MS was already scaled for (f30).
  // steady(f): f()'s measure unchanged over
  // frames (script-driven motion included). still(sel): no finite animation or transition running on the document's
  // clock (under sel's elements); endless ones (a loading pulse) don't count - the idle check has those.
  await page.evaluateOnNewDocument((checkMs) => {
    const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
    // A frame, or 500 ms without one: a wait only on rAF is a promise nothing but the frame holds - on a loaded gate
    // the evaluate awaiting it failed "Promise was collected" (relayout-*); the timer keeps it reachable and bounded.
    const frame = () => new Promise((ok) => (requestAnimationFrame(() => ok()), setTimeout(ok, 500)));
    const frames = async (n = 2) => { for (let k = 0; k < n; k++) await frame(); };
    // Default ms: checkMs (READY_MS, load-scaled by gate.sh - f30) instead of a fixed 3000. At 1-min load 25
    // (agent-swarm load, same cause as the boot wait) frames lagged the clock past 3 s though the app was fine -
    // dockTapCheck's tap() (desktops.ts) and others never reached their state within the fixed budget and the
    // gate FAILed "its window in front" though nothing was wrong with the code. READY_MS already scales for this
    // (gate.sh: load*1500, floor 8000, cap 60000); reusing it here covers these in-page waits the same way.
    const until = async (f, ms = checkMs) => {
      const t0 = performance.now();
      while (!(await f())) {
        if (performance.now() - t0 > ms) return false;
        await sleep(16);
      }
      return true;
    };
    // The shared "what's actually animating" helper (friction f125): a scroll-driven effect (animation-timeline:
    // scroll()/view(), the dock's edge fade) is "running" for as long as it exists - document.timeline is the only
    // one real motion plays on, so every still/idle/at-rest check in the gate filters on it HERE, once, instead of
    // each reimplementing (and some forgetting) the same filter - that's how a scroll-driven effect made a "nothing
    // is animating" wait never finish, or an at-rest check false-fail, at the other call sites before this.
    const documentAnimations = (sel) =>
      document.getAnimations().filter((a) => a.playState === "running" && a.timeline === document.timeline && (!sel || a.effect?.target?.closest?.(sel)));
    // still: a FINITE one under sel actually running; endless ones (a loading pulse) don't count - the idle check
    // has those.
    const still = (sel) => !documentAnimations(sel).some((a) => a.effect?.getComputedTiming().endTime !== Infinity);
    // Settled: f() holds, then no animation (under sel) and two frames on - the layout after the last one done.
    const settled = async (f = () => true, sel, ms = checkMs) => (await until(async () => (await f()) && still(sel), ms)) && (await frames(2), true);
    // Steady: f()'s value (a JSON-able measure: rects, an order) the same over n frames running - motion a script drives
    // (a spring, a rAF tween) that getAnimations() never sees has stopped. True if it got there within ms.
    const steady = async (f, n = 3, ms = checkMs) => {
      const t0 = performance.now();
      let last = JSON.stringify(await f()), same = 0;
      while (same < n) {
        if (performance.now() - t0 > ms) return false;
        await frames(1);
        const now = JSON.stringify(await f());
        same = now === last ? same + 1 : 0;
        last = now;
      }
      return true;
    };
    // A shell module, imported once per page and kept: each check imported state.ts & co. again (importShim), and on a
    // loaded gate such an evaluate failed "Promise was collected" (columnsAs, edit-search) - one import, then the cache.
    const mods = new Map();
    const mod = (path) => {
      if (!mods.has(path)) mods.set(path, window.importShim(path).catch((e) => (mods.delete(path), Promise.reject(e))));
      return mods.get(path);
    };
    window.__gw = { sleep, frames, until, still, settled, steady, mod, documentAnimations };
  }, READY_MS);
  // Counts the page's requestAnimationFrame callbacks (the idle check): counted as they run, nothing else changes.
  await page.evaluateOnNewDocument(() => {
    const raf = window.requestAnimationFrame.bind(window);
    window.__gateRaf = 0;
    window.requestAnimationFrame = (cb) => raf((t) => (window.__gateRaf++, cb(t)));
  });
  await bootSlot();
  const started = Date.now();
  await page.goto(url, { waitUntil: "domcontentloaded" }).catch((e) => problems.push(`navigation: ${e.message}`));
  page.waitForFunction(() => window.__powosAlive === true || window.__powosBoot?.failed === true, { timeout: READY_MS, polling: 100 })
    .catch(() => {}).finally(bootDone);
  return { page, name, problems, warnings, uncaught, started, tail };
}

/** A "not ready" FAIL's evidence: what the page said before it gave up. */
function printTail(r) {
  if (!r.problems.some((p) => p.startsWith("not ready"))) return;
  for (const t of r.tail ?? []) console.log(`     ${r.name} page: ${t}`);
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
      // Running and endless (an iteration count of Infinity): a finite one ends by itself. documentAnimations
      // already excludes a scroll-driven one (friction f125: it also reports endTime Infinity, "running" for as
      // long as it exists - without the timeline filter it false-failed every idle check on a page with one, e.g.
      // the dock's edge fade).
      anims: window.__gw.documentAnimations()
        .filter((a) => a.effect?.getComputedTiming().endTime === Infinity)
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
  // Load-scaled like the page waits (f30): puppeteer's own launch wait is a fixed 30 s ("Timed out ... waiting for the
  // WS endpoint URL") and chromium took ~12 s to start at load 13, so a starved Mac failed the gate before any page.
  timeout: PUPPETEER_MS,
  protocolTimeout: Math.max(180000, PUPPETEER_MS * 2),
  // Every page drawn as if on screen (the pages run side by side): a backgrounded or occluded one gets no frames, and
  // the idle check would see nothing.
  args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--no-first-run", "--mute-audio",
    "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows", "--disable-background-timer-throttling"],
});
// HACK: newPage() waits for its target with browser.waitForTarget's fixed 30 s default (puppeteer 22.9 api/Browser.js)
// and takes no timeout option - at load ~15 that wait is what died before any case (f30). Default it to PUPPETEER_MS
// here; real fix: upstream a timeout option on newPage / createBrowserContext.
const waitForTarget = browser.waitForTarget.bind(browser);
browser.waitForTarget = (predicate, options = {}) => waitForTarget(predicate, { timeout: PUPPETEER_MS, ...options });
let failed = 0;
try {
  const runs = [];
  // A run not in GATE_ONLY: open() throws SKIP before it makes a page; it reports nothing.
  runs.push = (...ps) => Array.prototype.push.apply(runs, ps.map((p) => p.catch((e) => (e === SKIP ? null : Promise.reject(e)))));
  if (process.env.SHELL_PAGES !== "0") {
    for (const mode of modes()) {
      const url = `${ORIGIN}/index.html${mode === "home" ? "" : `?mode=${mode}`}`;
      // Ready, or failed: the boot guard (index.html) saw an error before ready - no use waiting out READY_MS.
      runs.push(open(browser, url, mode).then((r) => settle(r, () => window.__powosAlive === true || window.__powosBoot?.failed === true)));
    }
  }
  // The phone's launcher is the overlay's page (index.html?mode=pull, pull.tsx): home has none of its own.
  for (const [mode, width, height] of [["pull", 404, 900], ["desktop", 1280, 800]]) {
    runs.push(open(browser, `${ORIGIN}/index.html?mode=${mode}`, `launcher-search-${mode}`, {width, height}).then(r => whenReady(r, async () => {
      const failures = await r.page.evaluate(async () => {
        const check = await importShim('./dev/search-check.js');
        return check.launcherSearchCheck();
      });
      await r.page.evaluate(async () => { const s = await importShim('./state.ts'); s.drawer.value = 1; s.query.value = 'dock position'; });
      await r.page.waitForSelector('[data-search-result^="settings:style:"]');
      await r.page.screenshot({path: `/cache/launcher-search-${mode}.png`});
      await r.page.evaluate(async () => { const s = await importShim('./state.ts'); s.query.value = s.apps.value.find(a => a.icon).label; });
      await r.page.waitForFunction(() => [...document.querySelectorAll('[data-search-result^="app:"] .app-icon img')].some(i => i.complete && i.naturalWidth > 0));
      await r.page.screenshot({path: `/cache/launcher-search-icons-${mode}.png`});
      return failures;
    })));

  }
  // The launcher's chat while typing (the user, 2026-10-28: "launcher chat refreshes every keypress"): no search, no
  // re-render of the chat or its messages, the scroll where it was (dev/search-check.js launcherChatTypingCheck).
  // In the launcher: the overlay's page (index.html?mode=pull).
  runs.push(open(browser, `${ORIGIN}/index.html?mode=pull`, "launcher-chat-typing", {width: 404, height: 900}).then(r => whenReady(r, async () => {
    const [failures, counts] = await r.page.evaluate(async () => (await importShim('./dev/search-check.js')).launcherChatTypingCheck());
    console.log(`launcher-chat-typing: ${JSON.stringify(counts)}`);
    return failures;
  })));
  const dockRun = (name, query, part, position = name.split("-")[3]) => open(browser, `${ORIGIN}/index.html${query}`, name, dockViews[name.split("-")[2]]).then(r => whenReady(r, async () => {
    const failures = await r.page.evaluate(dockPositionCheck, position, part);
    if (process.env.DOCK_SHOTS) await r.page.screenshot({path: `${process.env.DOCK_SHOTS}/${name}.png`});
    return failures;
  }));
  const dockViews = { cover: { width: 404, height: 900 }, inner: { width: 821, height: 883 }, desktop: { width: 1280, height: 800 } };
  for (const [label, mode, width, height] of [["cover", "home", 404, 900], ["inner", "home", 821, 883], ["desktop", "desktop", 1280, 800]]) {
    for (const position of ["bottom", "left", "right"]) {
      // Home has no launcher of its own (the overlay's page is the launcher): home's dock on home, the launcher's beside
      // it in the overlay's page (index.html?mode=pull).
      const parts = mode === "home" ? [["home", "", ""], ["launcher", "?mode=pull", "-launcher"]] : [["all", `?mode=${mode}`, ""]];
      runs.push(...parts.map(([part, query, suffix]) => dockRun(`dock-position-${label}-${position}${suffix}`, query, part)));
    }
  }
  for (const [mode, width, height] of [["windowbar", 280, 27], ["statusbar", 404, 46]])
    runs.push(open(browser, `${ORIGIN}/index.html?mode=${mode}`, `chrome-${mode}`, { width, height }).then((r) => whenReady(r, () => r.page.evaluate(mode === "windowbar" ? windowChromeCheck : statusChromeCheck))));
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
            const { powos } = await window.__gw.mod("./bridge.ts");
            const cells = [{ x: 0, y: 3, w: 6, h: 1 }, { x: 0, y: 5, w: 6, h: 2 }, { x: 0, y: 1, w: 2, h: 1 }];
            for (const c of cells) await Promise.race([powos.home.addPanel("search", 0, c), sleep(800)]).catch(() => {});
            // The widgets mounted and measured (the field sizes itself over frames), at rest.
            await window.__gw.settled(() => document.querySelectorAll(".search-face .pill").length >= cells.length);
            await window.__gw.steady(() => [...document.querySelectorAll(".pill")].map((p) => p.clientHeight));
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
            const S = await window.__gw.mod("./state.ts");
            for (const p of document.querySelectorAll(".pill")) p.style.width = "1px";
            await frames();
            S.query.value = "x";
            await frames();
            S.query.value = "";
            await frames();
            for (const p of document.querySelectorAll(".pill")) p.style.width = "";
            await frames();
            await window.__gw.steady(() => [...document.querySelectorAll(".pill")].map((p) => p.clientHeight));
            return [...fails, ...check(" after it was measured narrow and widened again")];
          })
          .catch((e) => [`evaluate: ${e.message.split("\n")[0]}`]);
        r.problems.push(...out);
        return { ...r, ready: true, ms: Date.now() - r.started };
      }),
    );
  }
  // Merged tiles in a straight stack (grid.tsx groupSpans/joins; the user's steam-over-fetch, 2026-10-28): a wide widget
  // over a half-width one shows as ONE rectangle - one width, outer edges on the grid lines, the shared side a seam, no
  // inner corner. Folded and unfolded.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 412, height: 915 }], ["unfolded", { width: 900, height: 1000 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `joins-${label}`, viewport).then((r) => whenReady(r, () => r.page.evaluate(joinsCheck))));
  // Floating windows live on home's pages (ui/desktops.ts; the user's design, 2026-10-22): page switch hides and
  // shows them, and the placement survives the page loading afresh.
  if (process.env.SHELL_PAGES !== "0")
    runs.push(
      open(browser, `${ORIGIN}/index.html`, "desktops", { width: 900, height: 1000 }).then(async (r) => {
        // The six steps are ONE check through whenReady's checkOnce: on a loaded gate an evaluate here was lost
        // ("Promise was collected", 2026-10-29 - also the ship service's post-ship gate) and only the first step went
        // through checkOnce; the others reported the lost evaluate as the scene's FAIL. Each step builds on the one
        // before (windows placed, pages added), so a lost one reruns the whole chain on a page loaded afresh - with the
        // first try's stored placement (localStorage "home.windows") cleared, or the rerun tests its leftovers.
        let tries = 0;
        const s = await whenReady(r, async () => {
          if (tries++) {
            await r.page.evaluate(() => localStorage.clear());
            await r.page.reload().catch(() => {});
            await r.page.waitForFunction(() => window.__powosAlive === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
          }
          for (const step of [desktopReleaseCheck, desktopsCheck, desktopsEdge, dockTapCheck, appMenuCheck, windowTouchCheck, webWindowCheck, webWindowMaskCheck]) {
            const problems = await r.page.evaluate(step);
            if (problems.length) return problems;
          }
          return [];
        });
        if (s.problems.length) return s;
        await r.page.reload().catch(() => {});
        return whenReady(r, () => r.page.evaluate(desktopsReloaded));
      }),
    );
  // Edit mode: the search bar a tile on the grid, the dock in view (the user, 2026-10-22). Folded and unfolded.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `edit-search-${label}`, viewport).then((r) => whenReady(r, async () => [...(await r.page.evaluate(editSearchCheck)), ...(await r.page.evaluate(editSearchMoved))])));
  // Edit mode's "+ app" (the user, 2026-10-23): the drawer's list and search, a pick at the first free cell of the page
  // in view, kept after a reload (the mock keeps its layout in localStorage once "mock.keepHome" is set). Both screens.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `add-app-${label}`, viewport).then(async (r) => {
        await whenReady(r, () => r.page.evaluate(() => (localStorage.setItem("powos-shell:mock.keepHome", "1"), [])));
        await r.page.reload().catch(() => {});
        const s = await whenReady(r, () => r.page.evaluate(addAppHelpers).then(() => r.page.evaluate(addAppCheck)));
        if (s.problems.length) return s;
        await r.page.reload().catch(() => {});
        return whenReady(r, () => r.page.evaluate(addAppReloaded));
      }));
  // App and widget creation, live (the user, 2026-10-24): the drawer/home placeholder at the start, progress on mock
  // step events, the being-built view, and the in-place swap with no gap or overlap.
  if (process.env.SHELL_PAGES !== "0")
    // The app's placeholder is the launcher's (the overlay's page, index.html?mode=pull); the widget's is home's.
    runs.push(
      open(browser, `${ORIGIN}/index.html?mode=pull`, "pending-creation-launcher", { width: 404, height: 900 }).then((r) => whenReady(r, () => r.page.evaluate(pendingAppCheck))),
      open(browser, `${ORIGIN}/index.html`, "pending-creation", { width: 404, height: 900 }).then((r) => whenReady(r, () => r.page.evaluate(pendingWidgetCheck))),
    );
  // The app library: home's last page (the user, 2026-10-23). Both screens.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `library-${label}`, viewport).then((r) => whenReady(r, async () => {
        for (const check of [libraryCheck, libraryLiveCheck, folderMorphCheck, folderCloseCheck, libraryDragCheck]) {
          const fails = await r.page.evaluate(check);
          if (fails.length) return fails;
        }
        return [];
      })));
  // The search widget and the pull-up launcher (the user, 2026-10-23): default in the bar and in "+ widget", pulled up
  // or tapped from the bar and from the grid, put back; after a reload a pill is there again. Folded and unfolded.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `search-launcher-${label}`, viewport).then(async (r) => {
        const helpers = `window.__sp = { pullUpFrom: ${pullUpFrom}, drawerWithPill: ${drawerWithPill}, closeDrawerNow: ${closeDrawerNow}, searchPutBack: ${searchPutBack}, searchToDock: ${searchToDock}, pillBelowDockInEdit: ${pillBelowDockInEdit}, overlayAsked: ${overlayAsked} }`;
        const s = await whenReady(r, async () => [...(await r.page.evaluate(searchDefaultCheck)), ...(await r.page.evaluate(helpers).then(() => r.page.evaluate(homeAsks)).then(() => r.page.evaluate(searchLauncherCheck)))]);
        if (s.problems.length) return s;
        await r.page.reload().catch(() => {});
        return whenReady(r, () => r.page.evaluate(() => (document.querySelector(".home > .bar .bar-pill, .search-face .bar-pill") ? [] : ["after a reload: no search pill anywhere"])));
      }));
  // ...and the launcher overlay's side of it (index.html?mode=pull): open from home's pill, its own field typing.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html?mode=pull`, `search-launcher-overlay-${label}`, viewport).then((r) => whenReady(r, async () => {
        await r.page.evaluate(`window.__sp = { drawerWithPill: ${drawerWithPill} }`);
        return r.page.evaluate(overlaySearchCheck);
      })));
  // Edit mode: a rectangle drawn on empty space picks tiles, picked tiles move together (the user, 2026-10-22).
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `home-select-${label}`, viewport).then((r) => whenReady(r, async () => {
        const fails = await r.page.evaluate(marqueeCheck);
        return fails.length ? fails : r.page.evaluate(partyMoveCheck);
      })));
  // Folders from picked apps: made, opened, named, an app dragged out, the last one left dissolving it. Both screens.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `home-folder-${label}`, viewport).then((r) => whenReady(r, async () => {
        for (const check of [folderCreateCheck, folderNameCheck, folderDissolveCheck]) {
          const fails = await r.page.evaluate(check);
          if (fails.length) return fails;
        }
        return [];
      })));
  // The pinned dock never fades (folded: the dock pages to the recent apps; the user, 2026-10-23).
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html`, "dock-no-fade", { width: 404, height: 900 }).then((r) => whenReady(r, () => r.page.evaluate(dockPinnedNoFade))));
  // The drawer's list fades at an edge with more to scroll (2026-10-24): a short screen, so the mock's apps scroll.
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html?mode=pull`, "scroll-fade", { width: 404, height: 560 }).then((r) => whenReady(r, () => r.page.evaluate(scrollFadeCheck))));
    runs.push(open(browser, `${ORIGIN}/index.html`, "close-up", { width: 404, height: 560 }).then((r) => whenReady(r, () => r.page.evaluate(closeUpCheck))));
  // Unfolded home is one wide page with one bar (hosts/wide.ts, home.tsx; the user, 2026-10-22), migrated from the two
  // side-by-side pages without moving a tile.
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html`, "wide-home", { width: 821, height: 883 }).then((r) => whenReady(r, async () => [...(await r.page.evaluate(wideMigrated)), ...(await r.page.evaluate(wideAcross)), ...(await r.page.evaluate(wideBar)), ...(await r.page.evaluate(wideLauncherBar)), ...(await r.page.evaluate(wideBarParked))])));
    runs.push(open(browser, `${ORIGIN}/index.html?mode=pull`, "launcher-keyboard", { width: 1280, height: 800 }).then((r) => whenReady(r, () => launcherKeyboardKeepsFocus(r.page))));
  // The same in the user's unfolded home: the dock on the right, the pill below it, 821x883 (the phone, 2026-10-28).
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html?mode=pull`, "launcher-keyboard-side", { width: 821, height: 883 }).then((r) => whenReady(r, () => launcherKeyboardSide(r.page, { width: 821, height: 883 }))));
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
  // Never a stale wide home on the cover screen (staleWide: a desktop size, a resize dropped while hidden, a show).
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html`, "stale-wide", { width: 412, height: 900 }).then((r) => whenReady(r, () => staleWide(r.page, { width: 412, height: 900 }))));
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
            const S = await window.__gw.mod("./state.ts");
            const X = await window.__gw.mod("./ui/ccexpand.ts");
            const { powos } = await window.__gw.mod("./bridge.ts");
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
                const still = () => !window.__gw.documentAnimations(".cc").length;
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
              const S = await window.__gw.mod("./state.ts");
              S.notif.value = true;
              const t0 = performance.now();
              while (order().length < 3 && performance.now() - t0 < 15000) await new Promise((ok) => setTimeout(ok, 50));
              await window.__gw.steady(() => order(), 4);
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
        for (const step of [overpullKit, overpullInFlow, overpullHalf, overpullCard, overpullShort, overpullTests, overpullFold, overpullExpand, panelTracksFinger, overpullRest]) {
          const out = await r.page.evaluate(step).catch((e) => [`evaluate: ${e.message.split("\n")[0]}`]);
          fails.push(...(out ?? []));
          if (fails.length) break;
        }
        r.problems.push(...fails);
        return { ...r, ready: true, ms: Date.now() - r.started };
      }),
    );
  // The shade folded (one stacked list) and unfolded (two columns: notifications left, controls right).
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(
        open(browser, `${ORIGIN}/index.html?mode=shade`, `shade-${label}`, viewport).then(async (r) => {
          await r.page.waitForFunction(() => window.__powosAlive === true || window.__powosBoot?.failed === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
          r.problems.push(...((await r.page.evaluate(shadeLayout).catch((e) => [`evaluate: ${e.message.split("\n")[0]}`])) ?? []));
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
            const P = await window.__gw.mod("./apps/pages.ts");
            P.installedApps.value = [...P.installedApps.value, { id: "local.pet", name: "Pet", version: "0.1.0", database: "local-pet", tier: 0, manifest: "{}" }];
            // The pet's module loaded (it sets window.__pet as it loads), then a render on: off, nothing may show.
            await window.__gw.until(() => window.__pet);
            await window.__gw.frames(2);
            // Off by default (the module's enabled; no SpacetimeDB here): installed but off must render nothing.
            if (document.querySelector(".pet")) return ["the pet rendered while it's off (enabled false)"];
            window.__pet?.on?.(true);
            await window.__gw.until(() => document.querySelector(".pet"));
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
  for (const r of (await Promise.all(runs)).filter(Boolean)) {
    if (r.problems.length) {
      failed++;
      for (const p of r.problems) console.log(`FAIL ${r.name}: ${p}`);
      printTail(r);
    } else console.log(`ok   ${r.name} (${r.ms} ms)`);
    for (const w of r.warnings.slice(0, 3)) console.log(`     ${r.name} console: ${w.slice(0, 200)}`);
  }
} finally {
  await browser.close();
}
process.exit(failed ? 1 : 0);

/**
 * A stack the pull drives is in flow and as wide as its list, like at rest: it once took the heads-up banner's ".peek"
 * (fixed, inset by --edge, its own veil, sliding in from the top) - the 2026-10-28 19:53 "shade pull transition is
 * still fucked".
 */
function overpullInFlow() {
  window.__op.inFlow = (fails, at, st) => {
  const sc = getComputedStyle(st), lr = st.parentElement.getBoundingClientRect(), sr = st.getBoundingClientRect();
  const banner = sc.position === "fixed" || sc.animationName !== "none" || (sc.backdropFilter || "none") !== "none";
  if (banner) fails.push(`${at}, a stack is styled as a banner (position ${sc.position}, animation ${sc.animationName}, backdrop ${sc.backdropFilter})`);
  if (Math.abs(sr.left - lr.left) > 1 || Math.abs(sr.right - lr.right) > 1)
    fails.push(`${at}, a stack is ${Math.round(sr.left - lr.left)}/${Math.round(lr.right - sr.right)} px in from its list's edges`);
  };
}

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
import { FLEET_SETUP } from "./agents-fleet.mjs";

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

/** dock-key-migration's steps: the page reloaded and up again, and its dock state and keys. */
async function reloadReady(r) {
  await r.page.reload().catch(() => {});
  await r.page.waitForFunction(() => window.__powosAlive === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
}
function dockState(r) {
  return r.page.evaluate(async () => {
    const S = await importShim("./state.ts");
    const keys = Object.fromEntries(Object.keys(localStorage).filter((k) => /dock\.(position|migrated)/.test(k)).map((k) => [k, localStorage[k]]));
    return { mode: S.dockMode.value, pos: S.dockPosition.value, unfolded: S.unfoldedDockPlacement.value, keys };
  });
}
/** Seeds [seed] as the only storage, reloads twice: the unfolded dock is right after the migration and after a reload. */
async function dockSeedRight(r, seed) {
  await r.page.evaluate((seed) => { localStorage.clear(); for (const [k, v] of Object.entries(seed)) localStorage.setItem(k, v); }, seed);
  const fails = [];
  for (const when of ["migrated", "reloaded"]) {
    await reloadReady(r);
    const s = await dockState(r);
    const right = s.mode === "unfolded" && s.unfolded === "right" && s.pos === "right" && s.keys["powos.dock.position.unfolded"] === "right";
    if (!right) fails.push(`${when} from ${JSON.stringify(seed)}: unfolded dock not right: ${JSON.stringify(s)}`);
  }
  return fails;
}
/**
 * The dock's old keys (the user, 2026-10-30 18:30: the right dock jumped to the bottom after closing a window): the old
 * `powos.dock.position` right becomes the unfolded key's right (also over the "bottom" stored() wrote unasked), reloads
 * keep it, a check's dockTry never reaches storage, and a choice made after the migration isn't undone.
 */
async function dockKeyMigration(r) {
  const fails = [];
  fails.push(...(await dockSeedRight(r, { "powos.dock.position": "right" })));
  fails.push(...(await dockSeedRight(r, { "powos.dock.position": "right", "powos.dock.position.unfolded": "bottom", "powos.dock.position.desktop": "left" })));
  // A check's placement: shown, never stored, gone on a reload.
  const tried = await r.page.evaluate(async () => {
    const S = await importShim("./state.ts");
    S.dockTry.value = "left";
    await new Promise((res) => setTimeout(res, 50));
    return { pos: S.dockPosition.value, stored: localStorage.getItem("powos.dock.position.unfolded") };
  });
  if (tried.pos !== "left" || tried.stored !== "right") fails.push(`dockTry: ${JSON.stringify(tried)}`);
  await reloadReady(r);
  const after = await dockState(r);
  if (after.pos !== "right") fails.push(`dockTry outlived a reload: ${JSON.stringify(after)}`);
  // The user's later pick (Settings) stays: the migration ran once.
  await r.page.evaluate(async () => { (await importShim("./state.ts")).unfoldedDockPlacement.value = "bottom"; await new Promise((res) => setTimeout(res, 50)); });
  await reloadReady(r);
  const picked = await dockState(r);
  if (picked.pos !== "bottom") fails.push(`a pick after the migration was undone on reload: ${JSON.stringify(picked)}`);
  return fails;
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

/**
 * In the page: the Agents screen and widget against dev/agents-fleet.mjs's fleet (3 working, 1 stopped with
 * model_not_found, 12 idle; ui/agents.tsx, fleet.ts): the screen shows 3 working cards, 1 attention item and the
 * folded "12 idle" line, no raw label anywhere; the widget at 2x2 shows the count and the top (stopped) task, at 4x2
 * four tiles with the stopped one first, in red. [setup]: FLEET_SETUP, run again once the widget mounts (the mock
 * answers its subscription with its own snapshot).
 */
async function agentsFleetCheck(setup) {
  const G = window.__gw;
  const run = (body) => new (Object.getPrototypeOf(async function () {}).constructor)("U", "E", "sleep", body)(G.mod, window.__mockEvents, (ms) => new Promise((r) => setTimeout(r, ms)));
  const A = await G.mod("./agents.ts");
  const { powos } = await G.mod("./bridge.ts");
  const S = await G.mod("./state.ts");
  const RAW = /<ta|<task|model_not_found|\bidle \d|\(mac\)|Bash /;
  // Helpers are inner: page.evaluate serialises only this function.
  const text = (q, root = document) => root?.querySelector(q)?.textContent ?? "";
  const rawIn = (where, t) => {
    const m = t.match(RAW);
    return m ? [`${where}: a raw label "${m[0]}"`] : [];
  };
  // The screen's groups: 3 working, 1 stopped ("model not found"), "12 idle" folded.
  const screenGroups = () => {
    const fails = [];
    const working = [...document.querySelectorAll(".ag-screen .fl-sec .fl-card:not(.fl-bad)")].length;
    const bad = [...document.querySelectorAll(".ag-screen .fl-card.fl-bad")];
    const fold = text(".ag-screen .fl-fold-head");
    if (working !== 3) fails.push(`screen: ${working} working cards, not 3`);
    if (bad.length !== 1 || !/model not found/i.test(bad[0]?.textContent ?? "")) fails.push(`screen: ${bad.length} attention items (want 1, "model not found")`);
    if (!/12 idle/.test(fold)) fails.push(`screen: the folded line says "${fold.trim()}", not "12 idle ..."`);
    return fails;
  };
  // The screen's manager row and progress bars.
  const screenRows = () => {
    const fails = [];
    if (!/Manager/.test(text(".ag-screen .fl-mgr"))) fails.push("screen: no manager row");
    if (!document.querySelector(".ag-screen .fl-card .fl-bar")) fails.push("screen: no progress bar on the working cards");
    return fails;
  };
  const firstStopped = (tiles) => tiles[0]?.classList.contains("bad") && /^Can.t( start|…)/.test(tiles[0]?.textContent ?? "");
  // The widget at [w]x[h]: [want] tiles, the stopped one first in red (its reason, cut to "Can't…" at 2x2), the head's counts.
  const widgetFails = (panel, w, h, want) => {
    const fails = [];
    const tiles = [...(panel?.querySelectorAll(".fl-tile") ?? [])];
    const head = text(".ag-head", panel);
    if (tiles.length !== want) fails.push(`widget ${w}x${h}: ${tiles.length} tiles, not ${want}`);
    if (!firstStopped(tiles)) fails.push(`widget ${w}x${h}: the first tile isn't the stopped one in red`);
    if (!/3 working/.test(head) || !/1 needs you/.test(head) || /\+\d/.test(head)) fails.push(`widget ${w}x${h}: its head says "${head}"`);
    return fails;
  };
  // Home holding only the agents widget at [w]x[h]; its fails.
  const widget = async (w, h, want) => {
    const home = await powos.home.get();
    for (const i of home.items) await powos.home.remove(i.key);
    await powos.home.addPanel("agents", home.pages[0] ?? 1, { x: 0, y: 0, w, h });
    S.page.value = 0;
    await G.until(() => document.querySelector(".page:not(.away) .ag-panel"), 3000).then(() => run(setup));
    await G.until(() => /needs you/.test(text(".page:not(.away) .ag-panel .ag-head")) && document.querySelector(".page:not(.away) .ag-panel .fl-tile"), 3000);
    await G.frames(4);
    const panel = document.querySelector(".page:not(.away) .ag-panel");
    return [...widgetFails(panel, w, h, want), ...rawIn(`widget ${w}x${h}`, panel?.textContent ?? "")];
  };
  A.openAgents(null);
  await run(setup);
  await G.until(() => document.querySelectorAll(".ag-screen .fl-card").length >= 4, 3000);
  const fails = [...screenGroups(), ...screenRows(), ...rawIn("screen", text(".ag-screen"))];
  document.querySelector(".ag-screen .fl-fold-head")?.click();
  await G.frames(2);
  fails.push(...rawIn("screen, idle opened", text(".ag-screen")));
  A.closeAgents();
  for (const [w, h, want] of [[2, 2, 1], [4, 2, 4]]) fails.push(...(await widget(w, h, want)));
  return fails;
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
   * Half way (k about 0.5), down or back up: the notification stacks don't follow the pull - every one stays folded,
   * in flow and where it was (2026-10-30: every group is a folded stack, the control center's whole view or not, so
   * all apps fit on screen at once; they used to unfold with this pull).
   */
  o.midPull = (fails, way) => {
    return (k) => {
      const at = `${way} half way (k ${k.toFixed(2)})`;
      const stacks = [...document.querySelectorAll(".panel-body.together .notif-stack")];
      if (!stacks.length) return fails.push(`${at}, no notification stack in the shade`);
      if (stacks.some((st) => st.classList.contains("open"))) fails.push(`${at}, a notification stack unfolds with the pull`);
      for (const st of stacks) o.inFlow(fails, at, st);
      o.half[way] = stacks.map(o.topPart);
    };
  };
  o.half = {};
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
 * had it, the row still, every notification stack still folded. Pulled from the NOTIFICATIONS' list (the user, 2026-10-28: folded, a
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
  // The notifications stay stacked (2026-10-30, replacing 2026-10-24's "every stack unfolds"): all groups fit at once.
  const stacks = [...document.querySelectorAll(".panel-body.together .notif-stack")];
  if (!stacks.length) fails.push("no grouped notifications in the shade");
  else if (stacks.some((g) => g.classList.contains("open"))) fails.push(`expanded, ${stacks.filter((g) => g.classList.contains("open")).length} of ${stacks.length} notification stacks unfolded with it`);
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

/**
 * The launcher's pull (pull.tsx, the host's pull.drag p) ticks the haptics (ui/haptics.ts; the mock counts them in
 * window.__hapticsMock) once as it crosses its threshold (gesture.ts OPEN_AT): nothing short of it, nothing more held
 * past it, once more back and over again (the user, 10-31: "some small haptics thing there").
 *
 * Driven from the gate, one synchronous evaluate per event: no promise is left pending in the page between the drag's
 * frames. A long async evaluate awaiting the page's own frames/timers failed "Promise was collected" about one full gate
 * in five (10-31, rAF and a 16 ms timer alike, its whenReady retry too) - nothing reloaded the page (no files.changed from
 * the mock, no reload before the evaluate); the awaited promise was lost under load. A synchronous call has none to lose.
 */
async function launcherHapticsCheck(page) {
  const emit = (name, data) => page.evaluate((n, d) => void window.__mockEvents.emit(n, d), name, data);
  const ticks = () => page.evaluate(() => window.__hapticsMock.tick);
  const has = await page.evaluate(() => !!(window.__mockEvents && window.__hapticsMock));
  if (!has) return ["no mock events or mock haptics to drive the launcher's pull"];
  const t0 = await ticks();
  const fails = [];
  const to = async (ps, want, what) => {
    for (const p of ps) {
      await emit("pull.drag", { p });
      await new Promise((ok) => setTimeout(ok, 16));
    }
    const now = await ticks();
    if (now - t0 !== want) fails.push(`${what}: ${now - t0} haptic ticks, want ${want}`);
  };
  await emit("pull.begin", { kind: "apps" });
  await to([0.02, 0.06, 0.1], 0, "short of the threshold");
  await to([0.3], 1, "past the threshold");
  await to([0.5, 0.8, 1, 0.9, 0.6, 0.4], 1, "held past it");
  await to([0.1, 0.05], 1, "back under it");
  await to([0.35], 2, "over it again");
  await emit("pull.end", { open: false });
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
/** In the page: the render scan's hooks are there only while it's used, and the very originals after (renderscan.ts). */
async function renderScanCheck() {
  const fails = [], KEYS = ["__r", "diffed", "__c", "__e"];
  const options = (await window.importShim("preact")).options;
  const orig = KEYS.map((k) => options[k]);
  const same = () => KEYS.every((k, i) => options[k] === orig[i]);
  const R = await window.__gw.mod("./ui/renderscan.ts"), O = await window.__gw.mod("./ui/renderoverlay.ts");
  const P = await window.__gw.mod("./ui/perfrec.ts"), S = await window.__gw.mod("./state.ts");
  if (!same()) fails.push("options hooks changed by loading the render scan (it must install nothing while off)");
  R.startScan("gate");
  if (same()) fails.push("startScan installed no hooks");
  S.editing.value = !S.editing.value;
  await window.__gw.frames(3);
  S.editing.value = !S.editing.value;
  await window.__gw.frames(3);
  const rep = R.renderReport();
  if (!(rep.renders > 0)) fails.push(`no renders counted across an edit-mode flip: ${JSON.stringify(rep).slice(0, 200)}`);
  O.setOverlay(true);
  P.onMeter({ on: true, rec: 4242 });
  S.editing.value = !S.editing.value;
  await window.__gw.frames(3);
  S.editing.value = !S.editing.value;
  await window.__gw.frames(3);
  if (document.querySelectorAll("html > canvas").length !== 1) fails.push("the overlay's canvas isn't up while it's on");
  R.stopScan("gate");
  O.setOverlay(false);
  if (same()) fails.push("hooks gone while a recording still uses them");
  P.onMeter({ on: true });
  await window.__gw.frames(2);
  if (!same()) fails.push(`options hooks not restored after the last user stopped: ${KEYS.filter((k, i) => options[k] !== orig[i]).join(", ")}`);
  if (R.scanning()) fails.push("still scanning after every user stopped");
  if (document.querySelector("html > canvas")) fails.push("the overlay's canvas left behind");
  return fails;
}

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

/**
 * Fold <-> unfold with no input (the user, 10-31 00:18: unfolded, home kept the mobile layout until the page was moved).
 * window.screen pinned at the old screen's size over each resize (the WebView updates it after the resize event): in
 * the first frame after the resize, home's layout classes and the dock's side are already the new mode's.
 */
async function foldSameFrame(page) {
  const F = "./dev/fold-check.js";
  const call = (fn, ...a) => page.evaluate(async (F, fn, a) => (await importShim(F))[fn](...a), F, fn, a);
  const folded = { width: 404, height: 899 }, unfolded = { width: 821, height: 883 };
  await call("setUnfoldedRight");
  await call("pinScreen", folded.width, folded.height);
  const bad = [];
  const steps = [[folded, unfolded, { wide: true, dock: "right" }], [unfolded, folded, { wide: false, dock: "bottom" }], [folded, unfolded, { wide: true, dock: "right" }]];
  for (const [from, to, want] of steps) {
    await call("watchNextResize", to.width);
    await viewTo(page, to);
    const seen = await page.evaluate(() => window.__gw.until(() => window.__foldSeen).then(() => window.__foldSeen));
    if (seen?.wide !== want.wide || seen?.dock !== want.dock)
      bad.push(`${from.width}x${from.height} -> ${to.width}x${to.height}, screen still ${seen?.screen}: first frame after the resize wide=${seen?.wide} dock=${seen?.dock}, want wide=${want.wide} dock=${want.dock}`);
    // The screen catches up (the WebView's, a moment later).
    await call("pinScreen", to.width, to.height);
    await restAt(page, to);
  }
  return bad;
}

/**
 * The grip while folding (EM2): a long press on home that ends with a fold change within 1 s never leaves edit mode
 * on - the press's timer firing after the resize (EM2), or edit mode entered just before it (EM1).
 */
async function foldGrip(page) {
  const F = "./dev/fold-check.js";
  const call = (fn, ...a) => page.evaluate(async (F, fn, a) => (await importShim(F))[fn](...a), F, fn, a);
  const folded = { width: 404, height: 899 }, unfolded = { width: 821, height: 883 };
  const bad = [];
  for (const [label, before, to] of [["press, fold change, hold", 150, unfolded], ["held into edit mode, then the fold change", 600, folded]]) {
    await call("setUnfoldedRight");
    const why = await call("pressEmpty");
    if (why) return [why];
    await page.evaluate((ms) => window.__gw.sleep(ms), before);
    if (before > 420 && !(await call("editingNow"))) bad.push(`${label}: a 600 ms hold on empty space didn't enter edit mode (the scene's premise)`);
    await viewTo(page, to);
    await restAt(page, to);
    await page.evaluate(() => window.__gw.sleep(600));
    await call("releasePress");
    if (await call("editingNow")) bad.push(`${label}: editing after a long press and a fold change within 1 s`);
  }
  return bad;
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
/**
 * A swipe home from an app (the host's "recents.begin/drag/end" to: home): home is a desktop, always there - nothing of
 * it scales, fades, moves or reflows, during the swipe or after it is let go (the user, 2026-10-31: "the whole thing pops
 * up a little bit" ... "it should just like always be there"). Sampled every frame from the swipe's start to 600 ms
 * after it ends.
 */
async function homeReturnCheck() {
  const fails = [];
  const host = (event, data) => window.__mockEvents.emit(event, data);
  const raf = () => new Promise((ok) => requestAnimationFrame(() => ok()));
  const home = document.querySelector(".home");
  const screens = document.querySelector(".screens");
  const dock = document.querySelector(".dock");
  if (!home || !screens) return ["home-return: no .home / .screens"];
  const box = (el) => { const r = el?.getBoundingClientRect(); return r ? `${Math.round(r.left)},${Math.round(r.top)},${Math.round(r.width)}x${Math.round(r.height)}` : "-"; };
  const grid = () => document.querySelector(".page-track") ?? document.querySelector(".pages");
  const first = { home: box(home), dock: box(dock), grid: box(grid()) };
  const look = (when) => {
    for (const [name, el] of [[".home", home], [".screens", screens]]) {
      const cs = getComputedStyle(el);
      if (cs.transform !== "none" && cs.transform !== "matrix(1, 0, 0, 1, 0, 0)") fails.push(`${when}: ${name} transform ${cs.transform} (home must stay put)`);
      if (Number(cs.opacity) !== 1) fails.push(`${when}: ${name} opacity ${cs.opacity} (home must stay in sight)`);
    }
    const now = { home: box(home), dock: box(dock), grid: box(grid()) };
    for (const k of Object.keys(first)) if (now[k] !== first[k]) fails.push(`${when}: ${k} moved ${first[k]} -> ${now[k]}`);
  };
  const tasks = [{ id: 501, label: "Chrome", key: null, icon: null, snapshot: "" }, { id: 502, label: "Camera", key: null, icon: null, snapshot: "" }];
  host("recents.begin", { from: 501, tasks });
  await raf();
  look("begin");
  for (let i = 1; i <= 20; i++) {
    host("recents.drag", { progress: Math.min(1, i / 12), x: 0, y: -i * 8, home: Math.max(0, (i - 10) / 10) });
    await raf();
    look(`drag ${i}`);
  }
  host("recents.end", { to: "home" });
  const t0 = performance.now();
  for (let f = 0; performance.now() - t0 < 600; f++) {
    await raf();
    look(`after end, frame ${f}`);
  }
  return [...new Set(fails)].slice(0, 8);
}

/**
 * One recents update re-renders only the card that changed (perf-1793456386286: TaskCard 122 renders from onOpen/onMenu
 * made afresh each Recents render; recents.tsx now passes one handler per kind, TaskCard is memoised). The switcher up
 * with 4 cards; then the window lands on the first one with a fresh snapshot (recents.end to: switcher -> that card's
 * task changes), then a recents.update adds a task: each step may render exactly one TaskCard.
 */
async function recentsRendersCheck() {
  const fails = [];
  const host = (event, data) => window.__mockEvents.emit(event, data);
  const raf = () => new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(() => ok())));
  const scan = await window.__gw.mod("./ui/renderscan.ts");
  const task = (id, label) => ({ id, label, key: null, icon: null, snapshot: "" });
  const tasks = [task(601, "Chrome"), task(602, "Camera"), task(603, "Clock"), task(604, "Maps")];
  host("recents.show", { open: true, from: 601, tasks });
  await raf();
  if (document.querySelectorAll(".task[data-task]").length < 4) return [`recents-renders: ${document.querySelectorAll(".task[data-task]").length} cards shown, expected 4`];
  const cards = () => scan.scanStats().filter((x) => x.name === "TaskCard").reduce((n, x) => n + x.renders, 0);
  const step = async (what, act) => {
    scan.startScan("gate-recents");
    scan.reset();
    act();
    await raf();
    const n = cards();
    scan.stopScan("gate-recents");
    console.log(`recents-renders: ${what}: TaskCard rendered ${n}x`);
    if (n !== 1) fails.push(`${what}: TaskCard rendered ${n}x, expected 1 (only the changed card)`);
  };
  await step("landed with a fresh snapshot", () => host("recents.end", { to: "switcher", snapshot: "data:image/gif;base64,R0lGODlhAQABAAAAACw=" }));
  await step("a task added", () => host("recents.update", { tasks: [...tasks, task(605, "Notes")] }));
  return fails;
}

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
const AI_TRY_ID = "gate-overlap";

/** In the page: the bridge's verdict / message recorded (window.__nyGot), a Needs-you card to try on the board, opened. */
async function aiTrySetup(id) {
  const G = window.__gw;
  const [S, P, { powos }] = await Promise.all([G.mod("./state.ts"), G.mod("./ui/powai.tsx"), G.mod("./bridge.ts")]);
  const got = (window.__nyGot = []);
  window.__nyRestore = [powos.ai.verdict, powos.agents.message];
  powos.ai.verdict = async (...a) => void got.push(["verdict", ...a]);
  powos.agents.message = async (...a) => void got.push(["message", ...a]);
  const now = Date.now();
  P.board.value = [{ id, title: "Windows: tap the one behind to raise it", owner: "coder", status: "waiting", note: "Overlap two windows and tap the one behind: it should come to the front", project: "Windows", created: now - 9e5, updated: now - 6e4, done: 0, progressDone: 0, progressTotal: 0, step: "", steps: "", commits: JSON.stringify([{ sha: "abc1234", subject: "" }]), images: JSON.stringify(["/run/powos-app/powos-ai-shared/screen-1793386307690.jpg"]), activity: now - 6e4 }];
  P.boardSeen.value = true;
  S.page.value = -1;
  // The board is behind the AI page's ⋯ now: Progress (no powos-progress app here: the board itself).
  S.aiScreen.value = "progress";
  const card = () => [...document.querySelectorAll(".ai-work-list .ai-item")].find((e) => e.textContent.includes("Overlap two windows"));
  if (!(await G.until(card, 4000))) return false;
  card().querySelector(".ai-item-row").click();
  return !!(await G.until(() => card()?.querySelector(".ai-item-more"), 2000));
}

/** In the page: the card's actions and words - works / still broken / skip, no raw file name or "a change". */
function aiTryCardFails() {
  const card = [...document.querySelectorAll(".ai-work-list .ai-item")].find((e) => e.textContent.includes("Overlap two windows"));
  const fails = [];
  const acts = [...card.querySelectorAll(".ai-item-acts .ai-act")].map((b) => b.textContent.trim()).join(" / ");
  if (acts !== "works / still broken / skip") fails.push(`its actions are ${acts || "none"}, not works / still broken / skip`);
  const raw = card.textContent.match(/a change|\S+\.(jpg|png)/);
  if (raw) fails.push(`it shows a raw label or file name: "${raw[0]}"`);
  return fails;
}

/** In the page: "still broken", "x" typed in the reply line, sent; then what the bridge got (null: no reply line). */
async function aiReplyX() {
  const G = window.__gw;
  const card = () => [...document.querySelectorAll(".ai-work-list .ai-item")].find((e) => e.textContent.includes("Overlap two windows"));
  [...card().querySelectorAll(".ai-act")].find((b) => b.textContent.trim() === "still broken")?.click();
  if (!(await G.until(() => card()?.querySelector(".ai-reply textarea"), 2000))) return null;
  const field = card().querySelector(".ai-reply textarea");
  field.value = "x";
  field.dispatchEvent(new Event("input", { bubbles: true }));
  await G.frames(2);
  card().querySelector(".ai-reply").requestSubmit();
  await G.until(() => window.__nyGot.length >= 2, 2000);
  return window.__nyGot;
}

/** In the page: the card out of Needs you, in "Waiting for an agent" at once; then the bridge and board as they were. */
async function aiMovedAndRestore() {
  const G = window.__gw;
  const moved = () => !document.querySelector(".ai-work-list .ai-group.you") && document.querySelector(".ai-work-list .ai-group.free .ai-group-count")?.textContent === "1";
  const ok = !!(await G.until(moved, 2000));
  const [{ powos }, P] = await Promise.all([G.mod("./bridge.ts"), G.mod("./ui/powai.tsx")]);
  [powos.ai.verdict, powos.agents.message] = window.__nyRestore;
  P.board.value = [];
  return ok;
}

const nyCall = (got, kind) => got.find((c) => c[0] === kind) ?? null;
/** The user FAIL check with the words "x" on the task. */
const failCheckOk = (v) => !!v && v[1] === AI_TRY_ID && v[2] === false && v[3] === "still broken: x";
/** The manager's mail naming the task, with the words. */
const managerMailOk = (m) => !!m && m[1] === "manager" && m[2].includes(AI_TRY_ID) && m[2].includes('"x"');

/**
 * A Needs-you card that asks the user to try something (the user, 2026-10-30 20:52: "How am I supposed to give feedback
 * to this?" - it had only done / skip, and "a change · screen-....jpg" under it): works / still broken (skip quiet), no
 * raw file names or "a change"; "still broken", "x", send -> the bridge gets the user FAIL check with those words and
 * the manager's mail naming the task, and the card moves at once.
 */
async function aiStillBrokenCheck(page) {
  if (!(await page.evaluate(aiTrySetup, AI_TRY_ID))) return ["the Needs-you card to try didn't show (or open)"];
  const fails = await page.evaluate(aiTryCardFails);
  const got = await page.evaluate(aiReplyX);
  if (!got) return [...fails, "still broken opened no reply line"];
  if (!failCheckOk(nyCall(got, "verdict"))) fails.push(`the bridge got no user FAIL check with the words (${JSON.stringify(nyCall(got, "verdict"))})`);
  if (!managerMailOk(nyCall(got, "message"))) fails.push(`the manager got no mail naming the task (${JSON.stringify(nyCall(got, "message"))})`);
  if (!(await page.evaluate(aiMovedAndRestore))) fails.push("the card didn't move to Waiting for an agent at once");
  return fails;
}

/** In the page: the bridge recorded (window.__nyGot) and three Needs-you cards on the board ([try], [todo]: their words). */
async function nyTrySetup([tryLine, todo]) {
  const G = window.__gw;
  const [S, P, { powos }] = await Promise.all([G.mod("./state.ts"), G.mod("./ui/powai.tsx"), G.mod("./bridge.ts")]);
  const got = (window.__nyGot = []);
  window.__nyRestore = [powos.ai.verdict, powos.agents.message];
  powos.ai.verdict = async (...a) => void got.push(["verdict", ...a]);
  powos.agents.message = async (...a) => void got.push(["message", ...a]);
  const now = Date.now();
  const base = { owner: "coder", status: "waiting", project: "Windows", created: now - 9e5, done: 0, progressDone: 0, progressTotal: 0, step: "", steps: "", commits: "", images: "" };
  const row = (id, title, more, t) => ({ ...base, id, title, note: "", tryLine: "", ...more, updated: now - t, activity: now - t });
  P.board.value = [
    row("gate-ny-try", "Window tabs: drop a title bar onto another to group them", { note: "waiting on you", tryLine }, 6e4),
    row("gate-ny-do", "Charge the phone", { note: todo }, 7e4),
    row("gate-ny-none", "Window tabs in the switcher", {}, 8e4),
  ];
  P.boardSeen.value = true;
  S.page.value = -1;
  // The board is behind the AI page's ⋯ now: Progress (no powos-progress app here: the board itself).
  S.aiScreen.value = "progress";
  return !!(await G.until(() => document.querySelectorAll(".ai-work-list .ai-group.you .ai-item").length === 3, 4000));
}

/** In the page: each Needs-you card's actions and its line under the title. */
function nyCards() {
  return [...document.querySelectorAll(".ai-work-list .ai-group.you .ai-item")].map((c) => ({
    title: c.querySelector(".ai-item-title")?.textContent.trim(),
    line: c.querySelector(".ai-item-line > .ai-item-facts")?.textContent.trim(),
    acts: [...c.querySelectorAll(".ai-item-acts .ai-act")].map((b) => b.textContent.trim()).join(" / "),
  }));
}

/** In the page: [label] on the card titled [title], "x" typed in its reply line, sent; what the bridge got (null: no line). */
async function nyReply([title, label, want]) {
  const G = window.__gw;
  const card = () => [...document.querySelectorAll(".ai-work-list .ai-item")].find((e) => e.querySelector(".ai-item-title")?.textContent.trim() === title);
  [...card().querySelectorAll(".ai-act")].find((b) => b.textContent.trim() === label)?.click();
  if (!(await G.until(() => card()?.querySelector(".ai-reply textarea"), 2000))) return null;
  const field = card().querySelector(".ai-reply textarea");
  field.value = "x";
  field.dispatchEvent(new Event("input", { bubbles: true }));
  await G.frames(2);
  card().querySelector(".ai-reply").requestSubmit();
  await G.until(() => window.__nyGot.length >= want, 2000);
  return window.__nyGot.splice(0);
}

/** In the page: the bridge and board as they were. */
async function nyRestore() {
  const [{ powos }, P] = await Promise.all([window.__gw.mod("./bridge.ts"), window.__gw.mod("./ui/powai.tsx")]);
  [powos.ai.verdict, powos.agents.message] = window.__nyRestore;
  P.board.value = [];
}

const NY_TRY_TITLE = "Window tabs: drop a title bar onto another to group them";
const NY_TRY = "Drop one window's title bar onto another: they become tabs";
const NY_DO = "Plug the phone into the Mac and leave it charging";
/** The manager's mail naming [id], with the words "x". */
const nyMailOk = (m, id) => !!m && m[1] === "manager" && m[2].includes(id) && m[2].includes('"x"');

/** The cards' actions and lines: works / still broken under the --try line, done / can't on the thing to do, no empty phrase. */
function nyCardFails(cards) {
  const by = (t) => cards.find((c) => c.title === t) ?? {};
  const [tryCard, doCard, none] = [by(NY_TRY_TITLE), by(NY_DO), by("Window tabs in the switcher")];
  const fails = [];
  if (tryCard.acts !== "works / still broken / skip") fails.push(`the card to try offers ${tryCard.acts || "nothing"}, not works / still broken / skip`);
  if (tryCard.line !== NY_TRY) fails.push(`the card to try says "${tryCard.line}", not its --try line`);
  if (doCard.acts !== "done / can't / problem / skip") fails.push(`the thing to do offers ${doCard.acts || "nothing"}, not done / can't / problem / skip`);
  if (!none.line || /waiting on you/.test(none.line)) fails.push(`the card with no words says "${none.line}"`);
  return fails;
}

/** "still broken", "x" on the card to try: the user FAIL check with the words and the manager's mail. */
function nyBrokenFails(got) {
  if (!got) return ["still broken opened no reply line"];
  const v = nyCall(got, "verdict");
  const fails = [];
  if (!(v && v[1] === "gate-ny-try" && v[2] === false && v[3] === "still broken: x")) fails.push(`still broken recorded no user FAIL check with the words (${JSON.stringify(v)})`);
  if (!nyMailOk(nyCall(got, "message"), "gate-ny-try")) fails.push(`still broken mailed the manager nothing naming the task (${JSON.stringify(got)})`);
  return fails;
}

/** "can't / problem", "x" on the thing to do: the manager's mail, no check recorded. */
function nyCantFails(got) {
  if (!got) return ["can't / problem opened no reply line"];
  const fails = [];
  if (!nyMailOk(nyCall(got, "message"), "gate-ny-do")) fails.push(`can't / problem mailed the manager nothing naming the task (${JSON.stringify(got)})`);
  if (nyCall(got, "verdict")) fails.push("can't / problem recorded a check on a thing to do");
  return fails;
}

/**
 * Needs-you cards answer like Ready to try (the user, 2026-10-31 01:44: "Needs you doesn't let me say that it's
 * broken" - a "waiting on you" card had only done / skip): one asking to try (a --try, the note only "waiting on you")
 * offers works / still broken / skip under its --try line, and "still broken", "x" records the user FAIL check with
 * those words and mails the manager, as Ready to try does; a thing to do offers done / can't / problem / skip, the
 * reply mailed to the manager; one with neither says so plainly, never "waiting on you".
 */
async function nyTryCheck(page) {
  if (!(await page.evaluate(nyTrySetup, [NY_TRY, NY_DO]))) return ["the three Needs-you cards didn't show"];
  const fails = nyCardFails(await page.evaluate(nyCards));
  fails.push(...nyBrokenFails(await page.evaluate(nyReply, [NY_TRY_TITLE, "still broken", 2])));
  fails.push(...nyCantFails(await page.evaluate(nyReply, [NY_DO, "can't / problem", 1])));
  await page.evaluate(nyRestore);
  return fails;
}

const AI_CHAT_TRY = "gate-chat-try";
const AI_CHAT_DO = "gate-chat-do";

/** In the page: a conversation of [n] exchanges, the last one the manager's things to try (a ```try block). */
async function aiChatSetup([n, tag]) {
  const G = window.__gw;
  const [S, P, { powos }] = await Promise.all([G.mod("./state.ts"), G.mod("./ui/powai.tsx"), G.mod("./bridge.ts")]);
  const now = Date.now();
  const row = (id, title, more) => ({ id, title, owner: "coder", note: "", project: "Windows", created: now - 9e5, updated: now - 6e4, done: 0, progressDone: 0, progressTotal: 0, step: "", steps: "", commits: "", images: "", activity: now - 6e4, tryLine: "", ...more });
  P.board.value = [row("gate-epic", "Daily driver: everything on the phone", { status: "working", progressDone: 5, progressTotal: 8 }), row("gate-plug", "Kernel test", { status: "waiting", note: "Plug the phone into the Mac once" })];
  P.boardSeen.value = true;
  const got = (window.__nyGot = []);
  window.__nyRestore = [powos.ai.verdict, powos.agents.message];
  powos.ai.verdict = async (...a) => void got.push(["verdict", ...a]);
  powos.agents.message = async (...a) => void got.push(["message", ...a]);
  try { localStorage.removeItem("powos.ai.tried"); } catch {}
  const items = [];
  for (let i = 0; i < n; i++) {
    items.push({ kind: "user", text: `question ${i}` });
    items.push({ kind: "tool", name: "Bash", hint: "ls", ok: true, text: "", out: "" });
    items.push({ kind: "tool", name: "Read", hint: "/x/y.md", ok: true, text: "", out: "" });
    items.push({ kind: "assistant", text: `answer ${i}` });
  }
  const tryBlock = { title: "2 things ready", items: [{ id: `gate-chat-try${tag}`, line: "Tap a window behind another: it comes to the front" }, { id: `gate-chat-do${tag}`, line: "Plug the phone into the Mac once", do: true }] };
  items.push({ kind: "assistant", text: "Shipped.\n\n```try\n" + JSON.stringify(tryBlock) + "\n```" });
  S.aiScreen.value = "chat";
  S.chat.value = { busy: false, items };
  S.page.value = -1;
  return !!(await G.until(() => document.querySelector(".ai-screen .ai-chat .msg.try"), 4000));
}

/** In the page: what of the old page is still on the chat (board boxes, at work, units, the agents tile, "earlier"). */
function aiChatBoxes() {
  const scr = document.querySelector(".ai-screen");
  const left = [".ai-group", ".ai-work-list", ".ai-board", ".ai-session", ".ai-card", ".ai-history", ".ai-fold"].filter((q) => scr.querySelector(q));
  const text = scr.textContent;
  const words = ["Needs you", "Ready to try", "Being worked on", "Waiting for an agent", "installed & running", "earlier ·", "friction ·", "at work"].filter((w) => text.includes(w));
  return [...left, ...words];
}

/** In the page: the try message's buttons, "still broken" + "x" sent; what the bridge got and what the item says now. */
async function aiChatBroken() {
  const G = window.__gw;
  const item = () => [...document.querySelectorAll(".ai-screen .try-item")].find((e) => e.textContent.includes("Tap a window behind"));
  const acts = [...item().querySelectorAll(".try-acts .ai-act")].map((b) => b.textContent.trim()).join(" / ");
  const doActs = [...document.querySelectorAll(".ai-screen .try-item")].find((e) => e.textContent.includes("Plug the phone"))?.querySelectorAll(".try-acts .ai-act");
  [...item().querySelectorAll(".ai-act")].find((b) => b.textContent.trim() === "still broken").click();
  if (!(await G.until(() => item()?.querySelector(".ai-reply textarea"), 2000))) return { acts, got: null };
  const field = item().querySelector(".ai-reply textarea");
  field.value = "x";
  field.dispatchEvent(new Event("input", { bubbles: true }));
  await G.frames(2);
  item().querySelector(".ai-reply").requestSubmit();
  await G.until(() => window.__nyGot.length >= 2 && item()?.querySelector(".try-said"), 2000);
  return { acts, doActs: [...(doActs ?? [])].map((b) => b.textContent.trim()).join(" / "), got: window.__nyGot.splice(0), said: item()?.querySelector(".try-said")?.textContent.trim() ?? "" };
}

/** In the page: ⋯, then each screen and back; a fail per screen that didn't open, name itself, or come back. */
async function aiChatMenu() {
  const G = window.__gw;
  const titled = (name) => [...document.querySelectorAll(".ai-screen .ai-top .ai-title")].some((t) => t.textContent.trim() === name);
  // One screen from ⋯ and back; its fails. Inner (page.evaluate serialises only this function).
  const screen = async (name) => {
    const fails = [];
    document.querySelector(".ai-screen .ai-more")?.click();
    const find = () => [...document.querySelectorAll(".ai-screen .ai-menu-item")].find((b) => b.textContent.trim() === name);
    await G.until(find, 2000);
    const item = find();
    if (!item) return [`⋯ has no "${name}"`];
    item.click();
    const opened = await G.until(() => titled(name) && document.querySelector(".ai-screen .ai-sub"), 2000);
    if (!opened) fails.push(`"${name}" didn't open as its own screen`);
    // No powos-progress app: a summary per area, never the board's rows to answer (the try buttons live in the chat).
    if (name === "Progress" && !document.querySelector(".ai-screen .ai-sub .ai-summary")) fails.push("Progress (no powos-progress app) shows no summary");
    if (name === "Progress" && document.querySelector(".ai-screen .ai-sub :is(.ai-work-list, .ai-item-acts)")) fails.push("Progress still shows the board's rows to answer");
    document.querySelector(".ai-screen .ai-back")?.click();
    if (!(await G.until(() => document.querySelector(".ai-screen .ai-chat .msg.try"), 2000))) fails.push(`back from "${name}" didn't return to the chat`);
    return fails;
  };
  const fails = [];
  for (const name of ["Progress", "Agents & terminals", "Devices", "Friction"]) fails.push(...(await screen(name)));
  // The strip's "Daily driver NN%" (only with powos-progress installed) opens Progress.
  const dd = [...document.querySelectorAll(".ai-screen .ai-strip-seg")].find((b) => /Daily driver/.test(b.textContent));
  if (dd) {
    dd.click();
    if (!(await G.until(() => titled("Progress"), 2000))) fails.push("the strip's progress didn't open Progress");
    document.querySelector(".ai-screen .ai-back")?.click();
  }
  return fails;
}

/** In the page: messages drawn, then the chat scrolled to its top: more drawn (older ones load on scroll-up). */
async function aiChatOlder() {
  const G = window.__gw;
  const pane = document.querySelector(".ai-screen .ai-chat");
  const count = () => pane.querySelectorAll(".msg").length;
  const fade = () => Math.round(parseFloat(getComputedStyle(pane).getPropertyValue("--ai-fade")) || 0);
  const before = count();
  const rest = fade();
  pane.scrollTop = -pane.scrollHeight;
  await G.until(() => count() > before, 3000);
  await G.frames(2);
  return [before, count(), rest, fade()];
}

/**
 * In the page: one turn in which the manager sends a ```present card ("Plan") and then a ```choices card ("Go ahead?"),
 * as manager.py emits them (each tool call, then its block); the two cards' tops, null for one not drawn.
 */
async function aiChatOrder() {
  const G = window.__gw;
  const S = await G.mod("./state.ts");
  const plan = { title: "Plan", format: "md", body: "1. Do the thing\n2. Check it" };
  const ask = { question: "Go ahead?", options: ["yes", "no"], multi: false, other: true };
  const tool = (name) => ({ kind: "tool", name: `mcp__comms__${name}`, hint: "", ok: true, text: "", out: "" });
  S.chat.value = {
    busy: false,
    items: [
      { kind: "user", text: "plan it" },
      tool("present"),
      { kind: "assistant", text: "```present\n" + JSON.stringify(plan) + "\n```" },
      tool("present_choices"),
      { kind: "assistant", text: "```choices\n" + JSON.stringify(ask) + "\n```" },
    ],
  };
  const cards = () => {
    const card = [...document.querySelectorAll(".ai-screen .ai-chat .present")].find((e) => e.textContent.includes("Plan"));
    const choice = [...document.querySelectorAll(".ai-screen .ai-chat .choice")].find((e) => e.textContent.includes("Go ahead?"));
    return card && choice ? [card, choice] : null;
  };
  await G.until(cards, 3000);
  await G.frames(2);
  const got = cards();
  return got ? got.map((e) => Math.round(e.getBoundingClientRect().top)) : null;
}

/** The manager's cards of one turn in the order sent (friction f346: the choices showed above the document). */
async function aiChatOrderFails(page, size) {
  const tops = await page.evaluate(aiChatOrder);
  await page.screenshot({ path: `/cache/ai-page-${size}-order.png` });
  if (!tops) return [`${size}: the "Plan" card and the "Go ahead?" choices sent in one turn didn't both render`];
  return tops[0] < tops[1] ? [] : [`${size}: the "Go ahead?" choices (top ${tops[1]}) show above the "Plan" card sent before them (top ${tops[0]})`];
}

/** In the page: the bridge as it was. */
async function aiChatRestore() {
  const { powos } = await window.__gw.mod("./bridge.ts");
  [powos.ai.verdict, powos.agents.message] = window.__nyRestore;
}

/**
 * In the page, unfolded (the user, 2026-10-31 13:29: three panes, "not a stretched chat"): the nav with Chat / Agents /
 * Progress / Devices (Chat marked), the chat in the middle pane, the right column's "Try this" with the newest try
 * message's works / still broken; no strip (the panes say it).
 */
function aiPanesFails() {
  const scr = document.querySelector(".ai-screen");
  const fails = [];
  const nav = [...scr.querySelectorAll(".ai-nav .ai-nav-name")].map((e) => e.textContent.trim()).join(" / ");
  if (nav !== "Chat / Agents / Progress / Devices") fails.push(`the nav lists "${nav}", not Chat / Agents / Progress / Devices`);
  if (!scr.querySelector(".ai-nav .ai-nav-item.on")?.textContent.includes("Chat")) fails.push("the nav doesn't mark Chat as open");
  if (!scr.querySelector(".ai-mid .ai-chat .msg.try")) fails.push("the middle pane has no chat");
  const heads = [...scr.querySelectorAll(".ai-ctx .ai-ctx-head")].map((e) => e.textContent.trim());
  if (!heads.includes("Try this")) fails.push(`the right column has no "Try this" (has ${heads.join(", ") || "nothing"})`);
  const acts = [...scr.querySelectorAll(".ai-ctx .ai-ctx-try .try-acts")].length;
  if (acts !== 2) fails.push(`"Try this" offers ${acts} lines with buttons, not the newest message's 2`);
  if (scr.querySelector(".ai-strip")) fails.push("the strip still shows over the panes");
  return fails;
}

/**
 * In the page, unfolded: the name once, in the nav (UF-5); every nav label whole (UF-6); no page slab, each pane on the
 * widgets' compositor blur (the user, 14:17: "There's actually no transparency on the AI page").
 */
function aiPanesGlassFails() {
  const scr = document.querySelector(".ai-screen");
  const fails = [];
  if (scr.querySelector(".ai-mid .ai-top .ai-title")) fails.push(`the middle pane's header repeats "PowOS AI" (the nav has it)`);
  const cut = [...scr.querySelectorAll(".ai-nav .ai-nav-name")].filter((e) => e.scrollWidth > e.clientWidth + 1).map((e) => e.textContent.trim());
  if (cut.length) fails.push(`the nav cuts ${cut.join(", ")}`);
  const fill = getComputedStyle(scr).backgroundColor;
  if (!/^rgba\(0, 0, 0, 0\)$|^transparent$/.test(fill)) fails.push(`the page paints ${fill} over the wallpaper (the panes are the glass, not a page slab)`);
  const want = getComputedStyle(document.documentElement).getPropertyValue("--widget-blur-native").trim();
  const off = [".ai-nav", ".ai-mid", ".ai-ctx"].filter((q) => getComputedStyle(scr.querySelector(q)).getPropertyValue("--glass-blur-native").trim() !== want);
  if (off.length) fails.push(`${off.join(", ")} not on the widgets' blur (${want})`);
  return fails;
}

/** The chat page before any answer: no old boxes, reading width, the strip, older messages on scroll-up. */
async function aiChatLayout(page, size) {
  const fails = [];
  const boxes = await page.evaluate(aiChatBoxes);
  if (boxes.length) fails.push(`${size}: the chat page still shows ${boxes.join(", ")}`);
  await page.screenshot({ path: `/cache/ai-page-${size}-chat.png` });
  const width = await page.evaluate(() => Math.round(document.querySelector(".ai-screen .ai-chat").getBoundingClientRect().width));
  if (width > 700) fails.push(`${size}: the chat is ${width} px wide, not centred at reading width`);
  if (size === "unfolded") fails.push(...[...(await page.evaluate(aiPanesFails)), ...(await page.evaluate(aiPanesGlassFails))].map((f) => `${size}: ${f}`));
  else {
    const strip = await page.evaluate(() => document.querySelector(".ai-screen .ai-strip")?.textContent ?? "");
    // "N working · Daily driver NN% · N to try": the try count is the chat's unanswered things to try; the daily driver
    // only from powos-progress (not installed here); never a task's title, never the board's waiting count.
    if (!/(^|·)2 to try$/.test(strip.trim()) || /everything on the phone|need/.test(strip)) fails.push(`${size}: the strip at the chat's top says "${strip}", not "2 to try"`);
  }
  const [before, after, rest, up] = await page.evaluate(aiChatOlder);
  if (!(after > before)) fails.push(`${size}: scrolling up loaded no older messages (${before} -> ${after})`);
  if (rest !== 0 || up < 40) fails.push(`${size}: the chat's foot fade is ${rest} px at the newest and ${up} px scrolled up (want 0, then ~48)`);
  await page.screenshot({ path: `/cache/ai-page-${size}-scrolled.png` });
  return fails;
}

/** The try message's buttons and what "still broken" + "x" recorded (aiChatBroken's result). */
function aiChatAnswerFails(r, size) {
  const fails = [];
  if (r.acts !== "works / still broken") fails.push(`${size}: the thing to try offers ${r.acts || "nothing"}, not works / still broken`);
  if (r.doActs !== "done / can't / problem") fails.push(`${size}: the thing to do offers ${r.doActs || "nothing"}, not done / can't / problem`);
  return [...fails, ...aiChatRecordFails(r, size)];
}

/** What "still broken" + "x" recorded: the user FAIL check, the manager's mail, the item's answer. */
function aiChatRecordFails(r, size) {
  const fails = [];
  const v = r.got && nyCall(r.got, "verdict");
  if (!(v && v[1] === `${AI_CHAT_TRY}-${size}` && v[2] === false && v[3] === "still broken: x")) fails.push(`${size}: still broken recorded no user FAIL check with the words (${JSON.stringify(r.got)})`);
  if (!(r.got && nyMailOk(nyCall(r.got, "message"), `${AI_CHAT_TRY}-${size}`))) fails.push(`${size}: still broken mailed the manager nothing naming the task`);
  if (!/still broken: "x"/.test(r.said ?? "")) fails.push(`${size}: the item doesn't say what was answered ("${r.said}")`);
  return fails;
}

/** The chat's checks at one size: no old boxes, the try message answered, ⋯'s screens, older on scroll-up. */
async function aiChatAt(page, size) {
  if (!(await page.evaluate(aiChatSetup, [120, `-${size}-a`]))) return [`${size}: the manager's things-to-try message didn't render`];
  const fails = await aiChatLayout(page, size);
  await page.evaluate(aiChatSetup, [3, `-${size}`]);
  fails.push(...aiChatAnswerFails(await page.evaluate(aiChatBroken), size));
  await page.screenshot({ path: `/cache/ai-page-${size}-answered.png` });
  await page.evaluate(() => document.querySelector(".ai-screen .ai-more")?.click());
  await page.screenshot({ path: `/cache/ai-page-${size}-menu.png` });
  await page.evaluate(() => document.querySelector(".ai-screen .ai-menu-scrim")?.click());
  fails.push(...(await page.evaluate(aiChatMenu)).map((f) => `${size}: ${f}`));
  fails.push(...(await aiChatOrderFails(page, size)));
  await page.evaluate(aiChatRestore);
  return fails;
}

/**
 * The AI page is one chat (the user, 2026-10-31: "a bunch of different boxes ... stacked on top of each other"): folded
 * and unfolded no board boxes, no at-work list, no units; the manager's things to try (```try) render as its message
 * with works / still broken (done / can't on a thing to do), "still broken" + a reply records the user FAIL check and
 * mails the manager; ⋯ opens Progress / Agents & terminals / Devices, each with back; scrolling up loads older messages;
 * a ```present card and the ```choices sent after it in one turn show in that order.
 * Renders: /cache/ai-page-<size>-*.png.
 */
async function aiChatCheck(page) {
  const fails = await aiChatAt(page, "folded");
  await page.setViewport({ width: 821, height: 883 });
  await page.evaluate(() => window.__gw.until(() => innerWidth === 821));
  fails.push(...(await aiChatAt(page, "unfolded")));
  return fails;
}

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
 * In the page, edit mode (the user, 2026-10-30: "The search bar turns weird"): the foot's search bar keeps its size,
 * width and glass (no grid tile in its place), the edit bar sits below it, the dock stays in view; a side dock's column
 * keeps its top (under the status bar). Bottom dock and right dock, folded and unfolded.
 */
async function editSearchCheck() {
  const S = await window.__gw.mod("./state.ts");
  const fails = [];
  for (const place of ["bottom", "right"]) fails.push(...(await window.__es.at(S, place)));
  S.editing.value = false;
  S.dockTry.value = "";
  return fails;
}

/** editSearchCheck's page helpers: the foot's pill, the dock, and one dock placement's edit mode in and its findings. */
const editSearchHelpers = `window.__es = {
  shown: (el) => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility === "visible",
  pill: () => document.querySelector(".home > .bar .bar-pill"),
  dock: () => document.querySelector(".home > .dock:not(.dock-tray)"),
  box: (r) => \`\${Math.round(r.left)}+\${Math.round(r.width)}x\${Math.round(r.height)}\`,
  // The pill as it was, as it is: same box (left, width, height) and glass; the edit bar below it.
  pillKept: (at, was, glass) => {
    const E = window.__es, el = E.pill();
    if (!E.shown(el)) return [\`\${at}: the foot's search bar is hidden\`];
    const now = el.getBoundingClientRect(), sheet = document.querySelector(".home > .edit-sheet").getBoundingClientRect();
    const out = [];
    if (E.box(now) !== E.box(was)) out.push(\`\${at}: the search bar changed from \${E.box(was)} to \${E.box(now)}\`);
    if (getComputedStyle(el).background !== glass) out.push(\`\${at}: the search bar's glass changed\`);
    if (sheet.top < now.bottom - 1) out.push(\`\${at}: the edit bar (top \${Math.round(sheet.top)}) isn't below the search bar (bottom \${Math.round(now.bottom)})\`);
    return out;
  },
  at: async (S, place) => {
    const E = window.__es, at = \`edit mode, dock \${place}\`;
    S.dockTry.value = place;
    S.editing.value = false;
    await window.__gw.settled(() => E.shown(E.pill()) && !document.querySelector(".home.editing"));
    const was = E.pill().getBoundingClientRect(), glass = getComputedStyle(E.pill()).background, dockTop = E.dock()?.getBoundingClientRect().top;
    S.editing.value = true;
    await window.__gw.settled(() => document.querySelector(".home.editing > .edit-sheet"));
    await new Promise((ok) => setTimeout(ok, 250)); // the row's 180 ms rise
    const out = E.pillKept(at, was, glass);
    if (E.shown(document.querySelector('.home-tile[data-key="panel:search"]'))) out.push(\`\${at}: the search bar turned into a grid tile\`);
    if (!E.shown(document.querySelector(".home > :is(.dock, .dock-tray) .app"))) out.push(\`\${at}: the dock isn't in view\`);
    const top = E.dock()?.getBoundingClientRect().top;
    if (place === "right" && Math.abs(top - dockTop) > 1) out.push(\`\${at}: the dock column moved from \${Math.round(dockTop)} to \${Math.round(top)} (over the status bar)\`);
    return out;
  },
}`;

/** In the page: the search widget put on the grid (the widget picker's way), on the page in view, in its lowest free
 *  row, the middle five columns wide. Its home item, once placed. */
async function placeSearchWidget() {
  const S = await window.__gw.mod("./state.ts");
  const G = await window.__gw.mod("./ui/grid.tsx");
  const R = await window.__gw.mod("./ui/recentwidget.tsx");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const n = S.pages.value[S.page.value] ?? 1;
  const spot = R.recentsSpot(n, G.geometry.value.rows || 6);
  if (!spot) return null;
  const cols = S.home.value.columns, w = cols > 6 ? 5 : cols;
  await powos.home.addPanel("search", n, { ...spot.cell, x: Math.floor((cols - w) / 2), w });
  const placed = () => S.home.value.items.find((i) => i.kind === "panel" && i.name === "search");
  await window.__gw.until(placed);
  return placed() ?? null;
}

/** In the page: the first free 1x1 cell of the page in view, worked out here (not by grid.tsx placeNew), and a tap. */
const addAppHelpers = `window.__aa = {
  firstFree: (S, G, W) => {
    const n = S.pages.value[S.page.value] ?? 1;
    const items = S.home.value.items.filter((i) => i.page === n && i.cell);
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
  // Put on the grid (the widget picker's way).
  if (!(await window.__sp.placeSearchWidget())) return [...fails, "no room on the page for the search widget"];
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
  const fails = document.querySelector('.home-tile[data-key="panel:search"]') ? ["edit mode after the drop under the dock: the pill is a grid tile again"] : [];
  if (getComputedStyle(bar).visibility !== "visible" || p.top < d.bottom - 1)
    fails.push(`edit mode after the drop under the dock: the pill isn't below the dock (pill top ${p.top}, dock bottom ${d.bottom})`);
  return fails;
}

/**
 * The user's own move (2026-10-23, 5th report): edit mode, the search widget's tile carried down onto the dock and let
 * go - the pill is in the foot under the dock (folded), back in the bar (unfolded), and the drawer still has it.
 */
async function searchToDock() {
  const S = await window.__gw.mod("./state.ts");
  const G = await window.__gw.mod("./ui/grid.tsx");
  const W = await window.__gw.mod("./ui/searchwidget.tsx");
  const wide = !!document.querySelector(".home.wide");
  W.footBelow.value = "";
  const item = await window.__sp.placeSearchWidget();
  S.editing.value = true;
  // Folded the dock's row (under the dock); wide the one bar's middle (no "under" there).
  const foot = wide ? ".home > .edit-sheet" : ".home > .dock:not(.dock-tray)";
  await window.__gw.settled(() => document.querySelector('.home-tile[data-key="panel:search"]') && document.querySelector(foot));
  const tile = document.querySelector('.home-tile[data-key="panel:search"]')?.getBoundingClientRect();
  const to = document.querySelector(foot)?.getBoundingClientRect();
  if (!tile || !item || !to) return ["edit mode: no search tile or foot to drag it to"];
  const at = (type, x, y) => new PointerEvent(type, { pointerId: 11, pointerType: "touch", clientX: x, clientY: y, bubbles: true, isPrimary: true });
  G.startCarry({ item }, at("pointerdown", tile.left + 20, tile.top + 10), { x: 20, y: 10 });
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
    // Each event carries its own time (timeStamp = start + the step's ms): the gesture's real timing, however late the
    // page gets to run the handlers (GATE_THROTTLE, a loaded host).
    const t0 = performance.now();
    handlers.onTouchStart({ touches: [{ clientX: x0, clientY: 300 }], target, timeStamp: t0 });
    let t = 0;
    for (const [dx, ms] of steps) {
      await sleep(ms - t);
      t = ms;
      handlers.onTouchMove({ touches: [{ clientX: x0 + dx, clientY: 300 + (dyEnd * dx) / steps[steps.length - 1][0] }], cancelable: false, timeStamp: t0 + ms });
    }
    handlers.onTouchEnd({ changedTouches: [{ clientX: x0 + steps[steps.length - 1][0], clientY: 300 + dyEnd }], timeStamp: t0 + t + 5 });
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
    // DB1: dragged far up, the bar stops at the status bar's bottom (--inset-top), never above it.
    const r2 = el.querySelector(".webwindow-title").getBoundingClientRect();
    await drag(el.querySelector(".webwindow-title"), [r2.left + 60, r2.top + 18], [r2.left + 60, r2.top - 400]);
    const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--inset-top")) || 0;
    const barTop = el.querySelector(".webwindow-title").getBoundingClientRect().top;
    if (Math.abs(barTop - inset) > 1) fails.push(`dragged up past the status bar: the bar's top is at ${barTop}, want ${inset} (DB1)`);
    const b = el.querySelector(".webwindow-body").getBoundingClientRect();
    await drag(el.querySelector(".webwindow-body"), [b.left + 320, b.top + 80], [b.left + 20, b.top + 80]);
    fails.push(...turned("a sideways swipe on a web window's body"));
    // FL4: maximised, a swipe on the body is the app's only; full screen (Linux), home's pulls keep only the edge strips.
    W.toggleMaximise(901);
    await window.__gw.settled();
    const mb = el.querySelector(".webwindow-body").getBoundingClientRect();
    await drag(el.querySelector(".webwindow-body"), [mb.left + mb.width * 0.8, mb.top + 200], [mb.left + mb.width * 0.2, mb.top + 200]);
    await drag(el.querySelector(".webwindow-body"), [mb.left + 200, mb.top + 300], [mb.left + 200, mb.top + 40]);
    fails.push(...turned("a swipe on a maximised web window's body"));
    const fr = (await window.__gw.mod("./ui/home.tsx")).fullScreenAppRegion();
    if (!(fr.top >= 24 && fr.top + fr.height <= innerHeight - 24)) fails.push(`full-screen Linux window: its claimed region ${JSON.stringify(fr)} leaves no edge strips to home`);
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
 * In the page: RS1 (the user, 10-30: "I try to resize windows, it's just lagging after, eventually it's catching up") -
 * a corner drag, one move per frame for 30 frames: every frame's "w.f" has the new body (the frame follows the finger),
 * but the app's size (the host's real resize: a relayout, a new buffer) changes at most once per 2 frames, and on
 * release the last "w.f" says the drag ended with the body's final size.
 */
async function webWindowResizeCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const fails = [];
  try {
    W.webWins.value = [{ id: 903, key: "a:gate.resize", label: "Resize", page: S.pages.value[0], x: 200, y: 160, w: 360, h: 300, live: true }];
    await window.__gw.settled();
    const edge = document.querySelector('.webwindow[data-wwid="903"] .ww-edge-se');
    if (!edge) return ["resize: no se edge on the web window"];
    const r = edge.getBoundingClientRect();
    const [x0, y0] = [r.left + r.width / 2, r.top + r.height / 2];
    const pe = (type, k) => edge.dispatchEvent(new PointerEvent(type, { pointerId: 41, pointerType: "touch", isPrimary: true, clientX: x0 + k * 6, clientY: y0 + k * 4, bubbles: true }));
    const frame = () => new Promise((ok) => requestAnimationFrame(ok));
    const from = window.__ww.sent.length;
    const FRAMES = 30;
    pe("pointerdown", 0);
    for (let k = 1; k <= FRAMES; k++) (pe("pointermove", k), await frame());
    pe("pointerup", FRAMES);
    await frame(), await frame(), await frame();
    // Each line: "w.f <id> <dpr> <n> <entry>..."; an entry is 24 words, its last four "<resizing> <app w> <app h> <fill>".
    const ours = (t) => [...Array(Math.floor(t.length / 24)).keys()].map((i) => t.slice(i * 24, i * 24 + 24)).find((e) => e[0] === "903");
    const mine = window.__ww.sent.slice(from).map((l) => ours(l.split(" ").slice(4))).filter(Boolean);
    const judge = (end) => {
      const during = mine.filter((e) => e[20] === "1");
      const sizes = new Set(during.map((e) => `${e[21]}x${e[22]}`));
      const bodies = new Set(during.map((e) => `${e[7]}x${e[8]}`));
      const last = mine.at(-1) ?? [];
      return [
        bodies.size < FRAMES / 2 && `RS1: a 30-frame corner drag gave only ${bodies.size} body sizes (the frame must follow the finger each frame)`,
        sizes.size * 2 > during.length + 1 && `RS1: ${sizes.size} app resizes for ${during.length} drag frames (want <= 1 per 2 frames)`,
        last[20] !== "0" && `RS1: after release the last w.f still says resizing (${last.slice(20).join(" ")}): no final resize`,
        end?.w !== 360 + FRAMES * 6 && `RS1: the corner drag left the window ${end?.w} wide (want ${360 + FRAMES * 6})`,
        !/^[0-9a-f]{6}$/.test(last[23] ?? "") && `RS1: the fill colour in w.f is "${last[23]}" (want rrggbb)`,
      ].filter(Boolean);
    };
    fails.push(...judge(W.webWins.value.find((w) => w.id === 903)));
    // RB1: a corner drag resizes; the bar stays 36 px.
    const f903 = document.querySelector('.webwindow[data-wwid="903"]');
    const b903 = f903?.querySelector(".webwindow-body");
    const bar = b903 ? b903.getBoundingClientRect().top - f903.getBoundingClientRect().top : NaN;
    if (Math.abs(bar - 36) > 0.5) fails.push(`RB1: after a corner drag the bar is ${bar} px (want 36, fixed)`);
  } finally {
    W.webWins.value = [];
  }
  return fails;
}

/**
 * In the page: W-IN1 (the user, 10-31: "Try to interact with one of the floating windows I still activate the launcher
 * or the search or the AI page or the notifications"; "Seems like the window resized, but like the touch handlers ...
 * didn't realize"). Two windows tiled, the divider moved so the left one grows (a resize with no finger on it), and a
 * window resized bigger: within a few frames the regions home sends the host's shade/pull (the mock records them)
 * hold a point in each newly grown part, and a drag up, down and sideways starting there (body and bar) opens no
 * launcher, shade or page swipe.
 */
async function webWindowRegionsTiled() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const frames = async (n) => { for (let i = 0; i < n; i++) await new Promise((ok) => requestAnimationFrame(ok)); };
  const covered = (x, y) => (globalThis.__homePullRegions ?? []).some((r) => x >= r.left && x <= r.left + r.width && y >= r.top && y <= r.top + r.height);
  const was = S.page.value;
  try {
    S.page.value = 0;
    await window.__gw.settled();
    const p = S.pages.value[0];
    W.webWins.value = [
      { id: 921, key: "a:gate.r1", label: "R1", page: p, x: 60, y: 140, w: 200, h: 200, live: true },
      { id: 922, key: "a:gate.r2", label: "R2", page: p, x: 300, y: 140, w: 200, h: 200, live: true },
    ];
    await window.__gw.settled();
    W.tileWindows(p, [921, 922]);
    await (window.__gw.settled(), frames(3));
    const el = () => document.querySelector('.webwindow[data-wwid="921"]').getBoundingClientRect();
    const before = el();
    // The divider let go further right: the left window grows (tilings + relayout, no finger on the window).
    W.tilings.value = { ...W.tilings.value, [p]: { ...W.tilings.value[p], rx: 0.7 } };
    W.webWins.value = [...W.webWins.value];
    await (window.__gw.settled(), frames(3));
    const after = el();
    const pt = [(before.right + after.right) / 2, after.top + after.height / 2];
    if (after.right > before.right + 20 && !covered(...pt)) return [`W-IN1: after the divider grew window 921 (${before.right} -> ${after.right}), ${pt} isn't in the host's excluded regions`];
    return [];
  } finally {
    W.webWins.value = [];
    W.tilings.value = {};
    S.page.value = was;
  }
}

/**
 * CL1 (10-31 03:05, the switcher's "Clear all": "it didn't really close the comb window properly" / "like it's missing
 * the title bar"): three windows, two of them tiled - the host's "webwindows.closed" for each leaves no .webwindow
 * within 1 s; and a window the host's "webwindows.alive" doesn't list (no host window) shows its PowOS bar with a close
 * button even when it draws its own frame - never a bare picture.
 */
async function webWindowClearAll() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const was = S.page.value;
  const fails = [];
  try {
    S.page.value = 0;
    await window.__gw.settled();
    const p = S.pages.value[0];
    W.webWins.value = [
      { id: 941, key: "a:gate.c1", label: "C1", page: p, x: 60, y: 140, w: 200, h: 200, live: true },
      { id: 942, key: "a:gate.c2", label: "C2", page: p, x: 300, y: 140, w: 200, h: 200, live: true },
      { id: 943, key: "a:gate.c3", label: "C3", page: p, x: 120, y: 400, w: 220, h: 200, live: true, ownFrame: true },
    ];
    await window.__gw.settled();
    W.tileWindows(p, [941, 942]);
    await window.__gw.settled();
    if (document.querySelectorAll(".webwindow[data-wwid]").length < 3) fails.push("CL1: the three windows never showed");
    for (const id of [941, 942, 943]) window.__mockEvents.emit("webwindows.closed", id);
    await sleep(1000);
    const left = [...document.querySelectorAll(".webwindow[data-wwid]")].map((e) => e.dataset.wwid);
    if (left.length) fails.push(`CL1: after the host closed all three, .webwindow left: ${left.join(", ")}`);
    window.__mockEvents.emit("webwindows.alive", [950]);
    W.webWins.value = [{ id: 951, key: "a:gate.ghost", label: "Ghost", page: p, x: 80, y: 160, w: 260, h: 220, live: true, ownFrame: true }];
    await window.__gw.settled();
    if (!document.querySelector('.webwindow[data-wwid="951"] .webwindow-title .ww-close')) fails.push("CL1: a window the host doesn't list (own frame) has no PowOS bar with a close button");
    return fails;
  } finally {
    W.webWins.value = [];
    W.tilings.value = {};
    W.hostIds.value = null;
    S.page.value = was;
  }
}

/**
 * RL1 (10-31 14:19, "my widgets A window behind my widgets."): a page reload drops the page's window list while the
 * host keeps the windows. The mock host's "webwindows.list" returns two; the page's rebuild gives two .webwindow with
 * their bars at the host's rects, each the top element at its centre (over the widgets), and "w.f" geometry naming
 * them goes out again within 500 ms (RL0: geometry resumes after a reload).
 */
async function webWindowReloadCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const was = S.page.value;
  const had = powos.webwindows;
  const fails = [];
  // One rebuilt window: there, with its bar, at the host's frame, the top element at its centre.
  const judge = (h) => {
    const el = document.querySelector(`.webwindow[data-wwid="${h.id}"]`);
    if (!el) return [`RL1: no .webwindow for host window ${h.id}`];
    const r = el.getBoundingClientRect();
    const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    return [
      !el.querySelector(".webwindow-title") && `RL1: window ${h.id} has no bar`,
      (Math.abs(r.left - h.frame.left) > 2 || Math.abs(r.top - h.frame.top) > 2) && `RL1: window ${h.id} at ${Math.round(r.left)},${Math.round(r.top)}, host had ${h.frame.left},${h.frame.top}`,
      top?.closest(".webwindow") !== el && `RL1: window ${h.id}'s centre shows ${top?.className || top?.tagName}, not the window`,
    ].filter(Boolean);
  };
  // A "w.f" naming both windows (ids no other check uses; __ww.sent keeps the last 120) within [ms] of [t0].
  const geometrySent = async (t0, ms) => {
    const named = () => window.__ww.sent.slice(-20).some((l) => / 961 /.test(l) && / 962 /.test(l));
    while (performance.now() - t0 < ms && !named()) await sleep(20);
    return named();
  };
  try {
    S.page.value = 0;
    await window.__gw.settled();
    W.webWins.value = [];
    const host = [
      { id: 961, key: "a:gate.r1", label: "R1", state: "floating", live: true, frame: { left: 80, top: 160, width: 300, height: 240 }, body: { left: 80, top: 196, width: 300, height: 204 } },
      { id: 962, key: "a:gate.r2", label: "R2", state: "floating", live: true, frame: { left: 420, top: 200, width: 320, height: 260 }, body: { left: 420, top: 236, width: 320, height: 224 } },
    ];
    powos.webwindows = { ...had, list: () => Promise.resolve(host) };
    const t0 = performance.now();
    const n = await W.rebuildFromHost();
    await window.__gw.settled();
    if (n !== 2) fails.push(`RL1: rebuild added ${n} windows, not 2`);
    fails.push(...host.flatMap(judge));
    if (!(await geometrySent(t0, 500))) fails.push("RL0: no w.f naming both rebuilt windows within 500 ms");
    return fails;
  } finally {
    powos.webwindows = had;
    W.webWins.value = [];
    W.hostIds.value = null;
    S.page.value = was;
  }
}

/** W-IN1, a floating window resized bigger: its grown corner is excluded, and drags from it (body, bar) stay the window's. */
async function webWindowRegionsResized() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const G = await window.__gw.mod("./ui/gesture.ts");
  const frames = async (n) => { for (let i = 0; i < n; i++) await new Promise((ok) => requestAnimationFrame(ok)); };
  const covered = (x, y) => (globalThis.__homePullRegions ?? []).some((r) => x >= r.left && x <= r.left + r.width && y >= r.top && y <= r.top + r.height);
  const pulled = () => S.drawer.value > 0 || G.drawerDrag.value != null || S.notif.value || G.notifDrag.value != null || S.page.value !== 0;
  const drag = async (el, a, d) => {
    const send = (kind, k) => {
      const [x, y] = [a[0] + d[0] * k, a[1] + d[1] * k];
      el.dispatchEvent(new PointerEvent(`pointer${kind}`, { pointerId: 13, pointerType: "touch", isPrimary: true, clientX: x, clientY: y, bubbles: true }));
      const t = [new Touch({ identifier: 13, target: el, clientX: x, clientY: y })];
      const name = { down: "Start", move: "Move", up: "End" }[kind];
      const init = { touches: kind === "up" ? [] : t, changedTouches: t, bubbles: true, cancelable: true };
      for (const type of [`touch${name.toLowerCase()}`, `Touch${name}`]) el.dispatchEvent(new TouchEvent(type, init));
    };
    let seen = (send("down", 0), false);
    for (let i = 1; i <= 6; i++) (send("move", i / 6), await new Promise((ok) => setTimeout(ok, 8)), (seen ||= pulled()));
    await (send("up", 1), window.__gw.settled());
    return seen || pulled();
  };
  const was = S.page.value;
  const fails = [];
  try {
    S.page.value = 0;
    const home = { id: 923, key: "a:gate.r3", label: "R3", page: S.pages.value[0], x: 80, y: 160, w: 240, h: 200, live: true };
    W.webWins.value = [home];
    await (window.__gw.settled(), frames(3));
    W.webWins.value = [{ ...home, w: 420, h: 360 }];
    await (window.__gw.settled(), frames(3));
    const sel = '.webwindow[data-wwid="923"]';
    const f = document.querySelector(sel).getBoundingClientRect();
    const grown = [f.right - 30, f.bottom - 30];
    if (!covered(...grown)) fails.push(`W-IN1: window 923 resized to ${f.width}x${f.height}: its grown corner ${grown} isn't in the host's excluded regions`);
    const [body, bar] = [document.querySelector(`${sel} .webwindow-body`), document.querySelector(`${sel} .webwindow-title`)];
    const b = bar.getBoundingClientRect();
    const onBar = [b.left + 40, b.top + 12];
    const cases = [["up on the body", body, grown, [0, -260]], ["down on the body", body, grown, [0, 260]], ["sideways on the body", body, grown, [-300, 0]], ["down on the bar", bar, onBar, [0, 260]], ["sideways on the bar", bar, onBar, [-300, 0]]];
    for (const [label, node, a, d] of cases) {
      if (await drag(node, a, d)) fails.push(`W-IN1: a drag ${label} of a window opened the launcher, the shade or turned the page`);
      W.webWins.value = [{ ...home, w: 420, h: 360 }];
      await window.__gw.settled();
    }
  } finally {
    W.webWins.value = [];
    S.page.value = was;
  }
  return fails;
}

/**
 * In the page: RZ5 (the user, 10-31: "When I try to resize an application ... It sometimes activates the launcher or the
 * notification panel"). A fast vertical drag up from a bottom-corner zone, and one down from it, resize the window and
 * open neither the launcher nor the shade (pull and drawer state stay closed, the page stays); a zone never reaches
 * into the bottom gesture strip. RZ6: the grips show on activation and are gone after GRIPS_MS.
 */
async function webWindowZoneKeepsHome() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const G = await window.__gw.mod("./ui/gesture.ts");
  const [sel, sleep, win] = ['.webwindow[data-wwid="905"]', (ms) => new Promise((ok) => setTimeout(ok, ms)), () => W.webWins.value.find((w) => w.id === 905)];
  // One finger [a] -> [b] fast, pointer AND touch events (as webWindowCheck's drag): whether home pulled meanwhile.
  const drag = async (el, a, b) => {
    const send = (kind, k) => {
      const [x, y] = [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k];
      el.dispatchEvent(new PointerEvent(`pointer${kind}`, { pointerId: 12, pointerType: "touch", isPrimary: true, clientX: x, clientY: y, bubbles: true }));
      const t = [new Touch({ identifier: 12, target: el, clientX: x, clientY: y })];
      const name = { down: "Start", move: "Move", up: "End" }[kind];
      const init = { touches: kind === "up" ? [] : t, changedTouches: t, bubbles: true, cancelable: true };
      for (const type of [`touch${name.toLowerCase()}`, `Touch${name}`]) el.dispatchEvent(new TouchEvent(type, init));
    };
    const pulled = () => S.drawer.value > 0 || G.drawerDrag.value != null || S.notif.value || G.notifDrag.value != null;
    let seen = (send("down", 0), false);
    for (let i = 1; i <= 6; i++) (send("move", i / 6), await sleep(8), (seen ||= pulled()));
    await (send("up", 1), window.__gw.settled());
    return seen || pulled();
  };
  // A drag [dy] from 20 px off the bottom-right corner: it resizes, home stays as it was.
  const zoneDrag = async (label, dy) => {
    const f = document.querySelector(sel).getBoundingClientRect();
    const at = [f.right + 20, f.bottom + 20];
    const t = document.elementFromPoint(...at);
    if (!t?.closest?.(".ww-edge")) return [`RZ5: ${at} off the bottom-right corner is ${t?.className} (want a resize zone)`];
    const h0 = win().h;
    const pulled = await drag(t, at, [at[0], at[1] + dy]);
    return [
      win().h === h0 && `RZ5: a fast drag ${label} from the bottom-right zone didn't resize (h ${h0})`,
      pulled && `RZ5: a drag ${label} from a window's corner zone pulled the launcher or the shade`,
      S.page.value !== 0 && `RZ5: a drag ${label} from a window's corner zone turned the page`,
      G.windowGestureActive() && "RZ5: the window's gesture is still active after the finger lifted",
    ].filter(Boolean);
  };
  // The window's bottom 10 px over the gesture strip: its bottom zones are no taller than that.
  const stripKept = async () => {
    const strip = Math.max(24, parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--inset-bottom")) || 0);
    const o = document.querySelector(sel).getBoundingClientRect().top - win().y;
    W.webWins.value = W.webWins.value.map((w) => ({ ...w, h: 240, y: innerHeight - strip - 10 - 240 - o }));
    await window.__gw.settled();
    const se = document.querySelector(`${sel} .ww-edge-se`).getBoundingClientRect();
    return se.bottom > innerHeight - strip + 0.5 ? [`RZ5: the bottom-right zone reaches ${se.bottom} into the gesture strip (from ${innerHeight - strip})`] : [];
  };
  const grips = () => document.querySelector(sel)?.classList.contains("ww-grips");
  const was = S.page.value;
  try {
    S.page.value = 0;
    await window.__gw.settled();
    W.webWins.value = [{ id: 905, key: "a:gate.zone", label: "Zone", page: S.pages.value[0], x: 200, y: Math.max(140, innerHeight - 420), w: 320, h: 240, live: true }];
    await window.__gw.settled();
    const fails = grips() ? [] : ["RZ6: a window just activated shows no grips"];
    fails.push(...(await zoneDrag("up", -320)), ...(await zoneDrag("down", 320)), ...(await stripKept()));
    await sleep(W.GRIPS_MS + 400);
    if (grips() || getComputedStyle(document.querySelector(`${sel} .ww-grip-se`)).opacity !== "0") fails.push(`RZ6: the grips still show ${W.GRIPS_MS + 400} ms after activation`);
    return fails;
  } finally {
    W.webWins.value = [];
    S.page.value = was;
  }
}

/**
 * In the page: RZ1-RZ4 (the user, 10-30: "It's really hard to get hold of the resize bars; we need a better way to
 * resize windows") and WS1 ("the windows don't have a shadow"). Presses found by the DOM's hit test (as a finger's):
 * 20 dp outside the right edge resizes the width only; 30 dp off the bottom-right corner both; on the content 6 dp in
 * from the edge goes to the app (no resize); a lower window's zone under a higher window's content gives way to it.
 * A grab ticks the haptic and shows the size outline; a drag near half the work area snaps to it; the focused window
 * has visible grips and a shadow outside its frame.
 */
async function webWindowGrabCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const vib = navigator.vibrate;
  const g = { S, W, ticks: 0, sel: '.webwindow[data-wwid="904"]', win: () => W.webWins.value.find((w) => w.id === 904) };
  navigator.vibrate = () => (g.ticks++, true);
  try {
    return [...(await window.__grab.grabLooks(g)), ...(await window.__grab.grabZones(g)), ...(await window.__grab.grabContent(g)), ...(await window.__grab.grabSnap(g))];
  } finally {
    navigator.vibrate = vib;
    W.webWins.value = [];
  }
}

/** A finger at ([x], [y]) on whatever the DOM's hit test finds there, moved by ([dx], [dy]): what it hit, and whether the outline showed. */
async function grabPress(g, [x, y], [dx, dy]) {
  const t = document.elementFromPoint(x, y);
  const pe = (type, k) => t.dispatchEvent(new PointerEvent(type, { pointerId: 43, pointerType: "touch", isPrimary: true, clientX: x + k * dx, clientY: y + k * dy, bubbles: true }));
  pe("pointerdown", 0);
  await window.__gw.settled();
  const outline = !!document.querySelector(`${g.sel} .ww-outline`);
  pe("pointermove", 1);
  await window.__gw.settled();
  pe("pointerup", 1);
  await window.__gw.settled();
  return { t, outline };
}

/** One 300x260 window, alone and focused: its frame on screen. */
async function grabReset(g) {
  g.W.webWins.value = [{ id: 904, key: "a:gate.grab", label: "Grab", page: g.S.pages.value[0], x: 120, y: 160, w: 300, h: 260, live: true }];
  await window.__gw.settled();
  return document.querySelector(g.sel).getBoundingClientRect();
}

/** RZ1 + WS1: the focused window's grips show; its shadow is its own element, the frame unmasked. */
async function grabLooks(g) {
  await window.__grab.grabReset(g);
  const grip = document.querySelector(`${g.sel} .ww-grip-se`);
  const sh = document.querySelector(".ww-shadow.focused > div");
  return [
    (!grip || getComputedStyle(grip).opacity === "0") && "RZ1: the focused window shows no bottom-right grip",
    (!sh || getComputedStyle(sh).boxShadow === "none") && "WS1: the focused window has no drop shadow element",
  ].filter(Boolean);
}

/** RZ2 + RZ4: 20 dp outside the right edge - width only, a haptic tick, the outline; 30 dp off the corner - both. */
async function grabZones(g) {
  let f = await window.__grab.grabReset(g);
  const r = await window.__grab.grabPress(g, [f.right + 20, f.top + f.height / 2], [30, 30]);
  const edge = g.win();
  const fails = [
    !r.t.classList.contains("ww-edge") && `RZ2: a press 20 dp outside the right edge hit .${r.t.className} (want a resize zone)`,
    (edge.w !== 330 || edge.h !== 260) && `RZ2: a drag 20 dp outside the right edge left ${edge.w}x${edge.h} (want 330x260: width only)`,
    !r.outline && "RZ4: no live size outline during a resize",
    !g.ticks && "RZ4: no haptic tick on the grab",
    !!document.querySelector(`${g.sel} .ww-outline`) && "RZ4: the size outline stayed after release",
  ];
  f = await window.__grab.grabReset(g);
  await window.__grab.grabPress(g, [f.right + 30, f.bottom + 30], [30, 20]);
  const c = g.win();
  fails.push((c.w !== 330 || c.h !== 280) && `RZ2: a drag 30 dp off the bottom-right corner left ${c.w}x${c.h} (want 330x280: both)`);
  return fails.filter(Boolean);
}

/** RZ2: a press on the content near the edge is the app's; a higher window's content beats a lower one's zone (z). */
async function grabContent(g) {
  const f = await window.__grab.grabReset(g);
  const content = document.elementFromPoint(f.right - 6, f.top + f.height / 2);
  if (!content?.closest(".webwindow-body")) return [`RZ2: a press on the content 6 dp in from the right edge hit .${content?.className} (want the app's body)`];
  await window.__grab.grabPress(g, [f.right - 6, f.top + f.height / 2], [30, 0]);
  const fails = [g.win().w !== 300 && `RZ2: a drag on the content near the edge resized the window to ${g.win().w} (want the app's)`];
  g.W.webWins.value = [...g.W.webWins.value, { id: 905, key: "a:gate.grab2", label: "Over", page: g.S.pages.value[0], x: 424, y: 200, w: 260, h: 200, live: true }];
  await window.__gw.settled();
  const over = document.elementFromPoint(f.right + 20, f.top + 120);
  fails.push(!over?.closest('.webwindow[data-wwid="905"] .webwindow-body') && `RZ2: the lower window's zone took a press on a higher window's content (.${over?.className})`);
  return fails.filter(Boolean);
}

/** RZ4: a drag let go 9 px past half the work area's width snaps to the half. */
async function grabSnap(g) {
  const f = await window.__grab.grabReset(g);
  const a = g.W.tileArea();
  const half = (a.right - a.left - g.W.TILE_GAP) / 2;
  await window.__grab.grabPress(g, [f.right + 16, f.top + f.height / 2], [half - 300 + 9, 0]);
  const w = g.win().w;
  return Math.abs(w - half) > 1 ? [`RZ4: a drag to 9 px past half the work area left the window ${w} wide (want the half's ${Math.round(half)})`] : [];
}

// webWindowGrabCheck's helpers: page functions too (evaluated just before it: page.evaluate sends only that function).
const GRAB_HELPERS = `(window.__grab = { ${[grabPress, grabReset, grabLooks, grabZones, grabContent, grabSnap].map((f) => `${f.name}: ${f}`).join(", ")} }, [])`;

/**
 * In the page, after webWindowCheck: TB4 (the user, 2026-10-30: "If I click on the icon of an open window I should be
 * able to minimize it that way") - a dock tap on an app with web windows (ui/webwindows.tsx dockToggle): in front ->
 * minimised; again -> back in front; under another app's window -> raised; on another page -> home goes there, it in
 * front; several of one app -> cycled; a Linux window the same; the dock's own cell taps through it. Never a launch.
 * Its steps share the helpers DT_HELPERS puts on window.__dtg (page.evaluate sends one function only).
 */
async function dtHelpers() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const D = await window.__gw.mod("./ui/desktops.ts");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const P = S.pages.value;
  const win = (id, key, page = P[0]) => ({ id, key, label: key, page, x: 80 + (id % 10) * 40, y: 120, w: 300, h: 240, live: true });
  const top = () => W.webWins.value.at(-1)?.id;
  const min = (id) => !!W.webWins.value.find((w) => w.id === id)?.minimised;
  const tap = async (key) => (await D.dockTap(key), await window.__gw.frames(2));
  // A step with launches caught (a dock tap on a running window must never launch), all put back after.
  const step = async (body) => {
    const fails = [];
    const launched = [];
    // The mock may have no webwindows bridge (the windows here are the model's only): a stand-in then.
    const ww = powos.webwindows ?? {};
    const was = { page: S.page.value, launch: powos.apps.launch, open: ww.open };
    powos.apps.launch = async (key) => void launched.push(key);
    ww.open = async () => (launched.push("open"), -1);
    try {
      S.page.value = 0;
      await window.__gw.settled();
      await body(fails);
      if (launched.length) fails.push(`TB4: dock taps on running web windows launched [${launched}]`);
    } finally {
      W.webWins.value = [];
      powos.apps.launch = was.launch;
      ww.open = was.open;
      S.page.value = was.page;
    }
    return fails;
  };
  window.__dtg = { S, W, P, win, top, min, tap, step };
  return [];
}

/** TB4: one window - in front minimised, back in front; under another app's window raised. */
async function webDockToggleOne() {
  const { W, win, top, min, tap, step } = window.__dtg;
  return step(async (fails) => {
    W.webWins.value = [win(911, "a:gate.wa")];
    await tap("a:gate.wa");
    if (!min(911) || document.querySelector('.webwindow[data-wwid="911"]')) fails.push("TB4: a dock tap on the app of the window in front didn't minimise it");
    await tap("a:gate.wa");
    if (min(911) || !document.querySelector('.webwindow[data-wwid="911"]')) fails.push("TB4: a second dock tap didn't bring it back in front");
    W.webWins.value = [win(911, "a:gate.wa"), win(912, "a:gate.wb")];
    await tap("a:gate.wa");
    if (top() !== 911 || min(911) || min(912)) fails.push(`TB4: two windows, the icon of the one behind didn't raise it (top=${top()})`);
  });
}

/** TB4: its window on another page - home goes to that page, the window in front. */
async function webDockTogglePage() {
  const { S, W, P, win, top, tap, step } = window.__dtg;
  return step(async (fails) => {
    if (P.length < 2) return void fails.push("TB4: one home page only, the other-page case untested");
    W.webWins.value = [win(911, "a:gate.wa"), win(913, "a:gate.wc", P[1])];
    await tap("a:gate.wc");
    if (S.page.value !== 1 || top() !== 913) fails.push(`TB4: its window on another page: home on ${S.page.value} (want 1), top=${top()}`);
  });
}

/** TB4: several windows of one app cycle (none minimised); a Linux window toggles the same as an Android one. */
async function webDockToggleMany() {
  const { W, win, top, min, tap, step } = window.__dtg;
  return step(async (fails) => {
    W.webWins.value = [win(921, "a:gate.wd"), win(922, "a:gate.wd"), win(923, "a:gate.we")];
    const order = [];
    for (let i = 0; i < 3; i++) (await tap("a:gate.wd"), order.push(top()));
    if (order.join() !== "922,921,922" || W.webWins.value.some((w) => w.minimised)) fails.push(`TB4: two windows of one app: taps brought [${order}] to the front, not [922,921,922]`);
    W.webWins.value = [win(931, "l:gate.linux")];
    await tap("l:gate.linux");
    const first = min(931);
    await tap("l:gate.linux");
    if (!first || min(931)) fails.push(`TB4: a Linux window: tap minimised=${first}, tap again minimised=${min(931)}`);
  });
}

/** TB4: the dock's own cell taps through dockTap: a pinned app's cell, its web window in front, minimises it. */
async function webDockToggleCell() {
  const { W, win, min, step } = window.__dtg;
  return step(async (fails) => {
    const cell = document.querySelector('.dock .app[data-key^="a:"]');
    if (!cell) return void fails.push("TB4: no Android app in the dock to tap");
    W.webWins.value = [win(941, cell.dataset.key)];
    await window.__gw.frames(2);
    const r = cell.getBoundingClientRect();
    const at = { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, bubbles: true, pointerId: 7, button: 0 };
    cell.dispatchEvent(new PointerEvent("pointerdown", at));
    cell.dispatchEvent(new PointerEvent("pointerup", at));
    await window.__gw.until(() => min(941));
    if (!min(941)) fails.push(`TB4: a tap on the dock's ${cell.dataset.key}, its web window in front, didn't minimise it`);
  });
}

/**
 * DB1 (the user, 2026-10-31 03:00: "by default it should launch in Full screen"): a dock tap on an app with no window
 * launches it full screen - a plain launch, no web window opened and no new .webwindow - while the app grid's launch
 * (S.launch) still opens one; a dock tap on an app that has a window still toggles it (TB4's steps above).
 */
async function webDockLaunchFull() {
  const { S, W, tap } = window.__dtg;
  const { powos } = await window.__gw.mod("./bridge.ts");
  const key = [...S.byKey.value.keys()].find((k) => k.startsWith("a:"));
  if (!key) return ["DB1: no Android app to launch"];
  const ww = powos.webwindows ?? (powos.webwindows = {});
  const was = { launch: powos.apps.launch, open: ww.open, enabled: ww.enabled, page: S.page.value };
  const calls = [];
  powos.apps.launch = async (k) => void calls.push(`launch:${k}`);
  ww.open = async () => (calls.push("open"), -1);
  ww.enabled = async () => true;
  const fails = [];
  try {
    W.webWins.value = [];
    S.page.value = 0;
    await window.__gw.settled();
    await tap(key);
    if (calls.join() !== `launch:${key}` || document.querySelector(".webwindow[data-wwid]")) fails.push(`DB1: a dock tap on ${key} with no window gave [${calls}] (want one plain launch, no web window)`);
    calls.length = 0;
    await S.launch(key);
    if (!calls.includes("open")) fails.push(`DB1: the app grid's launch of ${key} no longer tries a web window [${calls}]`);
  } finally {
    W.webWins.value = [];
    Object.assign(ww, { open: was.open, enabled: was.enabled });
    powos.apps.launch = was.launch;
    S.page.value = was.page;
  }
  return fails;
}

/**
 * OI1 (the user, 10-31: "Sometimes it shows it as empty if it's opening two instances of the app"): the same app opened
 * twice within 50 ms (a double tap: the second while the first waits for the host), and again once its window is live
 * -> exactly one .webwindow for that key and ONE "webwindows.open" bridge call. A window with no task bound [BOUND]
 * after its launch (never live) is removed, not left empty.
 */
/** OI1's helpers (each step is evaluated on its own: they go on window.__oneg). */
function ONE_HELPERS() {
  /** OI1's stubbed host: "webwindows.open" answers after 120 ms with a new id each, every call recorded. */
  async function oneInstanceHost() {
    const [S, W, H, B] = await Promise.all(["./state.ts", "./ui/webwindows.tsx", "./hosts/wide.ts", "./bridge.ts"].map((m) => window.__gw.mod(m)));
    const ww = B.powos.webwindows ?? (B.powos.webwindows = {});
    const was = { open: ww.open, enabled: ww.enabled, close: ww.close, bound: W.BOUND.ms, page: S.page.value, wide: H.wideHome.value };
    const calls = [];
    let next = 7700;
    Object.assign(ww, { open: (k) => (calls.push(k), new Promise((ok) => setTimeout(() => ok(next++), 120))), enabled: async () => true, close: async () => true });
    const restore = () => {
      W.webWins.value = [];
      W.BOUND.ms = was.bound;
      Object.assign(ww, { open: was.open, enabled: was.enabled, close: was.close });
      H.wideHome.value = was.wide;
      S.page.value = was.page;
    };
    W.webWins.value = [];
    S.page.value = 0;
    H.wideHome.value = true;
    await window.__gw.settled();
    return { W, calls, restore, p: S.pages.value[0], count: () => document.querySelectorAll(".webwindow[data-wwid]").length };
  }

  /** OI1: two opens 50 ms apart, then one with the window live - one window, one bridge call. */
  async function oneInstanceTwice({ W, calls, p, count }, fails) {
    const key = "a:gate.oneinstance/.Main";
    W.BOUND.ms = 60_000;
    const a = W.openWindow(key, "One", p);
    await new Promise((ok) => setTimeout(ok, 50));
    const [ia, ib] = await Promise.all([a, W.openWindow(key, "One", p)]);
    await window.__gw.settled();
    const n = () => W.webWins.value.filter((w) => w.key === key).length;
    if (ia == null || ia !== ib) fails.push(`OI1: two opens of ${key} 50 ms apart gave windows ${ia} and ${ib} (want one, the same)`);
    if (calls.length !== 1 || n() !== 1 || count() !== 1) fails.push(`OI1: a double open made ${calls.length} "webwindows.open" calls, ${n()} entries, ${count()} .webwindow (want 1, 1, 1)`);
    W.update(ia, { live: true });
    const ic = await W.openWindow(key, "One", p);
    await window.__gw.settled();
    if (ic !== ia || calls.length !== 1 || count() !== 1) fails.push(`OI1: an open with its window live gave ${ic} (had ${ia}), ${calls.length} calls, ${count()} .webwindow (want the same, 1, 1)`);
  }

  /** OI1: a window never bound (no task, never live) is gone [BOUND] after its launch. */
  async function oneInstanceUnbound({ W, p }, fails) {
    W.webWins.value = [];
    W.BOUND.ms = 150;
    const id = await W.openWindow("a:gate.neverbound/.Main", "Never", p);
    await new Promise((ok) => setTimeout(ok, 400));
    await window.__gw.settled();
    if (id == null) return void fails.push("OI1: the never-bound app opened no window at all");
    if (W.webWins.value.some((w) => w.id === id) || document.querySelector(`.webwindow[data-wwid="${id}"]`)) fails.push(`OI1: window ${id} with no task ${W.BOUND.ms} ms after its launch is still there (want removed)`);
  }
  window.__oneg = { oneInstanceHost, oneInstanceTwice, oneInstanceUnbound };
  return [];
}

/** OI2 (15:16 "full screen and then they show desktop mode"): a launcher launch that windows it is ONE window open, no plain (full-screen) launch. */
async function webWindowOneLauncher() {
  const fails = [];
  const h = await window.__oneg.oneInstanceHost();
  const { W, calls, count } = h;
  const [S, B] = await Promise.all([window.__gw.mod("./state.ts"), window.__gw.mod("./bridge.ts")]);
  W.webWins.value = [];
  W.BOUND.ms = 60_000;
  calls.length = 0;
  const plain = [];
  let n = 0;
  const was = B.powos.apps.launch;
  B.powos.apps.launch = async (k, o) => void plain.push(`${k}${o?.fullScreen ? " full" : ""}`);
  try {
    await S.launch("a:gate.launcher/.Main");
    await window.__gw.settled();
    n = count();
  } finally {
    B.powos.apps.launch = was;
    h.restore();
  }
  if (calls.length !== 1 || plain.length || n !== 1) fails.push(`OI2: a launcher launch made ${calls.length} window opens, plain launches [${plain}], ${n} .webwindow (want 1, none, 1)`);
  return fails;
}

async function webWindowOneInstance() {
  const { oneInstanceHost, oneInstanceTwice, oneInstanceUnbound } = window.__oneg;
  const h = await oneInstanceHost();
  const fails = [];
  try {
    await oneInstanceTwice(h, fails);
    await oneInstanceUnbound(h, fails);
  } finally {
    h.restore();
  }
  return fails;
}

/**
 * DG1 (ui/dockgroups.tsx; the user 10-31 03:18: "the homebar doesn't really show them as docked together"): two web
 * windows tiled on page 1 and one floating -> the dock has exactly one group cell (2 mini icons) and one single cell,
 * and no cell of their own for the tiled apps; a tap on the group cell raises both tiled windows over the floating one.
 */
async function webDockGroupCheck() {
  const { S, W, P, win, step } = window.__dtg;
  const keys = [...S.byKey.value.keys()].filter((k) => !S.dock.value.includes(k)).slice(0, 3);
  return step(async (fails) => {
    if (keys.length < 3) return void fails.push(`DG1: ${keys.length} unpinned apps, want 3`);
    const [a, b, c] = keys;
    try {
      W.webWins.value = [win(951, a), win(952, b), win(953, c)];
      W.tilings.value = { [P[0]]: { layout: "2h", ids: [951, 952], rx: 0.5, ry: 0.5 } };
      await window.__gw.frames(3);
      const groups = [...document.querySelectorAll(".home .dock .app.group")];
      const icons = groups[0]?.querySelectorAll(".task-icon").length;
      if (groups.length !== 1 || icons !== 2) fails.push(`DG1: ${groups.length} group cells (${icons} icons), want 1 with 2`);
      const own = (k) => document.querySelectorAll(`.home .dock .app[data-key="${CSS.escape(k)}"]`).length;
      if (own(a) || own(b)) fails.push(`DG1: the tiled apps have own cells too (${own(a)}, ${own(b)})`);
      if (own(c) !== 1) fails.push(`DG1: the floating window's app has ${own(c)} cells, want 1`);
      W.raise(953);
      const cell = groups[0];
      if (!cell) return;
      const r = cell.getBoundingClientRect();
      const at = { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, bubbles: true, pointerId: 8, button: 0 };
      cell.dispatchEvent(new PointerEvent("pointerdown", at));
      cell.dispatchEvent(new PointerEvent("pointerup", at));
      await window.__gw.frames(2);
      const top2 = W.webWins.value.slice(-2).map((w) => w.id).sort().join();
      if (top2 !== "951,952") fails.push(`DG1: a tap on the group cell left [${W.webWins.value.map((w) => w.id)}] (want 951 and 952 on top)`);
    } finally {
      W.tilings.value = {};
    }
  });
}

/**
 * In the page: two fingers on a web window's body (the native frame's zoom, back in the DOM, the user 10-30 21:04: "i
 * can no longer use two fingers to rescale the windows") scale it, floor 0.4; the body's measured scale (the w.f
 * entry's) follows; the pinch never reaches the app (its press ends in one cancel); and at that scale a press at the
 * body's centre goes to the app's centre (body px, unscaled: Body.toApp divides by the measured scale).
 */
/**
 * In the page: tiled web windows take input through the forward path (TL1, the user 10-31 00:05: "Can't interact with
 * the tabs that I put into like split screen"). Three windows tiled; at each tile's body centre the DOM hit test must
 * find that body (not a divider, a page hole or another window), and a tap and a vertical drag sent THERE (where the
 * finger's events go) reach powos.webwindows.input with the tile's id and body coordinates, every move included. Each
 * tile has its bar and its close works. SC1: a split down to one window ends - the last one is full screen, no tiling.
 * TILE_HELPERS first (page.evaluate sends only the one function).
 */
function TILE_HELPERS() {
  const pe = (el, type, [x, y], id) => el.dispatchEvent(new PointerEvent(type, { pointerId: id, pointerType: "touch", isPrimary: true, clientX: x, clientY: y, bubbles: true }));
  const seen = (calls) => calls.map((c) => `${c[0]}:${c[1]}`).join(",") || "nothing";
  // A tap at the centre: down and up for [id], at the body's centre in body px.
  const tap = (id, { body, hit }, calls, [cx, cy]) => {
    calls.length = 0;
    (pe(hit, "pointerdown", [cx, cy], 40 + id), pe(hit, "pointerup", [cx, cy], 40 + id));
    if (seen(calls) !== `${id}:down,${id}:up`) return [`tile ${id}: a tap reached the app as ${seen(calls)} (want ${id}:down,${id}:up)`];
    const off = Math.hypot(calls[0][2] - body.offsetWidth / 2, calls[0][3] - body.offsetHeight / 2);
    return off > 1 ? [`tile ${id}: a tap at its centre went to the app at ${calls[0][2]},${calls[0][3]} (want ${body.offsetWidth / 2},${body.offsetHeight / 2})`] : [];
  };
  // A 120 px drag up (a scroll): down, 6 moves, up, all for [id].
  const drag = (id, hit, calls, [cx, cy]) => {
    calls.length = 0;
    pe(hit, "pointerdown", [cx, cy + 60], 40 + id);
    for (let k = 1; k <= 6; k++) pe(hit, "pointermove", [cx, cy + 60 - 20 * k], 40 + id);
    pe(hit, "pointerup", [cx, cy - 60], 40 + id);
    const want = ["down", ...Array(6).fill("move"), "up"].map((a) => `${id}:${a}`).join(",");
    if (seen(calls) !== want) return [`tile ${id}: a vertical drag reached the app as ${seen(calls)} (want down, 6 moves, up for ${id})`];
    return Math.abs(calls[0][3] - calls[7][3] - 120) > 1 ? [`tile ${id}: a 120 px drag reached the app as ${calls[0][3] - calls[7][3]} px`] : [];
  };
  const one = (id, calls) => {
    const frame = document.querySelector(`.webwindow[data-wwid="${id}"]`);
    const body = frame?.querySelector(".webwindow-body");
    if (!body) return [`tile ${id}: no body element`];
    const bar = frame.querySelector(".webwindow-title .ww-close") ? [] : [`tile ${id}: no title bar with a close button`];
    const b = body.getBoundingClientRect();
    const c = [b.left + b.width / 2, b.top + b.height / 2];
    const hit = document.elementFromPoint(...c);
    if (hit !== body) return [...bar, `tile ${id}: the hit test at its body's centre found ${hit ? `${hit.tagName}.${hit.className}` : "nothing"}, not its body`];
    return [...bar, ...tap(id, { body, hit }, calls, c), ...drag(id, hit, calls, c)];
  };
  // Its bar's close, pressed where the finger is (the hit test's element).
  const closeTile = async (W, id) => {
    const close = document.querySelector(`.webwindow[data-wwid="${id}"] .ww-close`);
    if (!close) return [];
    const r = close.getBoundingClientRect();
    const at = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    const fails = close.contains(at) ? [] : [`tile ${id}: the hit test at its close button found ${at?.className}`];
    (pe(at, "pointerdown", [r.left + 4, r.top + 4], 70), pe(at, "pointerup", [r.left + 4, r.top + 4], 70));
    at.dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: r.left + 4, clientY: r.top + 4 }));
    await window.__gw.settled();
    if (W.webWins.value.some((w) => w.id === id)) fails.push(`tile ${id}: its close button didn't close it`);
    return fails;
  };
  // SC1: the last window of a split is full screen (the work area, with no host), no tiling left.
  const lastAlone = (W, id, page) => {
    const last = W.webWins.value.find((w) => w.id === id);
    const a = W.workArea();
    const fails = W.tiledOn(id) != null || W.tilings.value[page] ? ["SC1: a split down to one window is still a tiling"] : [];
    const full = last?.restore && Math.abs(last.w - (a.right - a.left)) <= 1 && Math.abs(last.h - (a.bottom - a.top)) <= 1;
    return full ? fails : [...fails, `SC1: the last window of a split isn't full screen (${last?.w}x${last?.h}, restore ${!!last?.restore})`];
  };
  window.__tileg = { one, closeTile, lastAlone };
  return [];
}

async function webWindowTileInputCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const { powos } = await window.__gw.mod("./bridge.ts");
  const had = powos.webwindows;
  const calls = [];
  powos.webwindows = { ...had, input: (id, action, a) => (calls.push([id, action, a.x, a.y]), Promise.resolve(true)) };
  const page = S.pages.value[0];
  try {
    S.page.value = 0;
    await window.__gw.settled();
    W.webWins.value = [911, 912, 913].map((id, i) => ({ id, key: `a:gate.tile${i}`, label: `Tile ${i}`, page, x: 60 + 40 * i, y: 100 + 40 * i, w: 300, h: 260, live: true }));
    W.tileWindows(page, [911, 912, 913]);
    await window.__gw.settled();
    const fails = [911, 912, 913].flatMap((id) => window.__tileg.one(id, calls));
    // A tile's own close (its bar): gone, the others close up; then a split of two down to one ends (SC1).
    fails.push(...(await window.__tileg.closeTile(W, 913)));
    if (W.tiledOn(911) == null || W.tiledOn(912) == null) fails.push("a tile closed out of three: the other two left their split");
    W.minimise(912);
    await window.__gw.settled();
    return [...fails, ...window.__tileg.lastAlone(W, 911, page)];
  } finally {
    W.webWins.value = [];
    W.tilings.value = {};
    powos.webwindows = had;
  }
}

/**
 * TI1 (the user, 10-31 15:08-15:10, unfolded, Chrome left, Settings over Discord on the right): "I can't interact with
 * this" (the tiled windows' bar buttons), the divider's pill drawn upright across Discord's bar. In the page, three
 * tiled windows in that layout: each bar button is what the hit test finds at its centre; no body rect in "w.f" (the
 * app's touches) covers a bar; the top/bottom divider's pill lies flat in its gap, over no bar, the gap filled.
 */
function TI_HELPERS() {
  const rect = (el) => el.getBoundingClientRect();
  const meets = (a, b) => a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5;
  const bars = () => [...document.querySelectorAll(".webwindow[data-wwid] .webwindow-title")].map(rect);
  const buttons = (id) =>
    [...document.querySelectorAll(`.webwindow[data-wwid="${id}"] .ww-controls .ww-button`)].flatMap((b) => {
      const r = rect(b);
      const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      return b.contains(hit) ? [] : [`TI1: window ${id}'s ${b.getAttribute("aria-label")} button: the hit test at its centre found ${hit ? `${hit.tagName}.${hit.className}` : "nothing"}`];
    });
  // The app's touch rects: each window's body in its "w.f" entry (fields 5-8, viewport CSS px).
  const bodies = (W) =>
    W.webWins.value.flatMap((w) => {
      const f = W.entry(w)?.split(" ").map(Number);
      return f ? [{ id: w.id, left: f[5], top: f[6], right: f[5] + f[7], bottom: f[6] + f[8] }] : [];
    });
  const pill = () => {
    const d = document.querySelector('.ww-divider[data-axis="y"]');
    if (!d) return ["TI1: no top/bottom divider for the Settings | Discord split"];
    const r = rect(d);
    const cs = getComputedStyle(d, "::after");
    const [w, h] = [parseFloat(cs.width), parseFloat(cs.height)];
    const p = { left: r.left + r.width / 2 - w / 2, right: r.left + r.width / 2 + w / 2, top: r.top + r.height / 2 - h / 2, bottom: r.top + r.height / 2 + h / 2 };
    const fails = w > h ? [] : [`TI1: the top/bottom divider's pill is upright (${w}x${h})`];
    if (bars().some((b) => meets(b, p))) fails.push(`TI1: the divider's pill ${JSON.stringify(p)} overlaps a window's bar`);
    if (getComputedStyle(d).backgroundColor === "rgba(0, 0, 0, 0)") fails.push("TI1: the gap between Settings and Discord shows what's under the windows (no fill)");
    return fails;
  };
  const centre = (id, label) => {
    const b = document.querySelector(`.webwindow[data-wwid="${id}"] .ww-button[aria-label="${label}"]`);
    if (!b) return null;
    const r = rect(b);
    return [r.left + r.width / 2, r.top + r.height / 2];
  };
  window.__ti = { meets, bars, buttons, bodies, pill, centre };
  return [];
}

async function tileBarsSetup() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const page = S.pages.value[0];
  S.page.value = 0;
  await window.__gw.settled();
  W.webWins.value = [931, 932, 933].map((id, i) => ({ id, key: `a:gate.ti${i}`, label: ["Chrome", "Settings", "Discord"][i], page, x: 60 + 40 * i, y: 100 + 40 * i, w: 300, h: 260, live: true }));
  W.tileWindows(page, [931, 932, 933]);
  await window.__gw.settled();
  await window.__gw.frames(2);
  if (W.tilings.value[page]?.layout !== "3") return [`TI1: three windows tiled as ${W.tilings.value[page]?.layout}, not one left + two stacked right`];
  const t = window.__ti;
  const fails = [931, 932, 933].flatMap(t.buttons);
  for (const b of t.bodies(W)) if (t.bars().some((r) => t.meets(r, b))) fails.push(`TI1: window ${b.id}'s touch rect in w.f ${JSON.stringify(b)} covers a bar`);
  return [...fails, ...t.pill()];
}

async function tileBarsState() {
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  await window.__gw.settled();
  return { min: !!W.webWins.value.find((w) => w.id === 933)?.minimised, open: W.webWins.value.some((w) => w.id === 932) };
}

async function tileBarsDone() {
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  W.webWins.value = [];
  W.tilings.value = {};
  return [];
}

/**
 * A finger (CDP touch: the phone's path - touch events, pointer events, the synthesized click) on [page], reloaded with
 * touch on (Preact binds onTouchStart as "touchstart" only where the element has ontouchstart, as on the phone).
 */
async function fingerOf(page) {
  const cdp = await page.target().createCDPSession();
  await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 });
  await page.reload().catch(() => {});
  await page.waitForFunction(() => window.__powosAlive === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
  const touch = (type, pts) => cdp.send("Input.dispatchTouchEvent", { type, touchPoints: pts });
  const wait = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const tap = async ([x, y]) => (await touch("touchStart", [{ x, y }]), await wait(50), await touch("touchEnd", []), await wait(80));
  return { touch, wait, tap };
}

/** TI1 with a finger: Discord's minimise and then Settings' close, tapped where they are. */
async function tileBarsScene(r) {
  const f = await fingerOf(r.page);
  await r.page.evaluate(TI_HELPERS);
  const fails = await r.page.evaluate(tileBarsSetup);
  try {
    const min = await r.page.evaluate(() => window.__ti.centre(933, "Minimise"));
    if (min) await f.tap(min);
    if (!(await r.page.evaluate(tileBarsState)).min) fails.push("TI1: a tap on Discord's minimise button didn't minimise it");
    const close = await r.page.evaluate(() => window.__ti.centre(932, "Close"));
    if (close) await f.tap(close);
    if ((await r.page.evaluate(tileBarsState)).open) fails.push("TI1: a tap on Settings' close button didn't close it");
    return fails;
  } finally {
    await r.page.evaluate(tileBarsDone);
  }
}

/**
 * SB1 (the user, 10-31 15:11: "I should be able to swipe on the search bar to change page"): a finger's sideways swipe
 * from home's bottom search bar pages home as one on empty home does - following the finger, the page index stepping
 * once, never back and forth - with no windows and with two tiled windows (which follow the page in the same frame).
 */
async function barSwipeSetup(withWindows) {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  S.page.value = 0;
  const page = S.pages.value[0];
  W.webWins.value = withWindows ? [941, 942].map((id, i) => ({ id, key: `a:gate.sb${i}`, label: `SB ${i}`, page, x: 40 + 60 * i, y: 120, w: 160, h: 200, live: true })) : [];
  if (withWindows) W.tileWindows(page, [941, 942]);
  await window.__gw.settled();
  await window.__gw.frames(2);
  const bar = document.querySelector(".home > .bar");
  if (!bar) return null;
  const r = bar.getBoundingClientRect();
  window.__sb = { seen: [] };
  window.__sb.off = S.page.subscribe((p) => window.__sb.seen.push(p));
  return [r.left + r.width * 0.7, r.top + r.height / 2];
}

const barSwipeLeft = () => document.querySelector('.webwindow[data-wwid="941"]')?.getBoundingClientRect().left ?? null;

async function barSwipeResult() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  await window.__gw.settled();
  await window.__gw.frames(4);
  window.__sb.off();
  const out = { page: S.page.value, steps: window.__sb.seen.slice(1), focused: document.activeElement?.tagName ?? "" };
  W.webWins.value = [];
  W.tilings.value = {};
  S.page.value = 0;
  await window.__gw.settled();
  return out;
}

/** One SB1 swipe: 240 px left from the search bar in 8 moves, the tiled window checked 120 px in ([windows]). */
async function barSwipeOnce(r, f, tag, windows) {
  const at = await r.page.evaluate(barSwipeSetup, windows);
  if (!at) return [`${tag}: no search bar`];
  const fails = [];
  const l0 = await r.page.evaluate(barSwipeLeft);
  await f.touch("touchStart", [{ x: at[0], y: at[1] }]);
  for (let k = 1; k <= 8; k++) {
    await f.touch("touchMove", [{ x: at[0] - 30 * k, y: at[1] }]);
    await f.wait(17);
    const l = k === 4 && windows ? await r.page.evaluate(barSwipeLeft) : null;
    if (l != null && Math.abs(l - (l0 - 120)) > 3) fails.push(`${tag}: 120 px into the swipe a tiled window moved ${Math.round(l - l0)} px (want -120, with the page)`);
  }
  await f.touch("touchEnd", []);
  const out = await r.page.evaluate(barSwipeResult);
  if (out.page !== 1 || out.steps.join(",") !== "1") fails.push(`${tag}: a 240 px swipe left on the search bar went to page ${out.page} via [${out.steps}] (want 1, once)`);
  return fails;
}

/** SB1 with a finger, [label] the fold: no windows and then two tiled ones. */
async function barSwipeScene(r, label) {
  const f = await fingerOf(r.page);
  const none = await barSwipeOnce(r, f, `SB1 ${label} no windows`, false);
  return [...none, ...(await barSwipeOnce(r, f, `SB1 ${label} 2 tiled windows`, true))];
}

/**
 * DL1 (the user, 10-31 15:12: "I shouldn't have to hold it, I should just be able to drag it out"; dev/dock-lift-check.js):
 * a finger (CDP touch: mouse events never bind home's onTouchStart) on a dock app. "folded" (?mode=pull, Chrome in
 * front): up 40 px lifts it out (a carry, a tick), on to the top edge splits, to the middle floats. "home" (folded home):
 * sideways pages, a still hold is the app's menu (edit), a tap opens full screen. "right" (unfolded, the right dock):
 * left 40 px then to the middle opens a web window.
 */
const dl = (page, fn, ...args) => page.evaluate(async (fn, args) => (await importShim("./dev/dock-lift-check.js"))[fn](...args), fn, args);

/** One finger from [from] through [path] (five moves to each point), let go at its end; the state at the points [at] names. */
async function dlDrag(r, f, { from, path, at = {} }) {
  const seen = {};
  await f.touch("touchStart", [{ x: from[0], y: from[1] }]);
  let p = from;
  for (const [i, to] of path.entries()) {
    for (let k = 1; k <= 5; k++) (await f.touch("touchMove", [{ x: p[0] + ((to[0] - p[0]) * k) / 5, y: p[1] + ((to[1] - p[1]) * k) / 5 }]), await f.wait(17));
    p = to;
    // The state each point waits for (DL_WANT): under the ship gate's load the moves are handled late.
    if (at[i]) seen[at[i]] = await dlUntil(r, f, DL_WANT[at[i]]);
  }
  await f.touch("touchEnd", []);
  await f.wait(400);
  return seen;
}

/** What a point of [dlDrag] waits for: "lift" the carry, "end" the ghost, "mid" (a page swipe under way) anything. */
const DL_WANT = { lift: (s) => s.carry && s.ticks, end: (s) => s.zone, mid: (s) => s.page || s.strip };

/** Waits up to 8 s for [ok] on the page's state; the state then. */
async function dlUntil(r, f, ok) {
  let s = await dl(r.page, "state");
  for (let t = 0; t < 80 && !ok(s); t++) (await f.wait(100), (s = await dl(r.page, "state")));
  return s;
}

/** The lift: carried (lifted), a tick, no menu; then the ghost at the end shows [zone]. [tag] names the step. */
function dlLifted(seen, zone, tag) {
  const { lift = {}, end = {} } = seen;
  return [
    [!lift.carry?.lifted, `the move away from the dock didn't lift the app out (carry ${JSON.stringify(lift.carry)})`],
    [!lift.ticks, "no haptic tick as the app lifted out"],
    [lift.menu, "the move opened the app's menu (a hold), not a lift"],
    [end.zone !== zone, `at the end the ghost shows ${end.zone ?? "nothing"}, not ${zone}`],
  ].flatMap(([bad, what]) => (bad ? [`${tag}: ${what}`] : []));
}

/** Folded (?mode=pull, Chrome in front): [key] up 40 px and on to [end]: the ghost's [zone], then [want] of the host. */
async function dlFoldedOnce(r, f, [key, end, zone, want]) {
  await dl(r.page, "reset");
  const c = await dl(r.page, "cell", key);
  if (!c) return [`DL1 folded: no dock cell for ${key}`];
  const tag = `DL1 folded ${key} to ${end}`;
  const fails = dlLifted(await dlDrag(r, f, { from: c, path: [[c[0], c[1] - 40], end], at: { 0: "lift", 1: "end" } }), zone, tag);
  const s = await dlUntil(r, f, want);
  return want(s) ? fails : [...fails, `${tag}: let go: split ${JSON.stringify(s.split)} float ${JSON.stringify(s.float)} launch ${JSON.stringify(s.launch)}`];
}

async function dockLiftFolded(r, f) {
  await dl(r.page, "setup", false);
  const top = await dlFoldedOnce(r, f, ["a:signal", [202, 60], "first", (s) => String(s.split[0]) === "101,100"]);
  return [...top, ...(await dlFoldedOnce(r, f, ["a:spotify", [202, 450], "window", (s) => String(s.float[0]) === "102"]))];
}

/** Folded home: a sideways drag along the dock pages (home's or the dock strip's own), never lifts. */
async function dlSideways(r, f, c) {
  await dl(r.page, "reset");
  const s0 = await dl(r.page, "state");
  const seen = await dlDrag(r, f, { from: c, path: [[c[0] - 300, c[1]]], at: { 0: "mid" } });
  const side = await dl(r.page, "state");
  if (side.carry || seen.mid?.carry || side.split.length || side.float.length) return [`DL1 home: a sideways drag on the dock lifted the app (carry ${JSON.stringify(seen.mid?.carry)})`];
  const paged = [seen.mid, side].some((s) => s && (s.page !== s0.page || s.strip !== s0.strip));
  return paged ? [] : [`DL1 home: a sideways drag on the dock paged nothing (page ${side.page}, strip ${seen.mid?.strip}/${side.strip})`];
}

async function dockLiftHome(r, f) {
  await dl(r.page, "setup", false);
  const c = await dl(r.page, "cell", "a:maps");
  if (!c) return ["DL1 home: no dock cell for a:maps"];
  const fails = await dlSideways(r, f, c);
  // A still hold: the app's menu (edit), nothing lifted.
  await dl(r.page, "reset");
  const c2 = (await dl(r.page, "cell", "a:maps")) ?? c;
  await f.touch("touchStart", [{ x: c2[0], y: c2[1] }]);
  // The hold's 420 ms, then its menu (waited for: under load its timer runs late).
  await f.wait(500);
  const held = await dlUntil(r, f, (s) => s.menu);
  await f.touch("touchEnd", []);
  if (held.menu !== "a:maps" || held.carry) fails.push(`DL1 home: a still hold on a:maps: menu ${held.menu}, carry ${JSON.stringify(held.carry)} (want its menu)`);
  // A tap: full screen.
  await dl(r.page, "reset");
  // Once the menu's scrim is gone and the cell is the finger's again (cell waits for it).
  const c3 = await dl(r.page, "cell", "a:maps");
  if (!c3) return [...fails, "DL1 home: after the menu, a:maps's dock cell never came back to a finger"];
  await f.tap(c3);
  const tapped = await dlUntil(r, f, (s) => s.launch.length);
  if (String(tapped.launch[0]) !== "a:maps,true") fails.push(`DL1 home: a tap on a:maps launched ${JSON.stringify(tapped.launch)} (want a:maps full screen)`);
  return fails;
}

async function dockLiftRight(r, f) {
  const pos = await dl(r.page, "setup", true);
  if (pos !== "right") return [`DL1 right: the dock is ${pos}, not right`];
  const c = await dl(r.page, "cell", "a:maps");
  if (!c) return ["DL1 right: no dock cell for a:maps"];
  const fails = dlLifted(await dlDrag(r, f, { from: c, path: [[c[0] - 40, c[1]], [410, 440]], at: { 0: "lift", 1: "end" } }), "window", "DL1 right");
  const s = await dlUntil(r, f, (st) => st.windows);
  return s.windows ? fails : [...fails, `DL1 right: let go in the middle, no web window (float ${JSON.stringify(s.float)} launch ${JSON.stringify(s.launch)})`];
}

/** DL1 with a finger, [kind] the scene. */
async function dockLiftScene(r, kind) {
  const f = await fingerOf(r.page);
  return { folded: dockLiftFolded, home: dockLiftHome, right: dockLiftRight }[kind](r, f);
}

/**
 * In the page: the tile LAYOUT (10-31). TG1: two corner snaps make a 2-split filling the whole tile area (no empty slot,
 * a lone snap is no tiling); TG2: a divider dragged to near an edge stays there (only the minimum tile limits it);
 * TL2: every tile has its bar with a close, none merged into the status bar (its spans stay full width); SC1: closing
 * one of two leaves no tiling.
 */
async function webWindowTileLayoutCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const page = S.pages.value[0];
  const near = (a, b) => Math.abs(a - b) <= 2;
  const frame = (id) => document.querySelector(`.webwindow[data-wwid="${id}"]`);
  const win = (id, i) => ({ id, key: `a:gate.lay${i}`, label: `Lay ${i}`, page, x: 80 + 60 * i, y: 120 + 60 * i, w: 320, h: 260, live: true });
  // TG1: the two frames span the tile area edge to edge, top to bottom.
  const fills = (ids) => {
    const a = W.tileArea();
    const [l, r] = ids.map((id) => frame(id)?.getBoundingClientRect());
    if (!l || !r) return ["TG1: a tile has no frame"];
    const ok = [near(l.left, a.left), near(r.right, a.right), ...[l, r].flatMap((b) => [near(b.top, a.top), near(b.bottom, a.bottom)])].every(Boolean);
    return ok ? [] : [`TG1: 2 tiles don't fill the area ${JSON.stringify(a)}: ${[l, r].map((b) => `${b.left | 0},${b.top | 0} ${b.width | 0}x${b.height | 0}`).join(" | ")}`];
  };
  // TL2 + the status bar: a bar with a close on each tile, none maximised (a merged bar squeezes the status bar).
  const bars = (ids) =>
    ids.flatMap((id) => {
      const f = frame(id);
      const no = f?.querySelector(".webwindow-title .ww-close") ? [] : [`TL2: tile ${id} has no title bar with a close`];
      const merged = f?.querySelector(".webwindow-title.merged") || f?.classList.contains("maximised");
      return merged ? [...no, `status bar: tile ${id} is maximised, its bar merged into the status bar (squeezes it)`] : no;
    });
  // TG2: the divider, dragged to just past the minimum tile from the right edge, stays there (no snap to two thirds).
  const dragDivider = async () => {
    const div = document.querySelector(".ww-divider");
    if (!div) return ["TG2: no divider"];
    const a = W.tileArea();
    const d = div.getBoundingClientRect();
    const [x0, y] = [d.left + d.width / 2, d.top + d.height / 2];
    const to = a.right - W.MIN_TILE.x - 4;
    const ev = (type, x) => div.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 81, isPrimary: true, clientX: x, clientY: y }));
    ev("pointerdown", x0);
    for (let k = 1; k <= 8; k++) ev("pointermove", x0 + ((to - x0) * k) / 8);
    ev("pointerup", to);
    await window.__gw.settled();
    const rx = W.tilings.value[page]?.rx ?? 0;
    const want = (to - a.left) / (a.right - a.left);
    return Math.abs(rx - want) > 0.02 ? [`TG2: the divider let go at ${want.toFixed(2)} of the area sits at ${rx.toFixed(2)}`] : [];
  };
  try {
    S.page.value = 0;
    await window.__gw.settled();
    W.webWins.value = [win(921, 0)];
    W.tile(921, "tl");
    const fails = W.tilings.value[page] ? ["TG1: the only window snapped to a corner made a tiling (a reserved empty slot)"] : [];
    W.webWins.value = [...W.webWins.value, win(922, 1)];
    W.tile(922, "tr");
    await window.__gw.settled();
    const ids = W.tilings.value[page]?.ids ?? [];
    if (ids.length !== 2 || ids.includes(null)) return [...fails, `TG1: two corner snaps gave ${JSON.stringify(ids)}, not a 2-split`];
    fails.push(...fills(ids), ...bars(ids), ...(await dragDivider()));
    // SC1: one of two gone (minimised: the same untile) - no tiling left.
    W.minimise(922);
    await window.__gw.settled();
    return W.tilings.value[page] || W.tiledOn(921) != null ? [...fails, "SC1: a split down to one window is still a tiling"] : fails;
  } finally {
    W.webWins.value = [];
    W.tilings.value = {};
  }
}

/**
 * In the page: GL1, docking into the tiles (the user, 10-31 01:28: "drag them into a grid again. Like check out how
 * golden layout work"). Two tiles and a floating window: its bar dragged over the left tile's right edge shows the
 * preview there (and ticks); let go, three tiles with it where previewed; its bar dragged out again, two tiles.
 */
function DOCK_HELPERS() {
  const frame = (id) => document.querySelector(`.webwindow[data-wwid="${id}"]`);
  const ev = (id, type, [x, y]) => frame(id).querySelector(".webwindow-title").dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 83, isPrimary: true, clientX: x, clientY: y }));
  const fmt = (b) => `${Math.round(b.x)},${Math.round(b.y)} ${Math.round(b.width ?? b.w)}x${Math.round(b.height ?? b.h)}`;
  window.__dockg = {
    frame,
    fmt,
    near: (a, b) => [a.x - b.x, a.y - b.y, a.width - b.w, a.height - b.h].every((d) => Math.abs(d) <= 3),
    /** Window [id]'s bar dragged to [to] (held there: no pointerup). */
    async hold(id, to) {
      const bar = frame(id).querySelector(".webwindow-title").getBoundingClientRect();
      const from = [bar.left + 60, bar.top + bar.height / 2];
      ev(id, "pointerdown", from);
      for (let k = 1; k <= 8; k++) ev(id, "pointermove", [from[0] + ((to[0] - from[0]) * k) / 8, from[1] + ((to[1] - from[1]) * k) / 8]);
      await window.__gw.settled();
    },
    async release(id, at) {
      ev(id, "pointerup", at);
      await new Promise((r) => setTimeout(r, 400));
      await window.__gw.settled();
    },
    /** Let go: 931 | 933 | 932, 933 at the previewed rect [want], the preview gone. */
    landed(W, page, want) {
      const t = W.tilings.value[page];
      if (JSON.stringify(t?.ids) !== "[931,933,932]") return [`GL1: let go, the tiles are ${JSON.stringify(t)} (want 931 | 933 | 932)`];
      const got = frame(933).getBoundingClientRect();
      const fails = want && !this.near(got, want) ? [`GL1: it landed at ${fmt(got)}, previewed ${fmt(want)}`] : [];
      return document.querySelector(".ww-drop") ? [...fails, "GL1: the preview stayed after the drop"] : fails;
    },
    /** While held: the zone is the left tile's right half, the preview drawn, a haptic tick since [ticks]. */
    preview(W, ticks) {
      const z = W.dropView.value?.zone;
      const fails = z?.kind === "split" && z.tile === 0 && z.side === "right" ? [] : [`GL1: over the left tile's right edge the zone is ${JSON.stringify(z)}`];
      if (!document.querySelector(".ww-drop")) fails.push("GL1: no drop preview over the tiles");
      if ((window.__hapticsMock?.tick ?? 0) <= ticks) fails.push("GL1: no haptic tick as the preview zone showed");
      return fails;
    },
  };
  return [];
}

/**
 * In the page: WT1-WT3, tabs (the user, 10-31 01:31: "grab the title bar of Dolphin and drag it into the title bar of
 * Chrome, and then they can share a title bar and they can tap between them"). Helpers for [webWindowTabsCheck].
 */
function TAB_HELPERS() {
  const frame = (id) => document.querySelector(`.webwindow[data-wwid="${id}"]`);
  const pe = (el, type, [x, y]) => el.dispatchEvent(new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: 84, isPrimary: true, clientX: x, clientY: y }));
  const mid = (r) => [r.left + r.width / 2, r.top + r.height / 2];
  const settle = async () => (await new Promise((r) => setTimeout(r, 300)), await window.__gw.settled());
  window.__tabg = {
    frame,
    /** Press [el] at [from], move in 8 steps to [to], let go there unless [hold]. */
    async drag(el, from, to, hold) {
      pe(el, "pointerdown", from);
      for (let k = 1; k <= 8; k++) pe(el, "pointermove", [from[0] + ((to[0] - from[0]) * k) / 8, from[1] + ((to[1] - from[1]) * k) / 8]);
      await settle();
      if (!hold) (pe(el, "pointerup", to), await settle());
    },
    /** Window [id]'s bar (its free end) dragged onto window [onto]'s bar. */
    async barOnto(id, onto, hold) {
      const b = frame(id).querySelector(".webwindow-title").getBoundingClientRect();
      const t = frame(onto).querySelector(".webwindow-title").getBoundingClientRect();
      this.at = [t.left + t.width * 0.4, t.top + t.height / 2];
      await this.drag(frame(id).querySelector(".webwindow-title"), [b.left + 60, b.top + b.height / 2], this.at, hold);
    },
    async let(id) {
      pe(frame(id).querySelector(".webwindow-title"), "pointerup", this.at);
      await settle();
    },
    tab: (shown, id) => frame(shown)?.querySelector(`.ww-tab[data-tab="${id}"]`),
    async tap(shown, id) {
      const el = this.tab(shown, id);
      const at = mid(el.getBoundingClientRect());
      pe(el, "pointerdown", at);
      pe(el, "pointerup", at);
      await settle();
    },
    async tabOut(shown, id) {
      const el = this.tab(shown, id);
      const at = mid(el.getBoundingClientRect());
      await this.drag(el, at, [at[0] + 40, at[1] + 220]);
    },
  };
  return [];
}

/** WT1-WT3's judges ([webWindowTabsCheck]). */
function TAB_JUDGES() {
  const frame = (id) => document.querySelector(`.webwindow[data-wwid="${id}"]`);
  const near = (r, b) => r && [r.left - b.left, r.top - b.top, r.width - b.width, r.height - b.height].every((d) => Math.abs(d) <= 3);
  window.__tabj = {
    /** While B's bar is held over A's: the tab target A, its bar lit, a ghost tab, a tick since [ticks]. */
    aimed(W, a, ticks) {
      const v = W.tabView.value;
      const fails = v?.target === a ? [] : [`WT1: over the other bar the tab target is ${JSON.stringify(v)}`];
      if (!frame(a)?.querySelector(".webwindow-title.ww-tab-target")) fails.push("WT1: the target bar isn't lit");
      if (!frame(a)?.querySelector(".ww-tab.ghost")) fails.push("WT1: no ghost tab on the target bar");
      if ((window.__hapticsMock?.tick ?? 0) <= ticks) fails.push("WT1: no haptic tick as the tab target showed");
      return fails;
    },
    /** One stack [ids] shown as [shown] at [rect]: one element, the others none. */
    stacked(W, ids, shown, rect) {
      const s = W.stacks.value;
      if (s.length !== 1 || s[0].ids.join() !== ids.join() || s[0].active !== shown) return [`WT2: stacks ${JSON.stringify(s)} (want [${ids}] showing ${shown})`];
      const fails = ids.filter((id) => id !== shown && frame(id)).map((id) => `WT2: hidden tab ${id} still has an element`);
      if (!near(frame(shown)?.getBoundingClientRect(), rect)) fails.push("WT2: the shown tab isn't at the stack's frame");
      return [...fails, ...this.hiddenSent(W, ids.filter((v) => v !== shown))];
    },
    /** WT3: hidden tabs [ids] in the host's geometry, not visible (the host hides their layers, sizes kept). */
    hiddenSent(W, ids) {
      const geo = W.geometry().split(" ");
      return ids.flatMap((id) => {
        const i = geo.indexOf(String(id));
        return i >= 0 && geo[i + 14] === "0" ? [] : [`WT3: hidden tab ${id} not sent hidden (${i < 0 ? "absent" : "visible"})`];
      });
    },
    /** A 2-tab stack tiles as one tile: with a third window, a 2-split; a tab switch keeps the tile. */
    async tiles(W, g, page, win) {
      await g.barOnto(942, 941);
      W.webWins.value = [...W.webWins.value, win(943, 300, 500)];
      await window.__gw.settled();
      W.tileWindows(page, [942, 943]);
      await window.__gw.settled();
      const ids = JSON.stringify(W.tilings.value[page]?.ids);
      const tile = W.tileRects(W.tilings.value[page], W.tileArea())[0];
      const fails = ids === "[942,943]" ? [] : [`WT2: the stack + one window tile as ${ids} (want [942,943])`];
      await g.tap(942, 941);
      const now = JSON.stringify(W.tilings.value[page]?.ids);
      if (now !== "[941,943]") fails.push(`WT2: a tab switch in a tile left the tiles ${now} (want [941,943])`);
      const r = frame(941)?.getBoundingClientRect();
      if (!r || Math.abs(r.left - tile.x) > 3 || Math.abs(r.width - tile.w) > 3) fails.push("WT2: the switched-to tab isn't in the stack's tile");
      return fails;
    },
  };
  return [];
}

async function webWindowTabsCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const g = window.__tabg;
  const j = window.__tabj;
  const page = S.pages.value[0];
  const win = (id, x, y) => ({ id, key: `a:gate.tab${id}`, label: `Tab ${id}`, page, x, y, w: 340, h: 260, live: true });
  try {
    S.page.value = 0;
    await window.__gw.settled();
    W.webWins.value = [win(941, 40, 120), win(942, 460, 300)];
    await window.__gw.settled();
    const rect = g.frame(941).getBoundingClientRect();
    const ticks = window.__hapticsMock?.tick ?? 0;
    await g.barOnto(942, 941, true);
    const fails = j.aimed(W, 941, ticks);
    await g.let(942);
    const one = j.stacked(W, [941, 942], 942, rect);
    if (one.length) return [...fails, ...one];
    await g.tap(942, 941);
    fails.push(...j.stacked(W, [941, 942], 941, rect));
    await g.tabOut(941, 942);
    if (W.stacks.value.length || !g.frame(941) || !g.frame(942)) fails.push(`WT2: a tab dragged out leaves ${JSON.stringify(W.stacks.value)} (want two windows)`);
    return [...fails, ...(await j.tiles(W, g, page, win))];
  } finally {
    W.webWins.value = [];
    W.tilings.value = {};
    W.stacks.value = [];
    W.tabView.value = W.dropView.value = null;
  }
}

async function webWindowTileDockCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const g = window.__dockg;
  const page = S.pages.value[0];
  const win = (id, i) => ({ id, key: `a:gate.dock${i}`, label: `Dock ${i}`, page, x: 120 + 40 * i, y: 160 + 40 * i, w: 360, h: 280, live: true });
  try {
    S.page.value = 0;
    await window.__gw.settled();
    W.webWins.value = [win(931, 0), win(932, 1)];
    W.tileWindows(page, [931, 932]);
    W.webWins.value = [...W.webWins.value, win(933, 2)];
    await window.__gw.settled();
    const left = W.tileRects(W.tilings.value[page], W.tileArea())[0];
    const at = [left.x + left.w * 0.92, left.y + left.h * 0.6];
    const ticks = window.__hapticsMock?.tick ?? 0;
    await g.hold(933, at);
    const fails = g.preview(W, ticks);
    const want = W.dropView.value?.rect;
    await g.release(933, at);
    const three = g.landed(W, page, want);
    if (three.length) return [...fails, ...three];
    const got = g.frame(933).getBoundingClientRect();
    // Out again by its bar: floating, the other two a 2-split.
    const out = [got.left + got.width / 2, got.top + 200];
    await g.hold(933, out);
    await g.release(933, out);
    const two = JSON.stringify(W.tilings.value[page]?.ids);
    return W.tiledOn(933) == null && two === "[931,932]" ? fails : [...fails, `GL1: dragged out, the tiles are ${two} (want 933 floating, 931 | 932)`];
  } finally {
    W.webWins.value = [];
    W.tilings.value = {};
    W.dropView.value = null;
  }
}

/**
 * In the page: TG3a, the edge drawer (the user, 10-31 01:37: "the drawer stuff that we made, I think is really great").
 * Two tiles; the right one's bar dragged to the screen's right edge shows a ghost and a tick, let go there it parks: the
 * left one alone fills the area, one strip on the right edge; a tap on the strip -> two tiles again, the strip gone.
 */
async function webWindowParkCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const g = window.__dockg;
  const page = S.pages.value[0];
  const win = (id, i) => ({ id, key: `a:gate.park${i}`, label: `Park ${i}`, page, x: 120 + 40 * i, y: 160 + 40 * i, w: 360, h: 280, live: true });
  try {
    S.page.value = 0;
    await window.__gw.settled();
    W.webWins.value = [win(961, 0), win(962, 1)];
    W.tileWindows(page, [961, 962]);
    await window.__gw.settled();
    const edge = [innerWidth - 4, innerHeight / 2];
    const ticks = window.__hapticsMock?.tick ?? 0;
    await g.hold(962, edge);
    const fails = parkHeld(W, ticks);
    await g.release(962, edge);
    const strips = document.querySelectorAll(".ww-park");
    fails.push(...parkLanded(W, g, page, strips));
    if (strips.length !== 1) return fails;
    await parkTap(strips[0]);
    const two = JSON.stringify(W.tilings.value[page]?.ids);
    if (two !== "[961,962]") fails.push(`TG3a: the strip tapped, the tiles are ${two} (want 961 | 962)`);
    return document.querySelector(".ww-park") ? [...fails, "TG3a: the strip stayed after it was tapped"] : fails;
  } finally {
    W.webWins.value = [];
    W.tilings.value = {};
    W.parked.value = [];
    W.dropView.value = W.parkView.value = null;
  }

  /** Held at the right edge: the park previewed (a ghost) and a haptic tick since [ticks]. */
  function parkHeld(W, ticks) {
    const fails = W.parkView.value?.side === "right" ? [] : [`TG3a: held at the right edge, no park preview (${JSON.stringify(W.parkView.value)})`];
    if (!document.querySelector(".ww-drop")) fails.push("TG3a: no ghost while about to park");
    return (window.__hapticsMock?.tick ?? 0) > ticks ? fails : [...fails, "TG3a: no haptic tick entering the park zone"];
  }
  /** Let go: 962 parked (minimised, no tiling), 961 alone filling the area, one 28 px strip on the right edge. */
  function parkLanded(W, g, page, strips) {
    const fails = parkAlone(W, g, page);
    if (strips.length !== 1 || strips[0].dataset.parked !== "962") return [...fails, `TG3a: ${strips.length} strips after parking (want one, 962's)`];
    const r = strips[0].getBoundingClientRect();
    return r.width === 28 && r.right >= innerWidth - 1 ? fails : [...fails, `TG3a: the strip is at ${g.fmt(r)} (want 28 px wide on the right edge)`];
  }
  /** 962 parked (minimised, no tiling), 961 alone filling the area. */
  function parkAlone(W, g, page) {
    const fails = [];
    const one = g.frame(961)?.getBoundingClientRect();
    const a = W.workArea();
    if (W.tilings.value[page] || !W.webWins.value.find((w) => w.id === 962)?.minimised) fails.push(`TG3a: let go at the edge, 962 not parked (tiles ${JSON.stringify(W.tilings.value[page])})`);
    if (!one || one.width < (a.right - a.left) * 0.9) fails.push(`TG3a: the one left doesn't fill the area (${one && g.fmt(one)})`);
    return fails;
  }
  /** A tap on [strip]. */
  async function parkTap(strip) {
    const r = strip.getBoundingClientRect();
    const at = { bubbles: true, cancelable: true, pointerId: 84, isPrimary: true, clientX: r.left + 14, clientY: r.top + r.height / 2 };
    strip.dispatchEvent(new PointerEvent("pointerdown", at));
    strip.dispatchEvent(new PointerEvent("pointerup", at));
    await new Promise((res) => setTimeout(res, 300));
    await window.__gw.settled();
  }
}

/**
 * In the page: the edge snap's ghost (the user, 10-31 03:17: "there should be like a preview showing that hey by doing
 * this you're gonna end up with the window here like a ghost thing"). A floating window's bar held at the left edge's
 * middle shows a .ww-drop at the rect it then takes (+-3 px); back in the middle it goes; let go at the edge, it is there.
 */
async function webWindowSnapGhostCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const g = window.__dockg;
  const page = S.pages.value[0];
  const move = (at) => g.frame(941).querySelector(".webwindow-title").dispatchEvent(new PointerEvent("pointermove", { bubbles: true, cancelable: true, pointerId: 83, isPrimary: true, clientX: at[0], clientY: at[1] }));
  try {
    S.page.value = 0;
    W.webWins.value = [{ id: 941, key: "a:gate.snap", label: "Snap", page, x: 260, y: 220, w: 360, h: 280, live: true }];
    await window.__gw.settled();
    const a = W.tileArea();
    const edge = [a.left + 4, (a.top + a.bottom) / 2];
    const mid = [(a.left + a.right) / 2, (a.top + a.bottom) / 2];
    await g.hold(941, edge);
    const ghost = document.querySelector(".ww-drop")?.getBoundingClientRect();
    if (!ghost) return ["SG1: a bar held at the left edge's middle shows no snap ghost (.ww-drop)"];
    move(mid);
    await window.__gw.settled();
    const fails = document.querySelector(".ww-drop") ? ["SG1: the snap ghost stayed with the bar back in the middle"] : [];
    move(edge);
    await window.__gw.settled();
    await g.release(941, edge);
    const got = g.frame(941).getBoundingClientRect();
    const want = { x: ghost.left, y: ghost.top, w: ghost.width, h: ghost.height };
    if (!g.near(got, want)) fails.push(`SG1: let go at the edge it is at ${g.fmt(got)}, the ghost showed ${g.fmt(want)}`);
    if (document.querySelector(".ww-drop")) fails.push("SG1: the snap ghost stayed after the snap");
    return fails;
  } finally {
    W.webWins.value = [];
    W.tilings.value = {};
    W.snapView.value = null;
  }
}

/**
 * [webWindowPinchCheck]'s helpers into the page (window.__pzg; page.evaluate sends only the one function).
 * PZ1 (the user, 10-31 01:40: "If I zoom normally IN the app, I'm now resizing the window"): a pinch whose fingers start
 * on the BODY is the app's (Chrome's page zoom) - the window keeps its size and scale, the app gets ONE two-finger
 * gesture (finger 0 down, finger 1 down, both moving, both up; no cancel). SC1: a pinch whose first finger is on the BAR
 * (the second on the body) scales the window: 0.4..1.5, still 400x320 (no relayout), the frame transformed (bar and
 * body zoom together), the app's size in w.f unchanged and never a resize, nothing to the app.
 */
function PINCH_HELPERS() {
  const at = (el, type, id, [x, y]) => el.dispatchEvent(new PointerEvent(type, { pointerId: id, pointerType: "touch", isPrimary: id % 2 === 1, clientX: x, clientY: y, bubbles: true }));
  // Two fingers 200 px apart (about [cx]) come together to 140 px (8 moves): ids[0] on els[0] at ys[0], ids[1] on els[1].
  const pinchOn = (els, ys, ids, cx) =>
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].forEach((i) => {
      const t = i === 0 ? "pointerdown" : i === 9 ? "pointerup" : "pointermove";
      const q = Math.min(i, 8) * 3.75;
      (at(els[0], t, ids[0], [cx - 100 + q, ys[0]]), at(els[1], t, ids[1], [cx + 100 - q, ys[1]]));
    });
  // Both fingers in one gesture: down0, down1, moves of both, both up, never a cancel.
  const oneGesture = (seq) =>
    seq.slice(0, 2).join() === "down0,down1" && ["move0", "move1"].every((m) => seq.includes(m)) && seq.slice(-2).sort().join() === "up0,up1" && !seq.some((s) => s.startsWith("cancel"));
  // PZ1: the body's pinch, on window [pw] after it; [calls]: the app's input as [action, x, y, finger].
  const bodyPinch = (pw, body, calls) => {
    const fails = (pw.scale ?? 1) !== 1 || pw.w !== 400 || pw.h !== 320 ? [`a pinch on the body changed the window: ${pw.w}x${pw.h}@${pw.scale} (want 400x320@1: the app's zoom)`] : [];
    const seq = calls.map((c) => `${c[0]}${c[3]}`);
    if (!oneGesture(seq)) fails.push(`a pinch on the body sent the app ${seq.join(",")} (want down0,down1, moves of both, up0 and up1: one two-finger gesture)`);
    const m1 = calls.filter((c) => c[0] === "move" && c[3] === 1).at(-1);
    if (m1 && Math.abs(m1[1] - (body.offsetWidth / 2 + 70)) > 1) fails.push(`finger 1's last move reached the app at x ${m1[1]} (want ${body.offsetWidth / 2 + 70})`);
    return fails;
  };
  // SC1: the bar's pinch (40 px apart vertically: 204 -> 146 px, about 0.71) scaled [pw]; w.f entries from [from].
  const barPinch = (pw, body, from) => {
    const ours = (t) => [...Array(Math.floor(t.length / 24)).keys()].map((i) => t.slice(i * 24, i * 24 + 24)).find((e) => e[0] === "902");
    const entries = window.__ww.sent.slice(from).map((l) => ours(l.split(" ").slice(4))).filter(Boolean);
    const [tf, sizes] = [getComputedStyle(body.closest(".webwindow")).transform, new Set(entries.map((e) => `${e[21]}x${e[22]}`))];
    const bad = [Math.abs((pw.scale ?? 1) - 0.71) > 0.03 && `scale ${pw.scale} (want 0.71)`, (pw.w !== 400 || pw.h !== 320) && `size ${pw.w}x${pw.h} (want 400x320, unchanged)`,
      tf === "none" && "no transform on the frame (want the whole window zoomed)",
      Math.abs(body.getBoundingClientRect().width / body.offsetWidth - (pw.scale ?? 1)) > 0.01 && `a measured body scale ${body.getBoundingClientRect().width / body.offsetWidth} (the model's ${pw.scale})`,
      entries.some((e) => e[20] === "1") && "an app resize (w.f said resizing)",
      sizes.size > 1 && `the app's size changed: ${[...sizes].join(", ")}`];
    return bad.filter(Boolean).map((b) => `a pinch from the bar left ${b}`);
  };
  // At scale [k], a press at the body's centre reaches the app there; one finger whose up landed outside the frame
  // (never seen by it), then a new one-finger drag: only a move, no scale (10-30 "dragging with one finger rescales").
  const afterScale = async (W, body, calls) => {
    const pw = W.webWins.value.find((w) => w.id === 902);
    const b2 = body.getBoundingClientRect();
    const p = [b2.left + b2.width / 2, b2.top + b2.height / 2];
    calls.length = 0;
    (at(body, "pointerdown", 23, p), at(body, "pointerup", 23, p));
    const d = [...(calls[0] ?? []), NaN, NaN, NaN];
    const want = [body.offsetWidth / 2, body.offsetHeight / 2];
    const fails = Math.hypot(d[1] - want[0], d[2] - want[1]) > 1 ? [`at scale ${pw.scale}, a press at the body's centre went to the app at ${d[1]},${d[2]} (want ${want})`] : [];
    at(body, "pointerdown", 31, [p[0] - 80, p[1]]);
    document.body.dispatchEvent(new PointerEvent("pointerup", { pointerId: 31, pointerType: "touch", isPrimary: true, bubbles: true }));
    at(body, "pointerdown", 33, p);
    [20, 40, 60].forEach((dx) => at(body, "pointermove", 33, [p[0] + dx, p[1]]));
    at(body, "pointerup", 33, [p[0] + 60, p[1]]);
    await window.__gw.settled();
    const p2 = W.webWins.value.find((w) => w.id === 902);
    if (p2.w !== pw.w || p2.h !== pw.h || p2.scale !== pw.scale) fails.push(`a one-finger drag after a finger lifted outside the window changed it ${pw.w}x${pw.h}@${pw.scale} -> ${p2.w}x${p2.h}@${p2.scale}`);
    return fails;
  };
  window.__pzg = { pinchOn, bodyPinch, barPinch, afterScale };
  return [];
}

async function webWindowPinchCheck() {
  const g = window.__pzg;
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  const { powos } = await window.__gw.mod("./bridge.ts");
  // The app's input, recorded (restored after: the gate's host may have no webwindows at all).
  const had = powos.webwindows;
  const calls = [];
  powos.webwindows = { ...had, input: (id, action, a) => (calls.push([action, a.x, a.y, a.finger ?? 0]), Promise.resolve(true)) };
  try {
    const S = await window.__gw.mod("./state.ts");
    W.webWins.value = [{ id: 902, key: "a:gate.pinch", label: "Pinch", page: S.pages.value[0], x: 300, y: 160, w: 400, h: 320 }];
    await window.__gw.settled();
    const body = document.querySelector('.webwindow[data-wwid="902"] .webwindow-body');
    const bar = document.querySelector('.webwindow[data-wwid="902"] .webwindow-title');
    if (!body || !bar) return ["pinch: no web window body or bar on the page on screen"];
    const [pb, pr] = [body.getBoundingClientRect(), bar.getBoundingClientRect()];
    g.pinchOn([body, body], [pb.top + pb.height / 2, pb.top + pb.height / 2], [21, 22], pb.left + pb.width / 2);
    await window.__gw.settled();
    const fails = g.bodyPinch(W.webWins.value.find((w) => w.id === 902), body, calls);
    calls.length = 0;
    const from = window.__ww.sent.length;
    g.pinchOn([bar, body], [pr.top + pr.height / 2, pr.top + pr.height / 2 + 40], [25, 24], pb.left + pb.width / 2);
    await window.__gw.settled();
    fails.push(...g.barPinch(W.webWins.value.find((w) => w.id === 902), body, from));
    if (calls.length) fails.push(`a pinch from the bar reached the app: ${calls.map((c) => c[0] + c[3]).join(",")} (want nothing)`);
    return [...fails, ...(await g.afterScale(W, body, calls))];
  } finally {
    W.webWins.value = [];
    powos.webwindows = had;
  }
}

/**
 * In the page: web windows as ELEMENTS of their page (docs/WEB_WINDOWS.md "Element model"). The page's content is cut
 * over the bodies, a lower window over a higher one's body; a live body paints nothing, a new one its placeholder; the
 * DOM tile menu over a body takes the tap; and each frame's "w.f" follows a page swipe pixel-exact, clipped to the
 * page and the screen, hidden off page, on the PowOS AI side and under a folder.
 */
async function webWindowMaskCheck() {
  const S = await window.__gw.mod("./state.ts");
  const W = await window.__gw.mod("./ui/webwindows.tsx");
  // Its helpers are page functions too (WW_HELPERS, evaluated first): page.evaluate sends only this function.
  const g = window.__wwg;
  const ww = g.wwHelpers(W);
  const page = S.pages.value[S.page.value] || 1;
  try {
    W.webWins.value = [
      { id: 903, key: "a:gate.ww", label: "Gate", page, x: 400, y: 120, w: 360, h: 300, live: true },
      { id: 905, key: "a:gate.ww3", label: "Gate 3", page, x: 300, y: 200, w: 300, h: 240 },
      { id: 904, key: "a:gate.ww2", label: "Gate 2", page, x: 160, y: 200, w: 300, h: 240, minimised: true },
    ];
    await ww.frame();
    const el = document.querySelector('.webwindow[data-wwid="903"]');
    const top = document.querySelector('.webwindow[data-wwid="905"]');
    if (!g.wwFound(el, top)) return ["web windows: no elements (or no .page-under) on the page on screen"];
    g.wwCuts(ww, el, top);
    await g.wwMenu(ww, W, top);
    await g.wwRaise(ww, W);
    await g.wwSwipe(ww, el);
    await g.wwHidden(ww);
    g.wwMaximise(ww, W);
    return ww.fails;
  } finally {
    ww.restore();
    W.webWins.value = [];
  }
}

/** Both windows' elements on the page on screen, and the page's content wrapper. */
function wwFound(el, top) {
  return !!(el && top && el.closest(".page") && el.closest(".page").querySelector(".page-under"));
}

/** The web window checks' shared bits: failures, a frame, mask layers, the last "w.f" entry of a window. */
function wwHelpers(W) {
  const fails = [];
  const track = document.querySelector(".page-track");
  const screens = document.querySelector(".screens");
  const was = [track, screens].map((e) => (e ? e.style.transform : ""));
  return {
    W,
    fails,
    track,
    screens,
    // The page track and the screens back where they were (the swipe checks move them).
    restore: () => [track, screens].forEach((e, i) => e && (e.style.transform = was[i])),
    expect: (ok, msg) => ok || fails.push(msg),
    frame: () => new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(ok))),
    masks: (el) => (getComputedStyle(el).maskImage.match(/linear-gradient/g) ?? []).length,
    bg: (el) => getComputedStyle(el).backgroundColor,
    // The newest "w.f" entry of window [id]: its 19 numbers after the id (frame 0-3, body 4-7, clip 8-11, radius 12,
    // visible 13, alpha 14, scale 15, maximised 16, merge 17-18).
    sentFor: (id) => {
      // An entry is 24 words (ui/webwindows.tsx entry: ... <maximised> <titleEnd> <controls> <resizing> <app w> <app h> <fill>).
      const t = (window.__ww.sent.at(-1) ?? "").split(" ");
      for (let i = 4, n = Number(t[3]); n-- > 0; i += 24) if (Number(t[i]) === id) return t.slice(i + 1, i + 20).map(Number);
      return null;
    },
  };
}

/** Cut: the page under both bodies, the lower window under the higher one's body; live body clear, new a placeholder. */
function wwCuts(ww, el, top) {
  const under = el.closest(".page").querySelector(".page-under");
  ww.expect(ww.masks(under) === 3, `page content: ${ww.masks(under)} mask layers, want 3 (the page less 2 windows)`);
  ww.expect(ww.masks(el) === 2, `lower window: ${ww.masks(el)} mask layers, want 2 (itself less the higher window)`);
  ww.expect(ww.masks(top) === 0, "top window: masked (nothing is above it)");
  ww.expect(!document.querySelector('.webwindow[data-wwid="904"]'), "a minimised web window still has its element on the page");
  ww.expect(ww.bg(el.querySelector(".webwindow-body")) === "rgba(0, 0, 0, 0)", "a live window's body paints (it must be transparent over the app)");
  const ph = top.querySelector(".webwindow-body");
  ww.expect(ww.bg(ph) !== "rgba(0, 0, 0, 0)" && !!ph.querySelector(".ww-progress"), "a new window's body is a hole (want the placeholder: surface, icon, progress)");
  ww.expect(!!el.querySelector(".webwindow-title.tile"), "the title bar isn't a .tile (the widget glass)");
}

/** The DOM tile menu over a window's body takes the tap there (DOM order). */
async function wwMenu(ww, W, top) {
  top.querySelector('.ww-button[aria-label="Tile"]').click();
  await ww.frame();
  const item = top.querySelector('.ww-tile-item[data-slot="left"]');
  if (!ww.expect(!!item, "tile menu: not open after a tap on the tile button")) return;
  const ir = item.getBoundingClientRect();
  const body = top.querySelector(".webwindow-body").getBoundingClientRect();
  const hit = document.elementFromPoint(ir.left + ir.width / 2, ir.top + ir.height / 2);
  ww.expect(ir.top >= body.top && ir.top < body.bottom, "tile menu: not over the window's body (the check needs it there)");
  if (!ww.expect(hit === item || item.contains(hit), `tile menu: a tap over the body hits ${hit?.className} instead of the menu item`)) return;
  hit.click();
  await ww.frame();
  ww.expect(W.tiledOn(905) != null, "tile menu: picking Left half didn't tile the window");
  W.tile(905, "float");
  // 903 was the other half of that split; alone again it filled the work area: back to its floating frame.
  W.update(903, { x: 400, y: 120, w: 360, h: 300, restore: undefined });
  await ww.frame();
}

/**
 * raise(): one order drives both sides - the "w.f" the host stacks the apps' layers by (its index is the layer's z) and
 * the page's own stacking of the frames (bar, body, edges, shadow: one element each). The user, 10-30 20:54: "kind of
 * works for content ... But not the title bars" (the layers stayed in the old order while the bars went up).
 */
async function wwRaise(ww, W) {
  for (const [id, want] of [[903, "905,903"], [905, "903,905"]]) {
    W.raise(id);
    await ww.frame();
    const t = (window.__ww.sent.at(-1) ?? "").split(" ");
    const ids = [];
    for (let i = 4, n = Number(t[3]); n-- > 0; i += 24) ids.push(Number(t[i]));
    if (ww.expect(ids.join() === want, `raise(${id}): w.f order ${ids} (want ${want}: the raised window last)`)) window.__wwg.wwStacked(ww, ids, id);
  }
}

/** The frames of [ids] (w.f order, bottom first) stacked in that order: z-index, and the page's hit where they meet. */
function wwStacked(ww, ids, id) {
  const els = ids.map((w) => document.querySelector(`.webwindow[data-wwid="${w}"]`));
  const zs = els.map((e) => (e ? Number(getComputedStyle(e).zIndex) : NaN));
  ww.expect(zs.every((z, i) => i === 0 || z > zs[i - 1]), `raise(${id}): frames' z-index ${zs} doesn't follow w.f order ${ids}`);
  // As painted: where the lower frame (its bar first) meets the higher, the higher one is hit - never a bar of the
  // lower painted over it, whatever stacking context the bar's glass makes.
  const [lo, hi] = els;
  const b = hi.getBoundingClientRect();
  for (const part of [lo.querySelector(".webwindow-title"), lo]) {
    const a = part.getBoundingClientRect();
    const l = Math.max(a.left, b.left), r = Math.min(a.right, b.right), t = Math.max(a.top, b.top), bt = Math.min(a.bottom, b.bottom);
    if (r <= l || bt <= t) continue;
    const hit = document.elementFromPoint((l + r) / 2, (t + bt) / 2);
    ww.expect(hi.contains(hit), `raise(${id}): where window ${ids[0]}'s ${part === lo ? "frame" : "bar"} meets ${ids[1]} the page shows ${hit?.className} (want window ${ids[1]}, top of w.f)`);
  }
}

/** "w.f" each frame of a page swipe: pixel-exact with the page, hidden off it, clipped to it (PS2). */
async function wwSwipe(ww, el) {
  const at0 = ww.sentFor(903);
  if (!ww.expect(!!at0, "w.f: window 903 not in the last geometry sent")) return;
  ww.track.style.transition = "none";
  ww.track.style.transform = "translateX(-200px)";
  await ww.frame();
  const at1 = ww.sentFor(903) || [];
  const b1 = el.querySelector(".webwindow-body").getBoundingClientRect();
  ww.expect(Math.abs(at1[4] - b1.left) < 0.01 && Math.abs(at1[4] - (at0[4] - 200)) < 0.5, `page swipe: w.f body x ${at1[4]} (want ${b1.left}, ${at0[4] - 200}: 200 px left with its page)`);
  ww.expect(at1[13] === 1, "page swipe: the window went hidden mid-swipe");
  ww.track.style.transform = `translateX(${-innerWidth}px)`;
  await ww.frame();
  ww.expect((ww.sentFor(903) || [])[13] === 0, "page swiped away: the window is still visible in w.f");
  ww.restore();
  const pr = el.closest(".page").getBoundingClientRect();
  ww.W.update(903, { x: pr.width - 100 });
  await ww.frame();
  const hang = ww.sentFor(903) || [];
  ww.expect(hang[10] <= pr.right + 0.5, `page clip: w.f clip right ${hang[10]} past its page's right ${pr.right}`);
  ww.W.update(903, { x: 400 });
}

/** Hidden on the PowOS AI side (home slid away) and under a folder open over home. */
async function wwHidden(ww) {
  if (ww.screens) {
    ww.screens.style.transform = `translateX(${innerWidth}px)`;
    await ww.frame();
    ww.expect((ww.sentFor(903) || [])[13] === 0, "PowOS AI page: the window stays visible");
    ww.restore();
  }
  const f = document.body.appendChild(Object.assign(document.createElement("div"), { className: "folder-view open" }));
  await ww.frame();
  ww.expect((ww.sentFor(903) || [])[13] === 0, "a folder open over home: the window stays visible");
  f.remove();
}

/** Maximise fills the work area (the pages' box, above the dock) and restores the frame it had. */
function wwMaximise(ww, W) {
  W.toggleMaximise(903);
  const a = W.workArea();
  const m = W.webWins.value.find((w) => w.id === 903);
  ww.expect(!!m?.restore && Math.abs(m.w - (a.right - a.left)) <= 1 && Math.abs(m.h - (a.bottom - a.top)) <= 1, `full screen: ${JSON.stringify(m)} doesn't fill the work area ${JSON.stringify(a)}`);
  W.toggleMaximise(903);
  const r = W.webWins.value.find((w) => w.id === 903);
  ww.expect(!r?.restore && r?.w === 360 && r?.h === 300, `restore: ${JSON.stringify(r)} isn't back at 360x300`);
}

/** In the page: the LW3 run's modules, its mock host's log, its windows' elements by app key. */
async function lw3Env() {
  const mod = window.__gw.mod;
  const [S, W, B, H] = await Promise.all([mod("./state.ts"), mod("./ui/webwindows.tsx"), mod("./bridge.ts"), mod("./hosts/wide.ts")]);
  const g = (window.__lw3 ??= { launched: [], opened: [] });
  const els = (key) => [...document.querySelectorAll(".webwindow")].filter((e) => W.webWins.value.find((w) => String(w.id) === e.dataset.wwid)?.key === key);
  return { S, W, powos: B.powos, wideHome: H.wideHome, g, els, wait: (ms) => new Promise((ok) => setTimeout(ok, ms)) };
}

/** LW3: a mock web-windows host, then a Linux launch: its placeholder at once (no host geometry), the launch sent. */
async function lw3Launch() {
  const { S, W, powos, wideHome, g, els } = await window.__lw3f.lw3Env();
  wideHome.value = true;
  g.restore = { ww: powos.webwindows, launch: powos.apps.launch };
  powos.webwindows = {
    enabled: async () => true,
    open: async (key, rect, task, kwin) => (g.opened.push({ key, kwin, rect }), 77),
    close: async (id) => ((W.webWins.value = W.webWins.value.filter((w) => w.id !== id)), true),
    input: async () => true,
  };
  // A deliberately bad exec: the host's launch fails.
  powos.apps.launch = async (key) => {
    g.launched.push(key);
    if (key === "l:gate.bad") throw new Error("exec: not found");
  };
  W.LINUX_START.ms = 600_000;
  await S.launch("l:org.kde.dolphin");
  await window.__gw.settled();
  const w = W.webWins.value.find((v) => v.key === "l:org.kde.dolphin");
  g.el = els("l:org.kde.dolphin")[0];
  return [
    !(w?.pending && w.id < 0) && `a Linux launch made no placeholder window (${JSON.stringify(w)})`,
    !g.launched.includes("l:org.kde.dolphin") && "the placeholder's launch never reached the host (apps.launch)",
    !g.el?.querySelector(".ww-placeholder .ww-progress") && "the placeholder window shows no progress line",
    W.geometry().split(" ")[1] !== "0" && `a placeholder's geometry went to the host: ${W.geometry()}`,
  ].filter(Boolean);
}

/** LW3: another app's offer leaves the placeholder; Dolphin's takes it - the same element, the host's window id. */
async function lw3Offer() {
  const { W, g, els } = await window.__lw3f.lw3Env();
  // The KDE Wallet that came instead of Dolphin (2026-10-30 21:01) never takes Dolphin's placeholder.
  window.__mockEvents.emit("webwindows.adopt", { kwin: 36, key: "l:org.kde.ksecretd", label: "KDE Wallet Service" });
  window.__mockEvents.emit("webwindows.adopt", { kwin: 35, key: "l:org.kde.dolphin", label: "Dolphin" });
  await window.__gw.settled();
  const d = W.webWins.value.filter((v) => v.key === "l:org.kde.dolphin");
  const fails = [
    !(d.length === 1 && d[0].id === 77 && !d[0].pending) && `KWin's Dolphin did not take the placeholder: ${JSON.stringify(d)}`,
    els("l:org.kde.dolphin")[0] !== g.el && "the offered window is a new element, not the placeholder's (it jumps)",
    g.opened.find((o) => o.key === "l:org.kde.dolphin")?.kwin !== 35 && "the host opened no window for KWin's Dolphin (35)",
  ].filter(Boolean);
  window.__mockEvents.emit("webwindows.live", 77);
  W.webWins.value = d;
  return fails;
}

/** LW3: no window in LINUX_START - "couldn't start" with a close; a tap again is a new try. */
async function lw3Timeout() {
  const { S, W, g, els, wait } = await window.__lw3f.lw3Env();
  W.webWins.value = [];
  W.LINUX_START.ms = 200;
  await S.launch("l:org.kde.kate");
  await wait(400);
  await window.__gw.settled();
  const w = W.webWins.value.find((v) => v.key === "l:org.kde.kate");
  return [!(w?.failed && els("l:org.kde.kate")[0]?.querySelector(".ww-failed-close")) && `no "couldn't start" after the timeout: ${JSON.stringify(w)}`].filter(Boolean);
}

/** LW3: a tap on an app that couldn't start is a new try (a stuck window never blocks the app). */
async function lw3Retry() {
  const { S, W, g, wait } = await window.__lw3f.lw3Env();
  const fails = [];
  W.LINUX_START.ms = 600_000;
  const n = g.launched.length;
  await S.launch("l:org.kde.kate");
  const kate = W.webWins.value.filter((v) => v.key === "l:org.kde.kate");
  fails.push(!(g.launched.length === n + 1 && kate.length === 1 && !kate[0].failed) && "a tap on an app that couldn't start did not launch it again");
  W.LINUX_START.ms = 200;
  await wait(400);
  return fails.filter(Boolean);
}

/** LW3: a launch that fails (a bad exec) - "couldn't start" at once; its Close removes it. */
async function lw3BadExec() {
  const { S, W, els } = await window.__lw3f.lw3Env();
  W.webWins.value = [];
  await S.launch("l:gate.bad");
  await window.__gw.settled();
  const el = els("l:gate.bad")[0];
  const fails = [!el?.querySelector(".ww-failed-text")?.textContent.includes("launch failed") && `a bad exec shows no "couldn't start": ${el?.textContent}`];
  el?.querySelector(".ww-failed-close")?.click();
  await window.__gw.settled();
  fails.push(W.webWins.value.some((v) => v.key === "l:gate.bad") && "its Close left the window");
  return fails.filter(Boolean);
}

/** LW3: the host says a launch's command ended with no window ("apps.launchfailed") - "couldn't start: <why>" at once. */
async function lw3HostFailed() {
  const { S, W, els } = await window.__lw3f.lw3Env();
  W.webWins.value = [];
  W.LINUX_START.ms = 600_000;
  await S.launch("l:org.kde.kate");
  window.__mockEvents.emit("apps.launchfailed", { key: "l:org.kde.kate", reason: "It exited 1 with no window: kate: cannot open display" });
  await window.__gw.settled();
  const text = els("l:org.kde.kate")[0]?.querySelector(".ww-failed-text")?.textContent ?? "";
  W.webWins.value = [];
  W.LINUX_START.ms = 200;
  return [!text.includes("cannot open display") && `the host's launch failure shows no reason: "${text}"`].filter(Boolean);
}

/** LW3: the real host back. */
async function lw3End() {
  const { W, powos, g } = await window.__lw3f.lw3Env();
  powos.webwindows = g.restore.ww;
  powos.apps.launch = g.restore.launch;
  W.webWins.value = [];
  W.LINUX_START.ms = 20_000;
  return [];
}

/** The LW3 run's steps into the page (window.__lw3f); evaluates to []. */
const LW3_HELPERS = `(window.__lw3f = { ${[lw3Env, lw3Launch, lw3Offer, lw3Timeout, lw3Retry, lw3BadExec, lw3HostFailed, lw3End].map((f) => `${f.name}: ${f}`).join(", ")} }, [])`;

/** [webWindowMaskCheck]'s helpers into the page (window.__wwg); evaluates to [] (no problems) as a gate step. */
const WW_HELPERS = `(window.__wwg = { ${[wwHelpers, wwFound, wwCuts, wwMenu, wwRaise, wwStacked, wwSwipe, wwHidden, wwMaximise].map((f) => `${f.name}: ${f}`).join(", ")} }, [])`;

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
  // LW3 (the user, 2026-10-30: "they shoulf have a splash screen"): a Linux launch on the unfolded home with web
  // windows on shows its placeholder window at once; KWin's offer with its key takes it (the same element); a launch
  // that fails, or no window in LINUX_START, shows "couldn't start" with a close. Renders: /cache/lw3-*.png.
  runs.push(open(browser, `${ORIGIN}/index.html`, "linux-splash", { width: 821, height: 883 }).then((r) => whenReady(r, async () => {
    const shot = (name) => r.page.screenshot({ path: `/cache/lw3-${name}.png` });
    await r.page.evaluate(LW3_HELPERS);
    const step = (what) => r.page.evaluate((f) => window.__lw3f[f](), what);
    const fails = [...(await step("lw3Launch"))];
    await shot("1-placeholder");
    fails.push(...(await step("lw3Offer")));
    await shot("2-taken");
    fails.push(...(await step("lw3Timeout")));
    await shot("3-couldnt-start");
    fails.push(...(await step("lw3Retry")));
    fails.push(...(await step("lw3BadExec")));
    await shot("4-bad-exec");
    fails.push(...(await step("lw3HostFailed")));
    fails.push(...(await step("lw3End")));
    return fails;
  })));
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
  // SB3 (the user, 2026-10-30: "I can't press send like it doesn't disable the transcription and then send"): send
  // tapped mid-dictation stops the recognizer, waits for its final words (the send spins), then sends them once, the
  // mic off - in every pill with send (dev/send-dictation-check.js). Renders: /cache/send-dictation-<case>.png.
  for (const [name, mode, viewport, form, setup] of [
    ["bar-folded", "pull", { width: 404, height: 900 }, ".bar", "chat"],
    ["bar-unfolded", "pull", { width: 821, height: 883 }, ".bar", "chat"],
    ["powai-unfolded", "pull", { width: 821, height: 883 }, ".ai-compose", "ai"],
    ["assist-folded", "assist", { width: 404, height: 900 }, ".assist-ask", ""],
    ["assist-unfolded", "assist", { width: 821, height: 883 }, ".assist-ask", ""],
  ]) {
    runs.push(open(browser, `${ORIGIN}/index.html?mode=${mode}`, `send-dictation-${name}`, viewport).then((r) => whenReady(r, async () => {
      await r.page.evaluate(async (how) => {
        const S = await importShim("./state.ts");
        // A chat under way: Enter (and send) asks, never opens a search hit; "ai": PowOS AI's page, its own compose.
        if (how) (S.chatting.value = true), (S.drawer.value = 1);
        if (how === "ai") S.pullKind.value = "ai";
      }, setup);
      await r.page.waitForSelector(`form${form} .mic`, { timeout: READY_MS });
      const started = await r.page.evaluate(async (f) => (await importShim("./dev/send-dictation-check.js")).sendDictationStart(f), form);
      if (started.length) return started;
      await r.page.screenshot({ path: `/cache/send-dictation-${name}.png` });
      return r.page.evaluate(async (f) => (await importShim("./dev/send-dictation-check.js")).sendDictationEnd(f), form);
    })));
    // Typed text, sent by the button and by Enter: asked once, the field empty after (the user, 2026-10-30 23:08).
    for (const how of ["button", "enter"]) {
      runs.push(open(browser, `${ORIGIN}/index.html?mode=${mode}`, `send-clear-${how}-${name}`, viewport).then((r) => whenReady(r, async () => {
        await r.page.evaluate(async (s) => {
          const S = await importShim("./state.ts");
          if (s) (S.chatting.value = true), (S.drawer.value = 1);
          if (s === "ai") S.pullKind.value = "ai";
        }, setup);
        await r.page.waitForSelector(`form${form} .mic`, { timeout: READY_MS });
        return r.page.evaluate(async (f, h) => (await importShim("./dev/send-dictation-check.js")).sendTypedCheck(f, h), form, how);
      })));
    }
  }
  // AO1/AO2 (the user, 2026-10-30: "It should hide while I'm drawing so that I can draw like under the drawer"; "when
  // I activate it with like a short click, we should still activate the transcription"): the side-button overlay's
  // short press listens at once, and a stroke into the panel's area hides the panel and goes to the drawing
  // (dev/assist-draw-check.js). Renders: /cache/assist-draw-<case>-{mid,after}.png.
  for (const [name, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]]) {
    runs.push(open(browser, `${ORIGIN}/index.html?mode=assist`, `assist-draw-${name}`, viewport).then((r) => whenReady(r, async () => {
      await r.page.waitForSelector("form.assist-ask .mic", { timeout: READY_MS });
      const started = await r.page.evaluate(async () => (await importShim("./dev/assist-draw-check.js")).assistDrawStart());
      await r.page.screenshot({ path: `/cache/assist-draw-${name}-mid.png` });
      if (started.length) return started;
      const ended = await r.page.evaluate(async () => (await importShim("./dev/assist-draw-check.js")).assistDrawEnd());
      await r.page.screenshot({ path: `/cache/assist-draw-${name}-after.png` });
      return ended;
    })));
  }
  // AO3 (the user, 2026-10-31: "I'm starting two microphone conversations"): one dictation at a time - start->start
  // leaves one session, a tap on a mic while another window dictates ends that one instead of starting a second, a
  // superseded dictation leaves nothing pending (dev/mic-one-check.js; the mock's speech counts its sessions).
  for (const [name, mode, form] of [["launcher", "pull", ".bar"], ["assist", "assist", ".assist-ask"]]) {
    runs.push(open(browser, `${ORIGIN}/index.html?mode=${mode}`, `mic-one-${name}`, { width: 404, height: 900 }).then((r) => whenReady(r, async () => {
      await r.page.waitForSelector(`form${form} .mic`, { timeout: READY_MS });
      return r.page.evaluate(async (f) => (await importShim("./dev/mic-one-check.js")).micOneCheck(f), form);
    })));
  }
  // SI1 (the user, 2026-10-31 01:16: "The text inside the search widget and the launcher should be the same"): home's
  // bar and the overlay's are one input - home's typing and dictation partials show in the launcher, a send there clears
  // both, also when home's last dictation words reach the host after the send (dev/bar-sync-check.js: one host for both pages).
  runs.push(Promise.all([
    open(browser, `${ORIGIN}/index.html`, "bar-sync", { width: 404, height: 900 }),
    open(browser, `${ORIGIN}/index.html?mode=pull`, "bar-sync-launcher", { width: 404, height: 900 }),
  ]).then(async ([home, pull]) => {
    const { joinPages, barSyncCheck } = await import(path.join(ROOT, "dev/bar-sync-check.js"));
    const host = await joinPages(home.page, pull.page);
    return whenReady(home, async () => {
      await pull.page.waitForFunction(() => window.__powosAlive === true, { timeout: READY_MS, polling: 50 });
      return [...pull.problems.map((p) => `launcher: ${p}`), ...(await barSyncCheck(home.page, pull.page, host))];
    });
  }));
  runs.push(open(browser, `${ORIGIN}/index.html`, "dock-key-migration", { width: 821, height: 883 }).then((r) => whenReady(r, () => dockKeyMigration(r))));
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
  // The Agents screen and widget in plain words (ui/agents.tsx, fleet.ts): working / needs attention / folded idle.
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html`, "agents-fleet", { width: 412, height: 915 }).then((r) => whenReady(r, () => r.page.evaluate(agentsFleetCheck, FLEET_SETUP))));
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
          for (const step of [desktopReleaseCheck, desktopsCheck, desktopsEdge, dockTapCheck, appMenuCheck, windowTouchCheck, webWindowCheck, PINCH_HELPERS, webWindowPinchCheck, TILE_HELPERS, webWindowTileInputCheck, webWindowTileLayoutCheck, DOCK_HELPERS, webWindowTileDockCheck, webWindowParkCheck, webWindowSnapGhostCheck, TAB_HELPERS, TAB_JUDGES, webWindowTabsCheck, webWindowResizeCheck, webWindowZoneKeepsHome, webWindowRegionsTiled, webWindowRegionsResized, webWindowClearAll, webWindowReloadCheck, GRAB_HELPERS, webWindowGrabCheck, dtHelpers, webDockToggleOne, webDockTogglePage, webDockToggleMany, webDockToggleCell, webDockLaunchFull, ONE_HELPERS, webWindowOneInstance, webWindowOneLauncher, webDockGroupCheck, WW_HELPERS, webWindowMaskCheck]) {
            const problems = await r.page.evaluate(step).catch((e) => { throw new Error(`${step.name}: ${e.message}`); });
            if (problems.length) return problems;
          }
          return [];
        });
        if (s.problems.length) return s;
        await r.page.reload().catch(() => {});
        return whenReady(r, () => r.page.evaluate(desktopsReloaded));
      }),
    );
  // TI1: tiled windows' bars, the w.f touch rects, the divider's pill (the user's layout, 10-31 15:08, unfolded).
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html`, "tile-bars-unfolded", { width: 821, height: 883 }).then((r) => whenReady(r, () => tileBarsScene(r))));
  // SB1: a sideways swipe on the search bar pages home, with and without tiled windows. Folded and unfolded.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `bar-swipe-${label}`, viewport).then((r) => whenReady(r, () => barSwipeScene(r, label))));
  // DL1: a dock app dragged out with no hold, by a finger (dock-lift-*; the user, 10-31 15:12).
  if (process.env.SHELL_PAGES !== "0")
    for (const [kind, query, viewport] of [["folded", "?mode=pull", { width: 404, height: 900 }], ["home", "", { width: 404, height: 900 }], ["right", "", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html${query}`, `dock-lift-${kind}`, viewport).then((r) => whenReady(r, () => dockLiftScene(r, kind))));
  // Edit mode: the search bar as it is, the edit bar below it, the dock in view (the user, 2026-10-30). Folded and unfolded.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport] of [["folded", { width: 404, height: 900 }], ["unfolded", { width: 821, height: 883 }]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `edit-search-${label}`, viewport).then((r) => whenReady(r, async () => r.page.evaluate(editSearchHelpers).then(() => r.page.evaluate(editSearchCheck)))));
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
        const helpers = `window.__sp = { pullUpFrom: ${pullUpFrom}, drawerWithPill: ${drawerWithPill}, closeDrawerNow: ${closeDrawerNow}, searchPutBack: ${searchPutBack}, searchToDock: ${searchToDock}, pillBelowDockInEdit: ${pillBelowDockInEdit}, placeSearchWidget: ${placeSearchWidget}, overlayAsked: ${overlayAsked} }`;
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
  // (ai-still-broken and ai-needs-you-try retired 2026-10-31: Progress no longer lists the board's rows to answer -
  // works / still broken live only on the manager's try messages, which ai-chat checks.)
  // The AI page is one chat: things to try as the manager's message, ⋯ for the rest, older on scroll-up (2026-10-31).
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html`, "ai-chat", { width: 404, height: 900 }).then((r) => whenReady(r, () => aiChatCheck(r.page))));
  // THE backdrop (dev/backdrop-check.js; 2026-10-31 "the launcher ... not using the same dark background"): the widgets,
  // a folder, the shade, the launcher and its PowOS AI panel - one tint, one compositor blur. Both screens.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, viewport, part, query] of [["folded", 404, 900], ["unfolded", 821, 883]].flatMap(([l, width, height]) => [["home", ""], ["apps", "?mode=pull"], ["ai", "?mode=pull"]].map(([p, q]) => [l, { width, height }, p, q])))
      runs.push(open(browser, `${ORIGIN}/index.html${query}`, `backdrop-${part}-${label}`, viewport).then((r) => whenReady(r, async () => {
        const { fails, read } = await r.page.evaluate(async (p) => (await importShim("./dev/backdrop-check.js")).backdrop(p), part);
        if (!fails.length) console.log(`backdrop-${part}-${label}: ${JSON.stringify(read)}`);
        return fails;
      })));
  // The pinned dock never fades (folded: the dock pages to the recent apps; the user, 2026-10-23).
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html`, "dock-no-fade", { width: 404, height: 900 }).then((r) => whenReady(r, () => r.page.evaluate(dockPinnedNoFade))));
  // A dock app dragged out of the dock (ui/dockout.tsx; the user, 2026-10-31 03:00): a half = split screen with the app in
  // front, the middle = a window (unfolded a web window, folded Android's floating one); on home with no app in front it's
  // unpinned onto the grid as before; back on the dock = the dock's.
  if (process.env.SHELL_PAGES !== "0")
    for (const [kind, query, width, height] of [["split", "?mode=pull", 900, 600], ["float", "?mode=pull", 404, 900], ["window", "", 821, 883], ["home", "", 404, 900]])
      runs.push(open(browser, `${ORIGIN}/index.html${query}`, `dock-dragout-${kind}`, { width, height }).then((r) => whenReady(r, () => r.page.evaluate(async (k) => (await importShim("./dev/dock-dragout-check.js")).dockDragOut(k), kind))));
  // The drawer's list fades at an edge with more to scroll (2026-10-24): a short screen, so the mock's apps scroll.
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html?mode=pull`, "scroll-fade", { width: 404, height: 560 }).then((r) => whenReady(r, () => r.page.evaluate(scrollFadeCheck))));
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html?mode=pull`, "launcher-haptics", { width: 404, height: 900 }).then((r) => whenReady(r, () => launcherHapticsCheck(r.page))));
    runs.push(open(browser, `${ORIGIN}/index.html`, "close-up", { width: 404, height: 560 }).then((r) => whenReady(r, () => r.page.evaluate(closeUpCheck))));
  // Unfolded home is one wide page with one bar (hosts/wide.ts, home.tsx; the user, 2026-10-22), migrated from the two
  // side-by-side pages without moving a tile.
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html`, "home-return", { width: 404, height: 900 }).then((r) => whenReady(r, () => r.page.evaluate(homeReturnCheck))));
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html`, "recents-renders", { width: 404, height: 900 }).then((r) => whenReady(r, () => r.page.evaluate(recentsRendersCheck))));
  if (process.env.SHELL_PAGES !== "0")
    runs.push(open(browser, `${ORIGIN}/index.html`, "wide-home", { width: 821, height: 883 }).then((r) => whenReady(r, async () => [...(await r.page.evaluate(wideMigrated)), ...(await r.page.evaluate(wideAcross)), ...(await r.page.evaluate(wideBar)), ...(await r.page.evaluate(wideLauncherBar)), ...(await r.page.evaluate(wideBarParked))])));
    runs.push(open(browser, `${ORIGIN}/index.html?mode=pull`, "launcher-keyboard", { width: 1280, height: 800 }).then((r) => whenReady(r, () => launcherKeyboardKeepsFocus(r.page))));
  // The launcher's dock, opened after PowOS AI's pull (dev/dock-check.js launcherDockOpens - the user, 2026-10-30, the
  // third report: "the dock is still hiding in the launcher in unfolded mode"): unfolded right/bottom with and without the
  // keyboard; folded without it (with it the dock gives way there).
  const dockOpens = [["unfolded", "right", false], ["unfolded", "right", true], ["unfolded", "bottom", false], ["unfolded", "bottom", true], ["folded", "right", false], ["folded", "bottom", false]];
  const dockOpensView = { unfolded: { width: 821, height: 883 }, folded: { width: 404, height: 899 } };
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, position, keyboard] of dockOpens)
      runs.push(open(browser, `${ORIGIN}/index.html?mode=pull`, `launcher-dock-${label}-${position}${keyboard ? "-kbd" : ""}`, dockOpensView[label]).then((r) => whenReady(r, () => r.page.evaluate(async (pos, kb) => (await importShim("./dev/dock-check.js")).launcherDockOpens(pos, kb), position, keyboard))));
  // Home's search as a dock button (dev/dock-search-check.js; the user, 2026-10-31): no .bar, the button centred in the
  // dock, a tap expands it in place focused (not the launcher), folded and unfolded, bottom and side docks.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, position] of [["folded", "bottom"], ["folded", "right"], ["unfolded", "bottom"], ["unfolded", "right"], ["unfolded", "left"]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `dock-search-${label}-${position}`, dockOpensView[label]).then((r) => whenReady(r, () => r.page.evaluate(async (pos) => (await importShim("./dev/dock-search-check.js")).dockSearchCheck(pos), position))));
  // PI1 (dev/page-marks-check.js; the user, 2026-10-31 01:34): the dock marks the apps open on the page on screen - a
  // pill and full opacity for page 1's app, a dot and a fade for page 2's; a swipe to page 2 swaps them; no windows,
  // nothing fades. Folded: a running app's dot only. Renders: /cache/pi1-<case>-<step>.png.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, position] of [["folded", "bottom"], ["folded", "right"], ["unfolded", "bottom"], ["unfolded", "right"]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `page-marks-${label}-${position}`, dockOpensView[label]).then((r) => whenReady(r, async () => {
        const call = (fn, ...args) => r.page.evaluate(async (f, a) => (await importShim("./dev/page-marks-check.js"))[f](...a), fn, args);
        const shot = (step) => r.page.screenshot({ path: `/cache/pi1-${label}-${position}-${step}.png` });
        const unfolded = label === "unfolded";
        const { a, b, pages } = await call("pageMarksSetup", position, unfolded);
        const fails = [];
        if (unfolded && pages < 2) fails.push(`only ${pages} home page(s) to put two windows on`);
        fails.push(...(await call("pageMarksAt", 0, unfolded ? a : null, b, unfolded)));
        await shot("page1");
        if (unfolded) {
          fails.push(...(await call("pageMarksAt", 1, b, a, true)));
          await shot("page2");
        }
        fails.push(...(await call("pageMarksNone", b)));
        await shot("none");
        return fails.map((f) => `${position}: ${f}`);
      })));
  // DK1 + DK2: in dock-button mode the pinned dock stays its pinned apps + the button with running unpinned apps about
  // (same cells, same icon size); a side column has the button as the separator between them and the recent apps.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, position] of [["folded", "bottom"], ["unfolded", "bottom"], ["unfolded", "right"], ["unfolded", "left"]])
      runs.push(open(browser, `${ORIGIN}/index.html`, `dk1-${label}-${position}`, dockOpensView[label]).then((r) => whenReady(r, () => r.page.evaluate(async (pos) => (await importShim("./dev/dock-search-check.js")).dk1Check(pos), position))));
  // DS2: the launcher overlay's side - opened from the button, its bar's glass grows out of it (wider, higher, never
  // fading), a tap's open focused, a hold's dictating, push-to-talk's release leaving the words.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, position] of [["folded", "bottom"], ["unfolded", "bottom"], ["folded", "right"]])
      runs.push(open(browser, `${ORIGIN}/index.html?mode=pull`, `dock-search-launch-${label}-${position}`, dockOpensView[label]).then((r) => whenReady(r, () => r.page.evaluate(async (pos) => (await importShim("./dev/dock-search-check.js")).dockSearchLaunch(pos).then((o) => o.fails), position))));
  // The launcher's panel fits its window (dev/launcher-fit-check.js, LP1/LT1 2026-10-31): PowOS AI's pill above the nav
  // inset or the keyboard, the app grid a row gap under the panel's top - folded and unfolded, every dock side.
  if (process.env.SHELL_PAGES !== "0")
    for (const [label, position, keyboard] of ["unfolded", "folded"].flatMap((l) => ["bottom", "left", "right"].flatMap((p) => [[l, p, false], [l, p, true]])))
      runs.push(open(browser, `${ORIGIN}/index.html?mode=pull`, `launcher-fit-${label}-${position}${keyboard ? "-kbd" : ""}`, dockOpensView[label]).then((r) => whenReady(r, () => r.page.evaluate(async (pos, kb) => (await importShim("./dev/launcher-fit-check.js")).launcherFits(pos, kb), position, keyboard))));
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
  // The render scan (ui/renderscan.ts, renderoverlay.ts): collects while on (a recording, the overlay, a dev session),
  // and when the last user stops Preact's options hooks are the originals again - zero cost when off.
  if (process.env.SHELL_PAGES !== "0" && fs.existsSync(path.join(ROOT, "ui/renderscan.ts")))
    runs.push(open(browser, `${ORIGIN}/index.html`, "render-scan").then((r) => whenReady(r, () => r.page.evaluate(renderScanCheck))));
  // Fold <-> unfold: home's layout and dock change in the first frame after the resize, the screen object lagging
  // (foldSameFrame); a long press that ends with a fold change leaves edit mode off (foldGrip).
  if (process.env.SHELL_PAGES !== "0") {
    runs.push(open(browser, `${ORIGIN}/index.html`, "fold-same-frame", { width: 404, height: 899 }).then((r) => whenReady(r, () => foldSameFrame(r.page))));
    runs.push(open(browser, `${ORIGIN}/index.html`, "fold-grip", { width: 404, height: 899 }).then((r) => whenReady(r, () => foldGrip(r.page))));
  }
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
  // An app's menu (apps.tsx AppMenu) puts it on the control center's quick-launch row and takes it off again
  // (launchers.tsx toggleLauncher, the row's own add/remove): "add to quick launch" -> the shade's row ends with it;
  // then the item reads "remove from quick launch" -> the row no longer has it. Home and the shade are pages of their
  // own (the store between them, as on the phone): the same context, navigated.
  if (process.env.SHELL_PAGES !== "0")
    runs.push(
      open(browser, `${ORIGIN}/index.html`, "quick-launch-menu").then(async (r) => {
        const KEY = "a:discord";
        const ready = () => r.page.waitForFunction(() => window.__powosAlive === true, { timeout: READY_MS, polling: 50 }).catch(() => {});
        // On home: the menu's item for the app, its label, then a tap on it; then the store has the row changed.
        const tapItem = (want) =>
          r.page
            .evaluate(async (key, want) => {
              const S = await window.__gw.mod("./state.ts");
              const { powos } = await window.__gw.mod("./bridge.ts");
              const app = (await powos.apps.list()).find((a) => a.key === key);
              S.menu.value = { app, at: new DOMRect(150, 300, 60, 60) };
              const label = () => [...document.querySelectorAll(".menu-item")].find((b) => /quick launch/.test(b.textContent));
              const t0 = performance.now();
              while (label()?.textContent !== want && performance.now() - t0 < 10000) await new Promise((ok) => setTimeout(ok, 30));
              if (label()?.textContent === want) label().click();
              return label()?.textContent ?? "no quick-launch item";
            }, KEY, want)
            .catch((e) => `evaluate: ${e.message.split("\n")[0]}`);
        const stored = (adding) =>
          r.page
            .waitForFunction(
              async (key, adding) => {
                const { powos } = await window.__gw.mod("./bridge.ts");
                return ((await powos.store.get("controls.launchers")) ?? []).includes(key) === adding;
              },
              { timeout: 20000, polling: 50 },
              KEY,
              adding,
            )
            .then(() => true, () => false);
        const menuStep = async (want) => {
          const got = await tapItem(want);
          if (got !== want) return `the menu shows "${got}", not "${want}"`;
          const adding = want.startsWith("add");
          return (await stored(adding)) ? "" : `after "${want}" the stored row ${adding ? "lacks" : "still has"} ${KEY}`;
        };
        // In the shade (opened as the host opens it): the quick-launch row's keys.
        const row = async () => {
          await r.page.goto(`${ORIGIN}/index.html?mode=shade`).catch(() => {});
          await ready();
          return r.page
            .evaluate(async () => {
              const S = await window.__gw.mod("./state.ts");
              S.notif.value = true;
              const keys = () => [...document.querySelectorAll(".cc3-launchers .cc3-grid:not(.cc3-spare) [data-key]")].map((e) => e.dataset.key);
              await window.__gw.steady(() => keys().join(), 4);
              return keys();
            })
            .catch(() => null);
        };
        await ready();
        const fail = (m) => m && r.problems.push(m);
        fail(await menuStep("add to quick launch"));
        let keys = await row();
        if (keys?.at(-1) !== KEY) fail(`after "add to quick launch" the shade's row is ${JSON.stringify(keys)}, not ending in ${KEY}`);
        await r.page.goto(`${ORIGIN}/index.html`).catch(() => {});
        await ready();
        fail(await menuStep("remove from quick launch"));
        keys = await row();
        if (!keys || keys.includes(KEY)) fail(`after "remove from quick launch" the shade's row is ${JSON.stringify(keys)}`);
        return { ...r, ready: true, ms: Date.now() - r.started };
      }),
    );
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
  // What needs me (apps/needs-me, its UI through --app): the widget on the real host.notifications over mock Discord /
  // WhatsApp / Gmail notifications (MessagingStyle, a RemoteInput reply, mark-as-read), driven as the user does - the rows
  // grouped (one person across two apps), a reply pressing the reply action exactly once with the text, a swipe pressing
  // mark-as-read, and nothing pressed without a gesture.
  if (apps().some((a) => a.id === "local.needs-me"))
    runs.push(open(browser, `${ORIGIN}/__gate_app.html`, "app local.needs-me actions", { width: 404, height: 900 }).then((r) => settleNeedsMe(r)));
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

/** The What needs me case (above): mount, then each gesture, every step in the page (window.__nm); its problems. */
async function settleNeedsMe(r) {
  const steps = [nmMount, nmRows, nmReply, nmSwipe, nmOpen];
  try {
    await r.page.evaluate(() => new Promise((ok) => (window.importShim ? ok() : addEventListener("load", ok))));
    await r.page.evaluate(`window.__nmItems = ${nmItems.toString()}`);
    for (const step of steps) {
      const out = await r.page.evaluate(step);
      r.problems.push(...out);
      if (out.length && step === nmMount) break;
    }
  } catch (e) {
    r.problems.push(`evaluate: ${e.message.split("\n")[0]}`);
  }
  r.problems.push(...r.uncaught);
  return { ...r, ready: true, ms: Date.now() - r.started };
}

/** Mock Discord / WhatsApp / Gmail notifications (and one from a package the app may not read) on the mock bridge. */
function nmItems() {
  const now = Date.now();
  const reply = { title: "Reply", input: true, semantic: 1 };
  const read = { title: "Mark as read", input: false, semantic: 2 };
  const msg = (sender, text, ago) => ({ sender, text, time: now - ago * 1000 });
  const base = { icon: null, clearable: true, profile: null, tappable: true, conversation: true, groupConversation: false };
  const t = (ago) => now / 1000 - ago;
  return [
    { ...base, key: "wa", app: "WhatsApp", pkg: "com.whatsapp", title: "Anna Berg", text: "", time: t(60), actions: [reply, read], messages: [msg("Anna Berg", "Coming tonight?", 60)] },
    { ...base, key: "gm", app: "Gmail", pkg: "com.google.android.gm", title: "Anna Berg", text: "Photos", time: t(600), actions: [{ title: "Archive", input: false }] },
    { ...base, key: "dc", app: "Discord", pkg: "com.discord", title: "#powos", text: "", time: t(300), actions: [read, reply], messages: [msg("kai", "build is green", 300)], conversationTitle: "#powos", groupConversation: true },
    { ...base, key: "other", app: "Signal", pkg: "org.thoughtcrime.securesms", title: "Not ours", text: "hidden", time: t(0) },
  ];
}

/** In the page: the widget on the shell's own host (apps/stdb.ts) over the mock list, every press recorded. */
async function nmMount() {
  const imp = (p) => window.importShim(p);
  const { powos } = await imp("./bridge.ts");
  const P = await imp("./apps/pages.ts");
  const { host } = await imp("./apps/stdb.ts");
  const { h, render } = await imp("preact");
  const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
  const until = async (f, ms = 3000) => {
    for (const end = Date.now() + ms; Date.now() < end; await sleep(25)) if (f()) return true;
    return false;
  };
  const perms = ["notifications:com.discord", "notifications:com.whatsapp", "notifications:com.google.android.gm"];
  P.installedApps.value = [{ id: "local.needs-me", name: "What needs me", version: "0", database: "", tier: 0, manifest: JSON.stringify({ permissions: perms }) }];
  const calls = [];
  const list = { available: true, items: window.__nmItems() };
  Object.assign(powos.notifications, {
    list: async () => list,
    action: async (...a) => void calls.push(["action", ...a]),
    dismiss: async (k) => void calls.push(["dismiss", k]),
    open: async (k) => void calls.push(["open", k]),
  });
  const mod = await imp("./_app/local.needs-me/widgets/main.js");
  const root = Object.assign(document.createElement("div"), { style: "width:360px;height:360px;position:relative;font:14px sans-serif" });
  document.body.append(root);
  render(h(mod.default, { host, app: "local.needs-me", base: "./_app/local.needs-me/", cells: [4, 4] }), root);
  // By the row's group (a long name is shortened to fit, model.ts groupKey): a person's, or a conversation's.
  const row = (name) => [...root.querySelectorAll(".nm-row")].find((r) => r.dataset.group.endsWith(name.toLowerCase()));
  window.__nm = { calls, root, sleep, until, row, said: () => JSON.stringify(calls) };
  if (!(await until(() => row("Anna Berg") && row(":#powos")))) return [`the rows didn't render: "${root.textContent.slice(0, 200)}"`];
  await sleep(800);
  return [];
}

/** Grouped: Anna Berg once for WhatsApp + Gmail, #powos, nothing from Signal - and nothing pressed by showing them. */
async function nmRows() {
  const { root, row, calls, said } = window.__nm;
  const fails = [];
  const n = root.querySelectorAll(".nm-row").length;
  if (n !== 2) fails.push(`${n} rows, want 2 (Anna Berg across WhatsApp + Gmail, #powos; Signal not permitted)`);
  if (row("Anna Berg").querySelectorAll("[data-open]").length !== 2) fails.push("Anna Berg's row doesn't group WhatsApp and Gmail (two app icons)");
  if (root.textContent.includes("Not ours")) fails.push("a notification from a package the manifest doesn't permit shows");
  if (calls.length) fails.push(`pressed without a gesture: ${said()}`);
  return fails;
}

/** Tap the row, type, tap send twice fast: one press of WhatsApp's reply (action 0) with the text, nothing before send. */
async function nmReply() {
  const { row, calls, until, sleep, said } = window.__nm;
  const anna = row("Anna Berg");
  anna.querySelector("[role=button]").click();
  if (!(await until(() => anna.querySelector("form textarea, form input")))) return ["no reply field after tapping the row"];
  const field = anna.querySelector("form textarea, form input");
  Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value").set.call(field, "on my way");
  field.dispatchEvent(new Event("input", { bubbles: true }));
  await sleep(150);
  const before = calls.length ? [`tapping the row or typing pressed something: ${said()}`] : [];
  const send = anna.querySelector("form [type=submit]");
  send.click();
  send.click();
  await sleep(500);
  const ok = said() === JSON.stringify([["action", "wa", 0, "on my way"]]);
  return [...before, ...(ok ? [] : [`reply pressed ${said()}, want once ["action","wa",0,"on my way"]`])];
}

/** Swipe #powos sideways: Discord's own mark-as-read (action 0), once. */
async function nmSwipe() {
  const { row, calls, sleep, said } = window.__nm;
  calls.length = 0;
  const el = row(":#powos").querySelector("[role=button]");
  const box = el.getBoundingClientRect();
  const ev = (t, x) => el.dispatchEvent(new PointerEvent(t, { bubbles: true, clientX: box.left + x, clientY: box.top + box.height / 2, pointerId: 3, isPrimary: true }));
  ev("pointerdown", 20);
  for (let x = 20; x <= 20 + box.width * 0.6; x += 20) ev("pointermove", x);
  ev("pointerup", 20 + box.width * 0.6);
  await sleep(400);
  const ok = calls.length === 1 && JSON.stringify(calls[0].slice(0, 3)) === JSON.stringify(["action", "dc", 0]) && calls[0][3] == null;
  return ok ? [] : [`swipe pressed ${said()}, want once ["action","dc",0] (no text)`];
}

/** A tap on an app icon: that notification's own tap action (contentIntent), once. */
async function nmOpen() {
  const { row, calls, sleep, said, root } = window.__nm;
  calls.length = 0;
  row("Anna Berg").querySelector("[data-open]").click();
  await sleep(200);
  root.remove();
  return said() === JSON.stringify([["open", "wa"]]) ? [] : [`icon tap pressed ${said()}, want once ["open","wa"]`];
}

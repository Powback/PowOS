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

async function open(browser, url, name) {
  // A context (a window) of its own: tabs side by side in one window are hidden but the front one - no frames.
  const page = await (await browser.createBrowserContext()).newPage();
  await page.setViewport({ width: 412, height: 915, deviceScaleFactor: 1 });
  const problems = [];
  const warnings = [];
  await page.setRequestInterception(true);
  page.on("request", (req) => {
    const url = req.url();
    if (!url.startsWith(ORIGIN + "/")) {
      // Off the origin (a mock's socket, a font): never the network, from a gate.
      return url.startsWith("data:") || url.startsWith("blob:") ? req.continue() : req.abort();
    }
    const f = file(url);
    if (f?.virtual) return req.respond({ status: 200, contentType: "text/html", body: appPage() });
    if (!f) return req.respond({ status: 404, contentType: "text/plain", body: "" });
    req.respond({ status: 200, contentType: mime(f.name), body: fs.readFileSync(f.path), headers: { "Cache-Control": "no-store" } });
  });
  page.on("response", (res) => {
    const u = res.url();
    // A module that isn't there: es-module-shims reports it too, this names the file.
    if (res.status() >= 400 && /\.(m?js|tsx?|css)(\?|$)/.test(u)) problems.push(`${res.status()} ${u.replace(ORIGIN + "/", "")}`);
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

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
  // The control center's rearranging (ui/reorder.ts, control.tsx Controls): in edit mode a toggle held and carried onto
  // the first slot of the row lands there, is saved (the store holds it), and is still there after the panel shut and
  // opened again and after a reload; a carry cancelled (the system took the pointer) changes nothing. Every step waits
  // on the state it needs, never on time - CC_THROTTLE (e.g. 6) slows the page's CPU to check that it holds.
  if (process.env.SHELL_PAGES !== "0") {
    const ccOrder = () => [...document.querySelectorAll(".cc3-quick [data-key]")].map((e) => e.dataset.key);
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
            const item = (k) => document.querySelector(`.cc3-quick [data-key="${k}"]`);
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
                await until(() => document.querySelector(".cc3-quick .carried"), "the lift (a long press)");
                return [x, y];
              };
              // Carried part of the way, then cancelled: nothing changes.
              let [x, y] = await lift();
              let [tx, ty] = mid(item(before[0]));
              P(item(k0), "pointermove", (x + tx) / 2, (y + ty) / 2);
              await until(() => order().indexOf(k0) < 2, "the row making room", 5000).catch(() => {});
              P(item(k0), "pointercancel", tx, ty);
              await until(() => !document.querySelector(".cc3-quick .carried"), "the copy gone after a cancel");
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
              await until(() => !document.querySelector(".cc3-quick .carried"), "the copy gone after landing");
              if (order()[0] !== k0) fails.push(`carried ${k0} onto the first slot, it landed at ${order().indexOf(k0)} (${order().join(",")})`);
              // Saved: the store has it first among the row's.
              const savedFirst = async () => {
                const l = await powos.store.get("controls.layout");
                return (l?.order ?? []).filter((id) => before.includes(id))[0];
              };
              const t0 = performance.now();
              while ((await savedFirst()) !== k0 && performance.now() - t0 < 10000) await sleep(50);
              if ((await savedFirst()) !== k0) fails.push(`saved order has ${await savedFirst()} first, not ${k0}`);
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

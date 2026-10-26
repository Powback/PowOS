/**
 * The widget preview's browser half (shell/dev/preview.sh runs it in the gate's headless Chromium, in passes):
 *
 *   PASS=plan     the widgets (/work/owl/*.owl, /apps/<id>/powos-app.json islands, the shell's panels) and every size
 *                 each allows, minSize to 4x4, on the cover screen's cells and the inner screen's -> /work/widgets.json
 *                 and /work/batch.json (what `owl trees --batch` evaluates, per theme);
 *   PASS=measure  each OWL widget's sheet drawn once with those trees, the size each Canvas reported -> batch.json again
 *                 (Canvas code draws to its own size: the second trees are drawn at the measured ones, as on the phone);
 *   PASS=render   every sheet per theme: drawn, the fit checks run (dev/preview/sheet.tsx check()), shot; a widget with
 *                 a screen (its onTap's screen()) opened full size on each screen too, its backdrop checked; one
 *                 contact sheet per widget -> /out/<widget>.png, /out/report.json, and a line per failure on stdout.
 *
 * Mounted: /shell (the composed shell), /work, /out; optionally /apps (built PowOS apps: <id>/powos-app.json + ui/),
 * /wallpaper.jpg. Env: PREVIEW_THEMES ("gruvbox nord"), PREVIEW_ONLY (a regex over widget ids), PREVIEW_LIVE (1: http
 * sources fetched for real), PREVIEW_EMPTY (the unfilled threshold, 0.12).
 */
import fs from "node:fs";
import path from "node:path";
import puppeteer from "puppeteer";

const ORIGIN = "https://shell.powos";
const ROOT = "/shell";
const WORK = "/work";
const OUT = "/out";
const APPS = "/apps";
const PASS = process.env.PASS || "render";
const THEMES = (process.env.PREVIEW_THEMES || "gruvbox nord").split(/\s+/).filter(Boolean);
const ONLY = process.env.PREVIEW_ONLY ? new RegExp(process.env.PREVIEW_ONLY) : null;
const EMPTY = Number(process.env.PREVIEW_EMPTY || 0.12);
const COVER = Number(process.env.PREVIEW_COVER || 0.25);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
/** The gate's quick run: checks only (no contact sheets), the first theme, the cover screen's screen. */
const FAST = process.env.PREVIEW_FAST === "1";
const JOBS = Number(process.env.PREVIEW_JOBS || 3);
/**
 * [items] through [f], [JOBS] at a time, each worker with a browser of its own: several pages of one browser at once
 * are background tabs, and a background tab's screenshot waits for a frame that doesn't come (it hung for minutes).
 */
async function pool(items, f) {
  const out = [];
  let i = 0;
  await Promise.all(
    Array.from({ length: Math.min(JOBS, items.length) }, async () => {
      const b = await launch();
      try {
        while (i < items.length) {
          const k = i++;
          out[k] = await f(items[k], b);
        }
      } finally {
        await b.close();
      }
    }),
  );
  return out;
}

/**
 * The phone's two screens (OnePlus Open, 2.7625 px a CSS px): their size, and home's grid cell there (6 columns;
 * measured on the phone 2026-10-21: the cover's tiles are 63.3 x 68.1 a cell - grid.tsx measure() - and the inner
 * screen's from the same arithmetic over its 821 x 883).
 */
const SCREENS = {
  folded: { width: 404, height: 899, cell: [63.33, 68.1], insets: { top: 45.6, bottom: 16.3 } },
  unfolded: { width: 821, height: 883, cell: [132.83, 133.4], insets: { top: 45.6, bottom: 16.3 } },
};
/** .home-tile's padding: the face is the box less half the gap each side. */
const GAP = 8;
const MAX = [4, 4];

const mime = (p) =>
  ({ html: "text/html", js: "text/javascript", mjs: "text/javascript", ts: "text/plain", tsx: "text/plain", css: "text/css", json: "application/json",
    wasm: "application/wasm", svg: "image/svg+xml", png: "image/png", jpg: "image/jpeg", webp: "image/webp", woff2: "font/woff2", ttf: "font/ttf" })[
    p.slice(p.lastIndexOf(".") + 1).toLowerCase()
  ] ?? "application/octet-stream";

/** A theme's colors.toml (shell/dev/preview/themes/<name>.toml, Omarchy's), as the host's ThemeColors. */
function theme(name) {
  const t = Object.fromEntries(
    fs.readFileSync(path.join(ROOT, "dev/preview/themes", `${name}.toml`), "utf8").split("\n").map((l) => l.match(/^\s*([\w-]+)\s*=\s*"([^"]*)"/)).filter(Boolean).map((m) => [m[1], m[2]]),
  );
  const css = {
    background: t.background, surface: t.lighter_background, overlay: `color-mix(in srgb, ${t.background} 90%, transparent)`, foreground: t.foreground,
    muted: t.dark_foreground, accent: t.accent, border: t.muted, red: t.red, green: t.green,
  };
  return { name, light: t.mode === "light", css, colors: t };
}

const sizes = (min) => {
  const out = [];
  for (let r = Math.min(min[1], MAX[1]); r <= Math.max(min[1], MAX[1]); r++)
    for (let c = Math.min(min[0], MAX[0]); c <= Math.max(min[0], MAX[0]); c++) if (c >= min[0] && r >= min[1]) out.push([c, r]);
  return out.length ? out : [min];
};

function cellsFor(id, min) {
  const cells = [];
  for (const [screen, s] of Object.entries(SCREENS))
    for (const [c, r] of sizes(min)) {
      const w = Math.round(c * s.cell[0] * 10) / 10;
      const h = Math.round(r * s.cell[1] * 10) / 10;
      cells.push({ key: `${id}@${screen}-${c}x${r}`, label: `${c}x${r} · ${Math.round(w - GAP)}x${Math.round(h - GAP)}`, screen, cols: c, rows: r, w, h });
    }
  return cells;
}

/** Every widget there is to preview. */
function plan() {
  const widgets = [];
  const owlDir = path.join(WORK, "owl");
  for (const f of fs.existsSync(owlDir) ? fs.readdirSync(owlDir).filter((f) => f.endsWith(".owl")).sort() : []) {
    const src = fs.readFileSync(path.join(owlDir, f), "utf8");
    const size = (k) => src.match(new RegExp(`^\\s*${k}:\\s*(\\d+)x(\\d+)`, "m"))?.slice(1).map(Number);
    const id = f.replace(/\.owl$/, "");
    const name = src.match(/^\s*widget\s+"([^"]+)"/m)?.[1] ?? id;
    const terminal = /\bTerminal\s*\{/.test(src);
    widgets.push({ id, kind: "owl", title: `${name} (${f}, OWL)`, file: f, minSize: size("minSize") ?? [1, 1], screen: /^\s*screen\s*\{/m.test(src), terminal, term: terminal ? "full" : undefined });
    // A terminal's ink is what its shell holds: measured as used (bridge.ts mockTranscript) - a screen full of output,
    // and a short one (one command and the prompt).
    if (terminal)
      widgets.push({ id: `${id}-short`, kind: "owl", title: `${name}, a short session (${f}, OWL)`, file: f, minSize: size("minSize") ?? [1, 1], screen: false, terminal, term: "short" });
    // Data variants: dev/preview/data/<id>~<variant>.json is the same widget measured again with those values - the
    // widest ones a widget must still fit (-13°, 100%: a "13°" cut to "1…" on the phone passed with the mock's 5°).
    for (const d of fs.existsSync(path.join(WORK, "data")) ? fs.readdirSync(path.join(WORK, "data")).sort() : []) {
      const m = d.match(new RegExp(`^${id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}~([\\w-]+)\\.json$`));
      if (m) widgets.push({ id: `${id}~${m[1]}`, kind: "owl", title: `${name}, ${m[1]} (${f}, OWL)`, file: f, minSize: size("minSize") ?? [1, 1], screen: false, terminal });
    }
  }
  for (const app of fs.existsSync(APPS) ? fs.readdirSync(APPS).sort() : []) {
    const mf = path.join(APPS, app, "powos-app.json");
    if (!fs.existsSync(mf)) continue;
    const m = JSON.parse(fs.readFileSync(mf, "utf8"));
    for (const w of m.widgets ?? []) {
      if (!w.entry) continue;
      const min = String(w.minSize ?? w.size ?? "2x1").split("x").map(Number);
      const data = path.join(WORK, "data", `${m.id}.json`);
      widgets.push({ id: `${m.id}.${w.id}`, kind: "island", title: `${m.name ?? m.id}: ${w.name ?? w.id} (PowOS app island)`, app: m.id, entry: w.entry, minSize: min,
        data: fs.existsSync(data) ? JSON.parse(fs.readFileSync(data, "utf8")) : undefined });
      // Island data variants too: data/<app>~<variant>.json (e.g. local.lights~offline - the bridge unreachable from
      // mobile data: the calm line, never the raw "failed to connect to (192.168...)" wrapped and cut).
      for (const d of fs.readdirSync(path.join(WORK, "data")).sort()) {
        const v = d.match(new RegExp(`^${m.id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}~([\\w-]+)\\.json$`));
        if (v) widgets.push({ id: `${m.id}.${w.id}~${v[1]}`, kind: "island", title: `${m.name ?? m.id}: ${w.name ?? w.id}, ${v[1]} (PowOS app island)`, app: m.id, entry: w.entry,
          minSize: min, data: JSON.parse(fs.readFileSync(path.join(WORK, "data", d), "utf8")) });
      }
    }
  }
  for (const p of ["agents", "recents"]) widgets.push({ id: `panel.${p}`, kind: "panel", title: `${p} (shell panel)`, panel: p, minSize: [2, 1] });
  // The Agents widget with nobody running, as home often is: only sessions that finished lately, and nothing at all.
  // [agents]: the mock's agents replaced (sheet.tsx Panel) - role, state, title, step, report, ms ago.
  const gone = (role, title, report, ago) => ({ role, state: "gone", title, step: "", report, ago });
  widgets.push({ id: "panel.agents-idle", kind: "panel", title: "agents, nobody running (shell panel)", panel: "agents", minSize: [2, 1],
    agents: [gone("coder", "hosted widgets", "pushed 3 commits, gate green", 1_500_000), gone("devops", "prune old images", "freed 106 GB", 5_400_000),
      gone("reviewer", "review the drawer", "2 nits, approved", 9_000_000)] });
  widgets.push({ id: "panel.agents-empty", kind: "panel", title: "agents, none at all (shell panel)", panel: "agents", minSize: [2, 1], agents: [] });
  const chosen = widgets.filter((w) => !ONLY || ONLY.test(w.id));
  for (const w of chosen) w.cells = cellsFor(w.id, w.minSize);
  fs.writeFileSync(path.join(WORK, "widgets.json"), JSON.stringify(chosen, null, 1));
  writeBatch(chosen, {});
  console.log(`plan: ${chosen.length} widgets, ${chosen.reduce((n, w) => n + w.cells.length, 0)} tile sizes, themes ${THEMES.join(" ")}`);
}

/** `owl trees --batch` jobs: per OWL widget and theme; [canvas]: sizes measured, by tile key. */
function writeBatch(widgets, canvas) {
  const jobs = [];
  fs.mkdirSync(path.join(WORK, "trees"), { recursive: true });
  for (const w of widgets.filter((w) => w.kind === "owl"))
    for (const t of THEMES) {
      const data = path.join(WORK, "data", `${w.id}.json`);
      jobs.push({
        file: path.join(WORK, "owl", w.file),
        theme: path.join(WORK, "themes", `${t}.toml`),
        data: fs.existsSync(data) ? data : null,
        live: process.env.PREVIEW_LIVE === "1",
        out: path.join(WORK, "trees", `${w.id}.${t}.json`),
        variants: [
          ...w.cells.map((c) => ({ id: c.key, cols: c.cols, rows: c.rows, w: c.w - GAP, h: c.h - GAP, screen: null, canvas: canvas[c.key] ?? {} })),
          // The screen, at each screen's size (its panel's body: a little less, measured in the render pass).
          ...(w.screen
            ? Object.entries(SCREENS).map(([s, d]) => ({ id: `${w.id}@screen-${s}`, cols: 0, rows: 0, w: 0, h: 0, screen: [d.width - 32, d.height - 140], canvas: canvas[`${w.id}@screen-${s}#screen`] ?? {} }))
            : []),
        ],
      });
    }
  // The batch is read by the JVM in another container: the work folder is mounted at the same path there (preview.sh).
  const host = process.env.HOST_WORK || WORK;
  const fix = (p) => (p ? p.replace(WORK, host) : p);
  fs.writeFileSync(path.join(WORK, "batch.json"), JSON.stringify(jobs.map((j) => ({ ...j, file: fix(j.file), theme: fix(j.theme), data: fix(j.data), out: fix(j.out) }))));
}

/** The served shell: /shell, the trees of [themeName] as the mock's dev/sample-trees.json, apps under _app/. */
function serve(page, themeName) {
  const trees = {};
  for (const f of fs.existsSync(path.join(WORK, "trees")) ? fs.readdirSync(path.join(WORK, "trees")) : [])
    if (f.endsWith(`.${themeName}.json`)) {
      const t = JSON.parse(fs.readFileSync(path.join(WORK, "trees", f), "utf8"));
      for (const [k, v] of Object.entries(t)) if (k !== "meta" && k !== "errors") trees[k] = v;
    }
  const treesJson = JSON.stringify(trees);
  return page.setRequestInterception(true).then(() =>
    page.on("request", (req) => {
      const url = req.url();
      if (!url.startsWith(ORIGIN + "/")) return url.startsWith("data:") || url.startsWith("blob:") ? req.continue() : req.abort();
      let p = decodeURIComponent(new URL(url).pathname).replace(/^\/+/, "") || "index.html";
      if (p.split("/").includes("..")) return req.respond({ status: 404, body: "" });
      if (p === "dev/sample-trees.json") return req.respond({ status: 200, contentType: "application/json", body: treesJson });
      let f;
      if (p === "__wallpaper.jpg") f = "/wallpaper.jpg";
      else if (p.startsWith("_app/")) {
        const [, id, ...rest] = p.split("/");
        f = path.join(APPS, id, "ui", rest.join("/"));
      } else f = path.join(ROOT, p);
      if (!fs.existsSync(f) || !fs.statSync(f).isFile()) return req.respond({ status: 404, contentType: "text/plain", body: "" });
      req.respond({ status: 200, contentType: mime(p), body: fs.readFileSync(f), headers: { "Cache-Control": "no-store" } });
    }),
  );
}

const FALLBACK_WP =
  "data:image/svg+xml," +
  encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="900"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">` +
      `<stop offset="0" stop-color="#2b3a55"/><stop offset=".5" stop-color="#6b4f6f"/><stop offset="1" stop-color="#c28f6a"/></linearGradient></defs>` +
      `<rect width="400" height="900" fill="url(#g)"/><circle cx="300" cy="250" r="120" fill="#e9c46a" opacity=".55"/><circle cx="90" cy="640" r="160" fill="#2a9d8f" opacity=".45"/></svg>`,
  );

/**
 * Home booted against the mock, in [t], over the wallpaper, home's glass as the compositor draws it (a screen-sized
 * page); [frosted]: a sheet's long page instead - the wallpaper frosted once behind it all (a live blur per tile over
 * thousands of px is minutes of software rendering), which is what each tile shows.
 */
async function boot(browser, t, viewport, frosted = false) {
  const page = await browser.newPage();
  await page.setViewport({ ...viewport, deviceScaleFactor: 1 });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message.split("\n")[0]));
  await serve(page, t.name);
  await page.goto(`${ORIGIN}/index.html`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.__powosAlive === true, { timeout: 15000, polling: 50 }).catch(() => errors.push("home not ready"));
  const wp = fs.existsSync("/wallpaper.jpg") ? `${ORIGIN}/__wallpaper.jpg` : FALLBACK_WP;
  await page.evaluate(
    async (t, wp, frosted) => {
      const root = document.documentElement;
      window.__mockEvents?.emit("theme.changed", { name: t.name, light: t.light, css: t.css, colors: t.colors });
      await new Promise((r) => setTimeout(r, 300));
      const st = document.createElement("style");
      st.textContent = frosted
        ? `html { background: #1b1b1f url("${wp}") center top / 100% auto repeat-y; }`
        : `html { background: url("${wp}") center / cover no-repeat fixed; }` +
          `.glass-native :is(.tile, .notif-panel):not(:is(.tile, .notif-panel) *) { backdrop-filter: blur(30px); }`;
      document.head.append(st);
      root.classList.add("glass-native");
    },
    t,
    wp,
    frosted,
  );
  return { page, errors };
}

const dbg = (...a) => process.env.PREVIEW_DEBUG && console.log("   ", ...a);
async function sheet(browser, w, t, max) {
  const { page, errors } = await boot(browser, t, { width: max, height: 900 }, true);
  dbg(w.id, t.name, "booted", errors.join("; "));
  await page.evaluate(async (spec) => {
    window.__powosMockTerm = spec.term;
    const m = await importShim("./dev/preview/sheet.tsx");
    window.__pv = m;
    await m.mount(spec);
  }, { title: w.title, kind: w.kind, app: w.app, entry: w.entry, panel: w.panel, data: w.data, agents: w.agents, term: w.term, cells: w.cells });
  dbg(w.id, t.name, "mounted", process.env.PREVIEW_DEBUG ? await page.evaluate(() => [...document.fonts].map((f) => `${f.family}:${f.status}`).join(" ")) : "");
  return { page, errors };
}

/** The widget's screen opened as its onTap's screen() opens it, over home, at [s]; and the backdrop's check. */
async function screenShot(browser, w, t, sName, s) {
  const { page, errors } = await boot(browser, t, { width: s.width, height: s.height });
  const key = `${w.id}@screen-${sName}`;
  await page.evaluate(async (key, title, insets) => {
    document.documentElement.style.setProperty("--inset-top", `${insets.top}px`);
    document.documentElement.style.setProperty("--inset-bottom", `${insets.bottom}px`);
    const S = await importShim("./state.ts");
    S.screen.value = { key, title, terminal: false };
  }, key, w.title.split(" (")[0], s.insets);
  await sleep(1100);
  const shot = await page.screenshot({ encoding: "base64" });
  // What's behind showing through: the same frame over a page of large, high-contrast text; the difference's detail
  // inside the panel is what of it can be read.
  const res = await page.evaluate(async (shot, EMPTY) => {
    const panel = document.querySelector(".screen-panel");
    if (!panel) return { problems: ["no screen panel"] };
    const pr = panel.getBoundingClientRect();
    const problems = [];
    // Its content's width: charts and lists across the panel's body.
    const body = panel.querySelector(".screen-body .owl") ?? panel;
    const br = body.getBoundingClientRect();
    const cs = getComputedStyle(body);
    const inner = { left: br.left + parseFloat(cs.paddingLeft), right: br.right - parseFloat(cs.paddingRight) };
    const narrow = [];
    for (const el of body.querySelectorAll("canvas, svg, .owl > div > *")) {
      if (el.closest("svg") && el.tagName !== "svg") continue;
      // Blocks stacked down the screen: a chart or list; not a bar sharing a row with its labels.
      if (getComputedStyle(el.parentElement).flexDirection === "row") continue;
      const r = el.getBoundingClientRect();
      if (r.width < 40 || r.height < 6) continue;
      const fill = (r.right - r.left) / (inner.right - inner.left);
      if ((el.tagName === "CANVAS" || el.tagName === "svg" || el.style.display === "grid" || el.childElementCount > 2) && fill < 1 - EMPTY && fill > 0)
        narrow.push(`${el.tagName.toLowerCase()} ${Math.round(fill * 100)}% wide`);
    }
    if (narrow.length) problems.push(`content not across the screen: ${[...new Set(narrow)].slice(0, 4).join(", ")}`);
    for (const el of panel.querySelectorAll("*")) {
      const c = getComputedStyle(el);
      const bw = parseFloat(c.borderTopWidth);
      if (bw >= 1 && c.borderTopStyle !== "none" && !/rgba\(0, 0, 0, 0\)|transparent/.test(c.borderTopColor)) {
        problems.push("hard border");
        break;
      }
    }
    // The backdrop: text behind it, in the foreground colour - what of it shows through.
    const under = document.createElement("div");
    under.style.cssText = "position:fixed;inset:0;z-index:0;pointer-events:none;font:700 28px/1.2 sans-serif;color:var(--color-foreground);overflow:hidden;word-break:break-all";
    under.textContent = "BEHIND ".repeat(400);
    document.body.prepend(under);
    const scrim = panel.closest(".screen-scrim") ?? panel;
    // Under the sheet: everything of the page but it sits under it already; the text joins them.
    for (const el of document.body.children) if (!el.contains(scrim) && el !== under) el.style.visibility = "hidden";
    await new Promise((r) => setTimeout(r, 400));
    return { problems, rect: { x: pr.left, y: pr.top, w: pr.width, h: pr.height } };
  }, shot, EMPTY);
  if (res.rect) {
    const withText = await page.screenshot({ encoding: "base64" });
    // Undo: the same page without the text, home hidden too - so only the text differs.
    await page.evaluate(() => document.body.firstElementChild.remove());
    await sleep(300);
    const without = await page.screenshot({ encoding: "base64" });
    const detail = await page.evaluate(async (a, b, r) => {
      const load = async (s) => {
        const i = new Image();
        i.src = "data:image/png;base64," + s;
        await i.decode();
        const c = document.createElement("canvas");
        c.width = i.width;
        c.height = i.height;
        const g = c.getContext("2d");
        g.drawImage(i, 0, 0);
        return g.getImageData(Math.round(r.x), Math.round(r.y), Math.max(1, Math.round(r.w)), Math.max(1, Math.round(r.h)));
      };
      const [x, y] = [await load(a), await load(b)];
      const W = x.width;
      const H = x.height;
      const d = new Float32Array(W * H);
      for (let i = 0; i < W * H; i++) d[i] = Math.abs(x.data[i * 4] - y.data[i * 4]) + Math.abs(x.data[i * 4 + 1] - y.data[i * 4 + 1]) + Math.abs(x.data[i * 4 + 2] - y.data[i * 4 + 2]);
      // Detail, not a tint: the difference's own edges (legible text has them; a frosted blur of it doesn't). Measured:
      // a sheet frosted 30 px over the text scored 3-5 here.
      let e = 0;
      for (let yy = 0; yy < H - 1; yy++) for (let xx = 0; xx < W - 1; xx++) e += Math.abs(d[yy * W + xx] - d[yy * W + xx + 1]) + Math.abs(d[yy * W + xx] - d[(yy + 1) * W + xx]);
      return e / (W * H);
    }, withText, without, res.rect);
    if (detail > 12) res.problems.push(`backdrop shows what's behind (detail ${detail.toFixed(1)})`);
  }
  await page.close();
  return { shot, problems: [...res.problems, ...errors.map((e) => `error: ${e}`)] };
}

async function compose(browser, w, perTheme, screens, problems) {
  const img = (b64, cls = "") => `<img class="${cls}" src="data:image/png;base64,${b64}">`;
  const cols = perTheme.map(({ t, png }) => `<td><div class="t">${t}</div>${img(png)}</td>`).join("");
  const scr = screens.length
    ? `<h2>its screen (tap)</h2><div class="scr">${screens.map((s) => `<figure>${img(s.shot, s.screen === "folded" ? "f" : "u")}<figcaption>${s.theme} · ${s.screen}${s.problems.length ? `<br><b>${s.problems.join("<br>")}</b>` : ""}</figcaption></figure>`).join("")}</div>`
    : "";
  const n = problems.length;
  const html = `<html><head><style>
    body { margin: 0; background: #151515; color: #ddd; font: 13px monospace; padding: 10px 14px; }
    h1 { font-size: 17px; margin: 4px 0 8px; } h1 small { color: ${n ? "#f77" : "#7c7"}; font-weight: normal; }
    h2 { font-size: 14px; margin: 14px 0 6px; }
    td { vertical-align: top; padding-right: 12px; } .t { margin: 0 0 4px; color: #aaa; }
    td img { display: block; max-width: 1400px; }
    .scr { display: flex; gap: 14px; flex-wrap: wrap; } figure { margin: 0; } figcaption { color: #aaa; margin-top: 4px; max-width: 420px; }
    figure b { color: #f77; font-weight: normal; } img.f { width: 270px; } img.u { width: 420px; }
  </style></head><body><h1>${w.title} <small>${n ? `${n} fit problem${n > 1 ? "s" : ""}` : "fits at every size"}</small></h1>
    <table><tr>${cols}</tr></table>${scr}</body></html>`;
  const page = await browser.newPage();
  await page.setViewport({ width: 1200, height: 800, deviceScaleFactor: 1 });
  await page.setContent(html, { waitUntil: "load" });
  await page.screenshot({ path: path.join(OUT, `${w.id}.png`), fullPage: true });
  await page.close();
}

const launch = () => puppeteer.launch({
  executablePath: process.env.CHROME || "/usr/bin/chromium-browser",
  headless: true,
  // Several pages at once (PREVIEW_JOBS): none of them is the front tab, and a backgrounded page's frames (and so its
  // screenshots) wait - minutes - unless Chromium is told not to throttle them.
  args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--no-first-run", "--mute-audio", "--font-render-hinting=none",
    "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows"],
  protocolTimeout: 300000,
});
const browser = await launch();
let failed = 0;
try {
  if (PASS === "plan") plan();
  else {
    const widgets = JSON.parse(fs.readFileSync(path.join(WORK, "widgets.json"), "utf8"));
    if (PASS === "measure") {
      const canvas = {};
      const t = theme(THEMES[0]);
      await pool(
        widgets.filter((w) => w.kind === "owl"),
          async (w, browser) => {
            const { page } = await sheet(browser, w, t, 1900);
            const got = await page.evaluate(() => window.__pv.canvasSizes());
            if (process.env.PREVIEW_DEBUG) console.log(`measure ${w.id}: ${JSON.stringify(got).slice(0, 300)} canvases in page: ${await page.evaluate(() => document.querySelectorAll("#pv-root canvas").length)}`);
            Object.assign(canvas, got);
            // The screens' canvases: the screen's own page.
            if (w.screen)
              for (const [sName, s] of Object.entries(SCREENS).slice(0, FAST ? 1 : 2)) {
                const b = await boot(browser, t, { width: s.width, height: s.height });
                // sheet.tsx first: it's what records the canvases' sizes.
                await b.page.evaluate(async (key) => {
                  window.__pv = await importShim("./dev/preview/sheet.tsx");
                  (await importShim("./state.ts")).screen.value = { key, title: "", terminal: false };
                }, `${w.id}@screen-${sName}`);
                await sleep(900);
                const m = await b.page.evaluate(() => window.__pv.canvasSizes());
                for (const [k, v] of Object.entries(m)) canvas[`${k}#screen`] = v;
                await b.page.close();
              }
            await page.close();
          },
      );
      writeBatch(widgets, canvas);
      console.log(`measure: ${Object.keys(canvas).length} tiles with canvases`);
    } else {
      const report = {};
      const lines = await pool(widgets, async (w, b) => {
        const t0 = Date.now();
        let timer;
        const limit = new Promise((_, no) => (timer = setTimeout(() => no(new Error("timed out (240 s)")), 240000)));
        const r = await Promise.race([one(w, b), limit]).catch((e) => {
          report[w.id] = { title: w.title, kind: w.kind, problems: [`preview failed: ${e.message.split("\n")[0]}`], sheet: null };
          return [w.id, report[w.id].problems];
        });
        clearTimeout(timer);
        if (process.env.PREVIEW_DEBUG) console.log(`  ${w.id}: ${Date.now() - t0} ms`);
        return r;
      });
      async function one(w, browser) {
        let fill = {};
        const perTheme = [];
        const problems = [];
        const screens = [];
        for (const name of FAST ? THEMES.slice(0, 1) : THEMES) {
          const t = theme(name);
          const { page, errors } = await sheet(browser, w, t, 1500);
          const found = await page.evaluate((e, c) => window.__pv.check(e, c), EMPTY, COVER);
          if (name === THEMES[0]) fill = await page.evaluate(() => ({ ...window.__pv.fills }));
          if (process.env.PREVIEW_DEBUG_KEY)
            console.log(await page.evaluate((k) => [...document.querySelectorAll(`.pv-cell[data-key="${k}"] .owl div`)].filter((e) => [...e.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())).map((e) => `${e.textContent.slice(0, 12)} sw=${e.scrollWidth} cw=${e.clientWidth} ov=${getComputedStyle(e).overflowX}`).join("\n"), process.env.PREVIEW_DEBUG_KEY));
          await sleep(100);
          if (!FAST) perTheme.push({ t: name, png: await page.screenshot({ encoding: "base64", fullPage: true }) });
          for (const [key, list] of Object.entries(found)) {
            const c = w.cells.find((c) => c.key === key);
            for (const p of list) problems.push(`${c.screen} ${c.cols}x${c.rows} (${name}): ${p}`);
          }
          for (const e of new Set(errors)) problems.push(`(${name}) page error: ${e}`);
          await page.close();
          if (w.kind === "owl" && w.screen && !w.terminal)
            for (const [sName, s] of Object.entries(SCREENS).slice(0, FAST ? 1 : 2)) {
              const r = await screenShot(browser, w, t, sName, s);
              screens.push({ ...r, theme: name, screen: sName });
              for (const p of r.problems) problems.push(`screen ${sName} (${name}): ${p}`);
            }
        }
        const trees = THEMES.map((t) => path.join(WORK, "trees", `${w.id}.${t}.json`)).filter((f) => fs.existsSync(f));
        for (const f of trees.slice(0, 1)) for (const e of JSON.parse(fs.readFileSync(f, "utf8")).errors ?? []) problems.push(`widget error: ${e}`);
        if (!FAST) await compose(browser, w, perTheme, screens, problems);
        // Each tile's fill (% of it the content covers), by size: "folded 3x2": 41.
        const fills = Object.fromEntries(w.cells.map((c) => [`${c.screen} ${c.cols}x${c.rows}`, fill[c.key]]));
        report[w.id] = { title: w.title, kind: w.kind, problems, fills, sheet: FAST ? null : `${w.id}.png` };
        return [w.id, problems];
      }
      // Known problems (the gate's baseline, dev/preview/baseline.json): listed, not failed - a new one fails.
      const known = fs.existsSync(path.join(ROOT, "dev/preview/baseline.json")) && process.env.PREVIEW_BASELINE !== "0" ? JSON.parse(fs.readFileSync(path.join(ROOT, "dev/preview/baseline.json"), "utf8")) : {};
      // Compared without the theme and the exact amounts (a percentage moves with a font's metrics).
      // Quoted text without its digits too (a clock's "09:18").
      const norm = (p) =>
        p.replace(/ \((gruvbox|nord|[a-z-]+)\)/, "").replace(/\d+(\.\d+)?%/g, "N%").replace(/detail [\d.]+/, "detail N").replace(/"[^"]*"/g, (q) => q.replace(/\d/g, "N"));
      const baseline = {};
      for (const [id, problems] of lines) {
        const old = new Set(known[id] ?? []);
        const fresh = problems.filter((p) => !old.has(norm(p)));
        if (problems.length) baseline[id] = [...new Set(problems.map(norm))];
        report[id].new = fresh;
        if (fresh.length) failed++;
        const tag = fresh.length ? "FAIL" : problems.length ? "known" : "ok  ";
        console.log(`${tag} ${id}${problems.length ? `: ${fresh.length} new, ${problems.length - fresh.length} known fit problem(s)` : ""}`);
        for (const p of fresh.slice(0, 40)) console.log(`       ${p}`);
      }
      fs.writeFileSync(path.join(OUT, "report.json"), JSON.stringify(report, null, 1));
      fs.writeFileSync(path.join(OUT, "baseline.json"), JSON.stringify(baseline, null, 1));
    }
  }
} finally {
  await browser.close();
}
process.exit(failed ? 1 : 0);

/**
 * Design QA's renders (shell/dev/gate.sh --shots DIR runs it, in the gate's headless Chromium, after the boot check):
 * every surface of the shell - home's pages, edit mode, the widget picker, the theme popover, the drawer, search idle
 * and typing, PowOS AI's page and its compose, the assistant, the shade and the control center, the switcher, the lock
 * face, the settings screen - at the phone's two screens (the cover: 404x899 CSS px, the inner: 821x883), over a
 * wallpaper, in a theme, as the phone draws them (insets, html.glass-native emulated: the compositor's blur behind each
 * surface is a backdrop-filter here). docs/DESIGN-LANGUAGE.md is what they're judged against.
 *
 * Out: DIR/<scene>-<folded|unfolded>.png, and DIR/report.json - per shot, the text below 4.5:1 contrast (3:1 for
 * large text) against what is actually drawn behind it (the shot again with all text transparent, the box's pixels
 * averaged), and the page's errors.
 *
 * Mounted: /shell (the composed shell), /out (DIR), optionally /wallpaper.jpg. Env: SHOTS_THEME (gruvbox|kanagawa|
 * flexoki-light, default gruvbox: the user's), SHOTS_ONLY (a regex over scene names), SHOTS_SCALE (device scale, 1).
 */
import fs from "node:fs";
import path from "node:path";
import puppeteer from "puppeteer";

const ORIGIN = "https://shell.powos";
const ROOT = "/shell";
const OUT = "/out";
const SCALE = Number(process.env.SHOTS_SCALE || 1);
const ONLY = process.env.SHOTS_ONLY ? new RegExp(process.env.SHOTS_ONLY) : null;

/** The phone's screens (OnePlus Open, density 442: 2.7625 px a CSS px) and its insets there. */
const SIZES = {
  folded: { width: 404, height: 899, insets: { top: 45.6, bottom: 16.3 } },
  unfolded: { width: 821, height: 883, insets: { top: 45.6, bottom: 16.3 } },
};

/**
 * Themes as the host hands them over (ShellBridge.themeColors from ui/Theme.kt's palette: surface = lighter_background,
 * muted = dark_foreground, border = muted, overlay = background at 90%).
 */
const THEMES = {
  gruvbox: {
    light: false,
    bg: "#282828", surface: "#3c3836", fg: "#d4be98", muted: "#7c6f64", accent: "#7daea3", border: "#665c54", red: "#ea6962", green: "#a9b665",
  },
  kanagawa: {
    light: false,
    bg: "#1f1f28", surface: "#2a2a37", fg: "#dcd7ba", muted: "#727169", accent: "#7e9cd8", border: "#54546d", red: "#e82424", green: "#98bb6c",
  },
  "flexoki-light": {
    light: true,
    bg: "#fffcf0", surface: "#f2f0e5", fg: "#100f0f", muted: "#6f6e69", accent: "#205ea6", border: "#cecdc3", red: "#af3029", green: "#66800b",
  },
};
const THEME = THEMES[process.env.SHOTS_THEME || "gruvbox"] ?? THEMES.gruvbox;

function mime(p) {
  const ext = p.slice(p.lastIndexOf(".") + 1).toLowerCase();
  return (
    { html: "text/html", js: "text/javascript", mjs: "text/javascript", ts: "text/plain", tsx: "text/plain", css: "text/css", json: "application/json",
      wasm: "application/wasm", svg: "image/svg+xml", png: "image/png", jpg: "image/jpeg", webp: "image/webp", woff2: "font/woff2", ttf: "font/ttf" }[ext] ??
    "application/octet-stream"
  );
}

const WALLPAPER = fs.existsSync("/wallpaper.jpg") ? "/wallpaper.jpg" : null;
/** Without one: a busy gradient, so glass and seams show. */
const FALLBACK_WP =
  "data:image/svg+xml," +
  encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="900"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">` +
      `<stop offset="0" stop-color="#0b1020"/><stop offset=".5" stop-color="#5a7fb0"/><stop offset="1" stop-color="#c08050"/></linearGradient></defs>` +
      `<rect width="400" height="900" fill="url(#g)"/><circle cx="300" cy="420" r="160" fill="#a8d0ff" opacity=".6"/></svg>`,
  );

/**
 * The scenes: [name, mode, setup] - setup runs in the page once it's ready (S: state.ts, U: an import by path, E: the
 * mock's events, sleep). `behind`: what the window is over - "wallpaper" (home: native glass), "blurred" (the shade,
 * the switcher: the host blurs the app under them), "app" (the assistant, over an app as it is).
 */
const SCENES = [
  ["home", "home", "", "wallpaper"],
  ["home-p2", "home", "S.page.value = 1;", "wallpaper"],
  ["edit", "home", "S.editing.value = true;", "wallpaper"],
  ["edit-theme", "home", "S.editing.value = true; await sleep(200); [...document.querySelectorAll('.edit-act')].find(b => b.textContent.trim() === 'theme')?.click();", "wallpaper"],
  ["edit-picker", "home", "S.editing.value = true; await sleep(150); (await U('./ui/appwidget.tsx')).picker.value = true;", "wallpaper"],
  ["drawer", "home", "S.drawer.value = 1;", "wallpaper"],
  ["search-typing", "home", "const f = document.querySelector('.bar textarea, .bar input'); f?.focus(); if (f) { f.value = 'weather tomorrow in oslo and remind me to bring an umbrella'; f.dispatchEvent(new Event('input', { bubbles: true })); }", "wallpaper"],
  ["ai", "home", "S.page.value = -1;", "wallpaper"],
  ["ai-compose", "home", "S.page.value = -1; await sleep(300); const f = document.querySelector('.ai-compose textarea, .ai-compose input'); f?.focus(); if (f) { f.value = 'summarise what the agents did overnight and what needs me'; f.dispatchEvent(new Event('input', { bubbles: true })); }", "wallpaper"],
  ["widget-screen", "home", "const w = S.home.value.items.find((i) => i.kind === 'widget'); S.screen.value = { key: w.key, title: 'weather' };", "wallpaper"],
  ["notifications", "home", "S.panel.value = 'notifications'; S.notif.value = true;", "wallpaper"],
  ["settings", "home", "(await U('./screens.ts')).openScreen('settings');", "wallpaper"],
  ["assist", "assist", "", "app"],
  ["shade", "shade", "", "blurred"],
  ["control", "shade", "S.panel.value = 'control';", "blurred"],
  ["switcher", "recents", "E.emit('recents.show', { open: true, from: 100, tasks: await (await U('./bridge.ts')).powos.tasks.list() });", "blurred"],
  ["lock", "lock", "", "wallpaper"],
].filter(([n]) => !ONLY || ONLY.test(n));

function file(url) {
  const u = new URL(url);
  const p = decodeURIComponent(u.pathname).replace(/^\/+/, "") || "index.html";
  if (p.split("/").includes("..")) return null;
  if (p === "__wallpaper.jpg" && WALLPAPER) return { path: WALLPAPER, name: p };
  const f = path.join(ROOT, p);
  return fs.existsSync(f) && fs.statSync(f).isFile() ? { path: f, name: p } : null;
}

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || "/usr/bin/chromium-browser",
  headless: true,
  args: ["--no-sandbox", "--disable-dev-shm-usage", "--no-first-run", "--mute-audio", "--font-render-hinting=none"],
});
const report = [];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Text runs on the page: their boxes, colour, effective opacity and size. */
const collectText = () => {
  const out = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const range = document.createRange();
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const t = n.textContent.trim();
    if (!t) continue;
    const el = n.parentElement;
    if (!el || !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
    if (el.closest("svg, .xterm, canvas, [aria-hidden=true]")) continue;
    range.selectNodeContents(n);
    const r = range.getBoundingClientRect();
    if (r.width < 2 || r.height < 4 || r.right < 0 || r.bottom < 0 || r.left > innerWidth || r.top > innerHeight) continue;
    const cs = getComputedStyle(el);
    let o = 1;
    for (let a = el; a; a = a.parentElement) o *= parseFloat(getComputedStyle(a).opacity);
    if (o < 0.05) continue;
    out.push({
      text: t.slice(0, 40),
      cls: `${el.tagName.toLowerCase()}.${[...el.classList].join(".")}`,
      color: cs.color,
      opacity: o,
      size: parseFloat(cs.fontSize),
      bold: parseInt(cs.fontWeight) >= 700,
      x: Math.max(0, r.left), y: Math.max(0, r.top), w: Math.min(innerWidth, r.right) - Math.max(0, r.left), h: Math.min(innerHeight, r.bottom) - Math.max(0, r.top),
    });
  }
  // Placeholders: their own colour (::placeholder) on the field.
  for (const f of document.querySelectorAll("input, textarea")) {
    if (f.value || !f.placeholder || !f.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
    const r = f.getBoundingClientRect();
    const cs = getComputedStyle(f, "::placeholder");
    out.push({ text: `[${f.placeholder.slice(0, 30)}]`, cls: `${f.tagName.toLowerCase()}::placeholder`, color: cs.color, opacity: 1, size: parseFloat(cs.fontSize), bold: false,
      x: r.left + 4, y: r.top + r.height * 0.25, w: Math.min(r.width - 8, f.placeholder.length * parseFloat(cs.fontSize) * 0.6), h: r.height * 0.5 });
  }
  return out;
};

/** In a blank page: each run's background (the average of the text-less shot under its box) and its contrast. */
const contrastOf = async (png, runs) => {
  const img = new Image();
  img.src = "data:image/png;base64," + png;
  await img.decode();
  const c = document.createElement("canvas");
  c.width = img.width;
  c.height = img.height;
  const g = c.getContext("2d", { willReadFrequently: true });
  g.drawImage(img, 0, 0);
  const k = img.width / innerWidth;
  // Computed colours: rgb()/rgba(), or color(srgb r g b / a) (0-1) from a color-mix.
  const parse = (s) => {
    const m = (s.match(/[\d.]+/g) ?? ["0", "0", "0"]).map(Number);
    if (s.startsWith("color(")) return { r: m[0] * 255, g: m[1] * 255, b: m[2] * 255, a: m[3] ?? 1 };
    return { r: m[0], g: m[1], b: m[2], a: m[3] ?? 1 };
  };
  const lum = ({ r, g: gg, b }) => {
    const f = (v) => ((v /= 255) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
    return 0.2126 * f(r) + 0.7152 * f(gg) + 0.0722 * f(b);
  };
  return runs.map((t) => {
    const d = g.getImageData(Math.round(t.x * k), Math.round(t.y * k), Math.max(1, Math.round(t.w * k)), Math.max(1, Math.round(t.h * k))).data;
    let r = 0, gg = 0, b = 0, n = 0;
    for (let i = 0; i < d.length; i += 4) (r += d[i]), (gg += d[i + 1]), (b += d[i + 2]), n++;
    const bg = { r: r / n, g: gg / n, b: b / n };
    const fgc = parse(t.color);
    const a = fgc.a * t.opacity;
    const fg = { r: fgc.r * a + bg.r * (1 - a), g: fgc.g * a + bg.g * (1 - a), b: fgc.b * a + bg.b * (1 - a) };
    const [l1, l2] = [lum(fg), lum(bg)].sort((x, y) => y - x);
    return { ...t, ratio: +((l1 + 0.05) / (l2 + 0.05)).toFixed(2), bg: `rgb(${bg.r | 0} ${bg.g | 0} ${bg.b | 0})` };
  });
};


try {
  for (const [name, mode, setup, behind] of SCENES) {
    for (const [sizeName, size] of Object.entries(SIZES)) {
      let timer;
      const limit = new Promise((_, no) => (timer = setTimeout(() => no(new Error("timed out (40 s)")), 40000)));
      await Promise.race([shoot(name, mode, setup, behind, sizeName, size), limit])
        .catch((e) => { console.log(`shot ${name}-${sizeName}: FAILED ${e.message}`); report.push({ shot: `${name}-${sizeName}`, errors: [e.message] }); })
        .finally(() => clearTimeout(timer));
    }
  }
} finally {
  fs.writeFileSync(path.join(OUT, "report.json"), JSON.stringify(report, null, 1));
  await browser.close();
  process.exit(0);
}

async function shoot(name, mode, setup, behind, sizeName, size) {
  {
    {
      const t0 = Date.now();
      const step = (what) => process.env.SHOTS_DEBUG && console.log(`  ${name}-${sizeName} ${what} +${Date.now() - t0} ms`);
      const page = await browser.newPage();
      await page.setViewport({ width: size.width, height: size.height, deviceScaleFactor: SCALE });
      const errors = [];
      page.on("pageerror", (e) => errors.push(e.message.split("\n")[0]));
      page.on("console", (m) => m.type() === "error" && errors.push(m.text().split("\n")[0]));
      await page.setRequestInterception(true);
      page.on("request", (req) => {
        const url = req.url();
        if (!url.startsWith(ORIGIN + "/")) return url.startsWith("data:") || url.startsWith("blob:") ? req.continue() : req.abort();
        const f = file(url);
        if (!f) return req.respond({ status: 404, contentType: "text/plain", body: "" });
        req.respond({ status: 200, contentType: mime(f.name), body: fs.readFileSync(f.path), headers: { "Cache-Control": "no-store" } });
      });
      await page.goto(`${ORIGIN}/index.html${mode === "home" ? "" : `?mode=${mode}`}`, { waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => window.__powosAlive === true, { timeout: 10000, polling: 50 }).catch(() => errors.push("not ready"));
      const wp = WALLPAPER ? `${ORIGIN}/__wallpaper.jpg` : FALLBACK_WP;
      await page
        .evaluate(
          async ({ theme, insets, wp, behind, setup }) => {
            const root = document.documentElement;
            const css = { background: theme.bg, surface: theme.surface, overlay: `color-mix(in srgb, ${theme.bg} 90%, transparent)`, foreground: theme.fg,
              muted: theme.muted, accent: theme.accent, border: theme.border, red: theme.red, green: theme.green };
            // As the host would: through app.tsx's applyTheme (what it derives from the theme included).
            window.__mockEvents.emit("theme.changed", { name: "shots", light: theme.light, css, colors: { background: theme.bg, foreground: theme.fg } });
            await new Promise((r) => setTimeout(r, 300)); // the theme crossfade (html.theme-fade, 260 ms)
            root.style.setProperty("--inset-top", `${insets.top}px`);
            root.style.setProperty("--inset-bottom", `${insets.bottom}px`);
            // What the window is over, drawn behind the page (the WebView's own background is the wallpaper/app).
            const back = document.createElement("style");
            const pic = `url("${wp}") center / cover no-repeat fixed`;
            back.textContent =
              behind === "wallpaper"
                ? `html { background: ${pic}; }`
                : behind === "blurred"
                  ? `html::before { content: ""; position: fixed; inset: -40px; z-index: -1; background: ${pic}; filter: blur(30px) brightness(.8); }`
                  : `html { background: linear-gradient(#f4f4f4 0 12%, #fff 12%) ; }`;
            document.head.append(back);
            // Home's live glass, as the compositor draws it: each top-level glass surface blurs what's behind it.
            if (root.dataset.mode === "home") {
              root.classList.add("glass-native");
              const n = document.createElement("style");
              n.textContent = `.glass-native :is(.tile, .notif-panel):not(:is(.tile, .notif-panel) *) { backdrop-filter: blur(var(--shots-native-blur, 30px)); }`;
              document.head.append(n);
            } else if (window.__glass) window.__glass.use(wp);
            const S = await importShim("./state.ts");
            const U = (p) => importShim(p);
            const E = window.__mockEvents;
            const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
            await new (Object.getPrototypeOf(async function () {}).constructor)("S", "U", "E", "sleep", setup)(S, U, E, sleep);
          },
          { theme: THEME, insets: size.insets, wp, behind, setup },
        )
        .catch((e) => errors.push(`setup: ${e.message.split("\n")[0]}`));
      step("setup");
      await sleep(900);
      const out = path.join(OUT, `${name}-${sizeName}.png`);
      await page.screenshot({ path: out });
      // Contrast: the same frame without its text, under each run of text.
      step("shot");
      const runs = await page.evaluate(collectText).catch(() => []);
      step("texts");
      await page.addStyleTag({ content: "*, *::placeholder { color: transparent !important; -webkit-text-fill-color: transparent !important; text-shadow: none !important; caret-color: transparent !important; }" });
      await sleep(80);
      const bare = await page.screenshot({ encoding: "base64" });
      step("bare");
      const measured = await page.evaluate(contrastOf, bare, runs).catch((e) => (errors.push(`contrast: ${e.message}`), []));
      const low = measured.filter((t) => t.ratio < (t.size >= 24 || (t.size >= 18.66 && t.bold) ? 3 : 4.5));
      report.push({ shot: `${name}-${sizeName}`, errors: [...new Set(errors)].slice(0, 8), lowContrast: low, texts: measured.length });
      console.log(`shot ${name}-${sizeName}: ${measured.length} texts, ${low.length} below contrast${errors.length ? `, ${errors.length} errors` : ""}`);
      await page.close();
    }
  }
}

/**
 * The pet's body in every state, headless (review renders for the manager, not a gate): home booted against the mock
 * bridge with the pet installed, put on a perch, each state forced (window.__pet.force), a close-up of the pet saved per
 * state, and one contact sheet of them all. Also checks the body at rest: no running animations, rAF stops.
 *
 *   shell/dev/petshots.sh [OUT]       (OUT under $HOME; default ~/.cache/powos-petshots)
 *   env: PET_THEME=matte|gruvbox|kanagawa (matte = the phone's Matte Black), PET_STATES="idle looking ..." (default all),
 *        PET_SCALE (device scale, 3), PET_PERCH (an edge key: "bar", a tile's key; default "bar")
 */
import fs from "node:fs";
import path from "node:path";
import puppeteer from "puppeteer";

const ORIGIN = "https://shell.powos";
const ROOT = "/shell";
const OUT = "/out";
const THEMES = {
  matte: { light: false, bg: "#121212", surface: "#1e1e1e", fg: "#bebebe", muted: "#a7a7a7", accent: "#e68e0d", border: "#333333", red: "#d35f5f", green: "#ffc107" },
  gruvbox: { light: false, bg: "#282828", surface: "#3c3836", fg: "#d4be98", muted: "#7c6f64", accent: "#7daea3", border: "#665c54", red: "#ea6962", green: "#a9b665" },
  kanagawa: { light: false, bg: "#1f1f28", surface: "#2a2a37", fg: "#dcd7ba", muted: "#727169", accent: "#7e9cd8", border: "#54546d", red: "#e82424", green: "#98bb6c" },
};
const THEME = THEMES[process.env.PET_THEME || "matte"] ?? THEMES.matte;
const STATES = (process.env.PET_STATES || "idle looking working worried sleepy hungry eating happy listening").split(/\s+/).filter(Boolean);
const SCALE = Number(process.env.PET_SCALE || 3);
const PERCH = process.env.PET_PERCH || "bar";
const mime = (p) =>
  ({ html: "text/html", js: "text/javascript", ts: "text/plain", tsx: "text/plain", css: "text/css", json: "application/json", svg: "image/svg+xml", png: "image/png", woff2: "font/woff2", ttf: "font/ttf" })[p.split(".").pop()] ??
  "application/octet-stream";

const browser = await puppeteer.launch({ executablePath: process.env.CHROME || "/usr/bin/chromium-browser", headless: true, args: ["--no-sandbox", "--disable-dev-shm-usage"] });
const shots = [];
for (const state of STATES) {
  const page = await browser.newPage();
  await page.setViewport({ width: 404, height: 899, deviceScaleFactor: SCALE });
  await page.setRequestInterception(true);
  page.on("request", (req) => {
    const u = new URL(req.url());
    if (u.origin !== ORIGIN) return req.url().startsWith("data:") ? req.continue() : req.abort();
    const f = path.join(ROOT, decodeURIComponent(u.pathname).replace(/^\/+/, "") || "index.html");
    if (!fs.existsSync(f) || !fs.statSync(f).isFile()) return req.respond({ status: 404, body: "" });
    req.respond({ status: 200, contentType: mime(f), body: fs.readFileSync(f) });
  });
  page.on("pageerror", (e) => console.log(`${state}: pageerror ${e.message.split("\n")[0]}`));
  await page.goto(`${ORIGIN}/index.html`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.__powosAlive === true, { timeout: 15000 });
  const rest = await page.evaluate(
    async ({ theme, state, perch }) => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const css = { background: theme.bg, surface: theme.surface, foreground: theme.fg, muted: theme.muted, accent: theme.accent, border: theme.border, red: theme.red, green: theme.green };
      window.__mockEvents?.emit("theme.changed", { name: "shots", light: theme.light, css, colors: { background: theme.bg, foreground: theme.fg } });
      document.documentElement.style.background = "linear-gradient(160deg,#0b1020,#5a7fb0 55%,#c08050)";
      const P = await importShim("./apps/pages.ts");
      P.installedApps.value = [...P.installedApps.value, { id: "local.pet", name: "Pet", version: "0.1.0", database: "local-pet", tier: 0, manifest: "{}" }];
      await sleep(600);
      window.__pet.perch(perch, 0.8);
      window.__pet.force(state);
      // Its state's move plays once (<= ~6 s for sleepy's two breaths), then it must be still.
      await sleep(state === "sleepy" ? 6500 : 2500);
      let raf = 0;
      const orig = window.requestAnimationFrame;
      window.requestAnimationFrame = (f) => (raf++, orig(f));
      await sleep(1000);
      window.requestAnimationFrame = orig;
      return { raf, running: document.getAnimations().filter((a) => a.playState === "running").length };
    },
    { theme: THEME, state, perch: PERCH },
  );
  console.log(`${state}: at rest ${rest.running} running animations, ${rest.raf} rAF calls in 1 s`);
  const box = await page.evaluate(() => {
    const r = document.querySelector(".pet")?.getBoundingClientRect();
    return r ? { x: Math.max(0, r.left - 40), y: Math.max(0, r.top - 40), width: Math.min(innerWidth, r.width + 80), height: Math.min(innerHeight, r.height + 80) } : null;
  });
  const file = path.join(OUT, `pet-${state}.png`);
  if (box) await page.screenshot({ path: file, clip: box });
  shots.push({ state, file, rest });
  await page.close();
}
// The contact sheet: every state's close-up with its name and its rest check.
const cells = shots
  .filter((s) => fs.existsSync(s.file))
  .map((s) => `<figure><img src="data:image/png;base64,${fs.readFileSync(s.file).toString("base64")}"><figcaption>${s.state} · rest: ${s.rest.running} anim, ${s.rest.raf} rAF</figcaption></figure>`)
  .join("");
const sheet = await browser.newPage();
await sheet.setViewport({ width: 1240, height: 400 });
await sheet.setContent(
  `<html><body style="margin:0;background:#111;color:#ddd;font:13px monospace"><h1 style="font-size:15px;margin:10px">pet states · ${process.env.PET_THEME || "matte"}</h1><div style="display:grid;grid-template-columns:repeat(5,236px);gap:8px;padding:8px">${cells}</div><style>figure{margin:0}img{width:236px;display:block;border-radius:6px}figcaption{padding:4px 0}</style></body></html>`,
);
await sheet.screenshot({ path: path.join(OUT, "sheet.png"), fullPage: true });
await browser.close();

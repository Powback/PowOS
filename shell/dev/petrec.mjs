/**
 * The pet's movement in the real page, headless (review, not a gate): home booted against the mock bridge with the
 * pet installed and physics on, then sent to a few tiles; every frame's transform is recorded (max displacement per
 * frame), a frame strip is saved, and the page must run 0 requestAnimationFrame callbacks once it's at rest.
 *
 *   docker run --rm --platform linux/arm64 --shm-size 512m -v "$PWD/shell:/shell:ro" -v "$PWD/shell/dev/petrec.mjs:/usr/src/app/petrec.mjs:ro" \
 *     -v "$OUT:/out" -w /usr/src/app --entrypoint node zenika/alpine-chrome:with-puppeteer petrec.mjs
 *   (the gate's Chromium image; OUT under $HOME. PET_PHYS=off compares the keyframe hops, PET_W/PET_H the viewport.)
 */
import fs from "node:fs";
import path from "node:path";
import puppeteer from "puppeteer";

const ORIGIN = "https://shell.powos";
const ROOT = "/shell";
const OUT = "/out";
const W = Number(process.env.PET_W || 412);
const H = Number(process.env.PET_H || 915);
const mime = (p) => ({ html: "text/html", js: "text/javascript", ts: "text/plain", tsx: "text/plain", css: "text/css", json: "application/json", svg: "image/svg+xml", png: "image/png", webp: "image/webp", woff2: "font/woff2" })[p.split(".").pop()] ?? "application/octet-stream";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = await puppeteer.launch({ headless: "new", args: ["--no-sandbox", "--disable-gpu", "--font-render-hinting=none"] });
const page = await browser.newPage();
await page.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
await page.setRequestInterception(true);
page.on("request", (req) => {
  const u = new URL(req.url());
  if (u.origin !== ORIGIN) return req.url().startsWith("data:") || req.url().startsWith("blob:") ? req.continue() : req.abort();
  const p = decodeURIComponent(u.pathname).replace(/^\/+/, "") || "index.html";
  const f = path.join(ROOT, p);
  if (p.includes("..") || !fs.existsSync(f) || !fs.statSync(f).isFile()) return req.respond({ status: 404, body: "" });
  req.respond({ status: 200, contentType: mime(p), body: fs.readFileSync(f), headers: { "Cache-Control": "no-store" } });
});
const errors = [];
page.on("pageerror", (e) => errors.push(e.message.split("\n")[0]));
await page.evaluateOnNewDocument((phys) => {
  try {
    localStorage.setItem("powos.pet.physics", phys);
    localStorage.removeItem("powos.pet.perch");
  } catch {}
  const raf = window.requestAnimationFrame.bind(window);
  window.__raf = 0;
  window.__rafWho = [];
  window.requestAnimationFrame = (cb) => {
    if (window.__rafLog) window.__rafWho.push((new Error().stack || "").split("\n").slice(2, 5).join(" <- "));
    return raf((t) => (window.__raf++, cb(t)));
  };
}, process.env.PET_PHYS || "on");
await page.goto(`${ORIGIN}/index.html`, { waitUntil: "domcontentloaded" });
await page.waitForFunction(() => window.__powosAlive === true, { timeout: 20000 });
// The pet is a PowOS app (local.pet): installed here by hand - the mock has no registry.
await page.evaluate(async () => {
  const m = await window.importShim("./apps/pages.ts");
  m.installedApps.value = [...m.installedApps.value, { id: "local.pet", name: "Pet" }];
});
await page.waitForSelector(".pet", { timeout: 10000 });
// A sample layout of tiles to stand on (the mock home has few): plain .home-tile boxes on the page showing.
await page.evaluate((W, H) => {
  const pg = document.querySelector(".page:not(.away)");
  for (const t of pg.querySelectorAll(".home-tile")) t.style.visibility = "hidden", t.classList.add("lifted");
  const at = (key, l, t, w, h) => {
    const d = document.createElement("div");
    d.className = "home-tile tile";
    d.dataset.key = key;
    Object.assign(d.style, { position: "fixed", left: `${l}px`, top: `${t}px`, width: `${w}px`, height: `${h}px`, zIndex: 1 });
    pg.append(d);
  };
  // As on the phone's home (2026-10-21): two tiles at the top, the pill far below.
  const c = (W - 32) / 2;
  at("t-a", 12, 58, c, 204);
  at("t-b", 20 + c, 58, c, 136);
}, W, H);
await page.evaluate(() => window.dispatchEvent(new Event("resize")));
await sleep(600);
// Every frame: the pet's transform (where the page draws it).
await page.evaluate(() => {
  window.__track = [];
  const el = document.querySelector(".pet");
  const raf = window.requestAnimationFrame;
  const rec = () => {
    const m = /translate3d\(([-\d.]+)px, ([-\d.]+)px/.exec(el.style.transform);
    if (m) window.__track.push([performance.now(), +m[1], +m[2]]);
  };
  new MutationObserver(rec).observe(el, { attributes: true, attributeFilter: ["style"] });
  void raf;
});
const idle = async (label) => {
  await page.evaluate(() => (window.__powosMockQuiet = true));
  await sleep(Number(process.env.PET_SETTLE || 2500));
  const a = await page.evaluate(() => ((window.__rafLog = true), (window.__rafWho = []), window.__raf));
  await sleep(2000);
  const b = await page.evaluate(() => window.__raf);
  const who = await page.evaluate(() => ((window.__rafLog = false), window.__rafWho));
  const mine = who.filter((w) => /pet(move|phys|ai|body)\./.test(w)).length;
  console.log(`${label}: ${b - a} rAF callbacks in 2 s at rest, ${mine} from the pet's own loops`);
  report.petRaf = (report.petRaf || 0) + mine;
  if (who.length) console.log("  requested by:", [...new Set(who)].slice(0, 4).join("\n    "));
  return b - a;
};
const report = { idle: [], moves: [], errors };
report.idle.push(await idle("after boot"));
const edges = await page.evaluate(() => window.__pet.edges().filter((e) => !e.owner).map((e) => ({ key: e.key, left: e.left, right: e.right, top: e.top })));
console.log("edges:", edges.map((e) => `${e.key}@${Math.round(e.left)},${Math.round(e.top)}`).join(" "));
// Targets: the highest tile, a middle one, the left-most, the pill.
const tiles = edges.filter((e) => e.key !== "bar");
const pick = [...new Set([tiles.sort((a, b) => a.top - b.top)[0], tiles[Math.floor(tiles.length / 2)], tiles.sort((a, b) => a.left - b.left || b.top - a.top)[0], edges.find((e) => e.key === "bar")].filter(Boolean))];
fs.mkdirSync(OUT, { recursive: true });
let shot = 0;
for (const t of pick) {
  await page.evaluate(() => (window.__track = []));
  await page.evaluate((k) => window.__pet.go(k, 0.5), t.key);
  const t0 = Date.now();
  // Frames for the strip: every 120 ms while it moves (a screenshot each; the page keeps running meanwhile).
  while (Date.now() - t0 < 8000) {
    await page.screenshot({ path: path.join(OUT, `f${String(shot++).padStart(3, "0")}.png`) });
    await sleep(80);
    const moving = await page.evaluate(() => window.__track.length && performance.now() - window.__track.at(-1)[0] < 150);
    if (!moving && Date.now() - t0 > 600) break;
  }
  const track = await page.evaluate(() => window.__track);
  let max = 0;
  for (let i = 1; i < track.length; i++) max = Math.max(max, Math.hypot(track[i][1] - track[i - 1][1], track[i][2] - track[i - 1][2]));
  const end = track.at(-1);
  const r = { to: t.key, frames: track.length, maxPerFrame: +max.toFixed(1), end: end && [Math.round(end[1]), Math.round(end[2])], perch: await page.evaluate(() => localStorage.getItem("powos.pet.perch")) };
  console.log("move", JSON.stringify(r));
  report.moves.push(r);
  report.idle.push(await idle(`after ${t.key}`));
}
// A resize (fold): the world shrinks under it - it must walk back in, not snap.
await page.evaluate(() => (window.__track = []));
await page.setViewport({ width: Math.round(W * 0.8), height: H, deviceScaleFactor: 1 });
await sleep(3000);
const track = await page.evaluate(() => window.__track);
let max = 0;
for (let i = 1; i < track.length; i++) max = Math.max(max, Math.hypot(track[i][1] - track[i - 1][1], track[i][2] - track[i - 1][2]));
report.resize = { frames: track.length, maxPerFrame: +max.toFixed(1) };
console.log("resize", JSON.stringify(report.resize));
report.idle.push(await idle("after resize"));
fs.writeFileSync(path.join(OUT, "report.json"), JSON.stringify(report, null, 2));
console.log(errors.length ? `page errors: ${errors.join(" | ")}` : "no page errors");
await browser.close();

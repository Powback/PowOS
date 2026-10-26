/**
 * The glasses' screen page (?mode=glasses, shell/glasses/surface.tsx) driven in a headless Chromium against the mock
 * bridge - what it sends the glasses, not just that it boots (the gate does that):
 *
 * 1. text mode (a G2 without g2Raster): the HUD's text goes out through glasses.showText - the time, its views;
 * 2. input: a tap ("Enter" in a browser, "glasses.input" on the phone) moves to the next view, which is sent;
 * 3. nothing is sent again while nothing changed;
 * 4. image mode (g2Raster on): the page drawn into a canvas (frame.ts rasterize) and sent as a PNG with lit pixels.
 *
 * Run (as the gate, in its image):  shell/dev/glasses-check.sh
 */
import fs from "node:fs";
import path from "node:path";
import puppeteer from "puppeteer";

const ORIGIN = "https://shell.powos";
const ROOT = "/shell";
const mime = (p) =>
  ({ html: "text/html", js: "text/javascript", ts: "text/plain", tsx: "text/plain", css: "text/css", json: "application/json", woff2: "font/woff2", ttf: "font/ttf" })[
    p.slice(p.lastIndexOf(".") + 1)
  ] ?? "application/octet-stream";

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || "/usr/bin/chromium-browser",
  headless: true,
  args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"],
});
let failed = 0;
const check = (name, ok, detail = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : ` ${detail}`}`);
  if (!ok) failed++;
};
try {
  const page = await browser.newPage();
  await page.setRequestInterception(true);
  page.on("request", (req) => {
    const u = new URL(req.url());
    if (u.origin !== ORIGIN) return req.url().startsWith("data:") ? req.continue() : req.abort();
    const f = path.join(ROOT, decodeURIComponent(u.pathname).replace(/^\/+/, "") || "index.html");
    if (!fs.existsSync(f) || !fs.statSync(f).isFile()) return req.respond({ status: 404, body: "" });
    req.respond({ status: 200, contentType: mime(f), body: fs.readFileSync(f) });
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`${ORIGIN}/index.html?mode=glasses`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.__powosAlive === true, { timeout: 15000 });
  // Every call the page makes to the mock's glasses, recorded: bridge.ts is the page's own module instance (the
  // shim caches it by URL), and surface.tsx looks powos.glasses.showText up at each call.
  const host = await page.evaluate(async () => {
    const { powos } = await window.importShim("./bridge.ts");
    window.__sent = [];
    for (const k of ["showText", "showImage", "clear"]) {
      const f = powos.glasses[k];
      powos.glasses[k] = (...a) => (window.__sent.push({ k, a: k === "showImage" ? [a[0].slice(0, 22), a[0].length] : a }), f(...a));
    }
    return powos.host;
  });
  check("the page runs against the mock", host === "mock", host);
  const sent = () => page.evaluate(() => window.__sent);
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));

  // A tap (Enter in a browser) changes the view: its text goes out.
  await page.keyboard.press("Enter");
  await wait(3500);
  let s = await sent();
  check("a tap's next view is sent as text (G2, text mode)", s.some((x) => x.k === "showText" && /No notifications|: /.test(x.a[0])), JSON.stringify(s).slice(0, 300));
  const n = s.length;
  await wait(3500);
  s = await sent();
  check("nothing sent again while nothing changed", s.length === n, `${n} -> ${s.length}`);
  // Two more taps: the AI view, then home (the time) - each sent once, paced.
  await page.keyboard.press("Enter");
  await wait(3500);
  s = await sent();
  check("the PowOS AI view is sent", s.slice(n).some((x) => x.k === "showText" && /AI|ask PowOS/.test(x.a[0])), JSON.stringify(s.slice(n)).slice(0, 300));

  // Image mode: g2Raster on -> the page drawn and sent as a PNG.
  await page.evaluate(async () => {
    const { powos } = await window.importShim("./bridge.ts");
    await powos.glasses.option("g2Raster", true);
  });
  await wait(4000);
  s = await sent();
  const img = s.filter((x) => x.k === "showImage");
  check("image mode: a PNG of the page is sent", img.length > 0 && img[0].a[0].startsWith("data:image/png;base64") && img[0].a[1] > 1000, JSON.stringify(img).slice(0, 200));
  const lit = await page.evaluate(async () => {
    const { rasterize } = await window.importShim("./glasses/frame.ts");
    const f = await rasterize(document.querySelector(".glasses-root"), { width: 576, height: 288, bits: 4 });
    return f ? Array.from(f.levels).filter((v) => v > 0).length : -1;
  });
  check("the drawn frame has lit pixels (the HUD's text)", lit > 200, `lit=${lit}`);
  check("no page errors", errors.length === 0, errors.join("; "));
} finally {
  await browser.close();
}
process.exit(failed ? 1 : 0);

// Run by apps/sketch/test/rotate.sh (it says what this checks).
import http from "node:http"; import fs from "node:fs"; import path from "node:path"; import puppeteer from "puppeteer";
const types = { ".js": "text/javascript", ".html": "text/html", ".svg": "image/svg+xml" };
const srv = http.createServer((q, r) => {
  const u = q.url.split("?")[0];
  const f = u.startsWith("/v/") ? "/shell/vendor/" + u.slice(3) : u.startsWith("/app/") ? "/appui/" + u.slice(5) : "/t/page.html";
  try { const b = fs.readFileSync(f); r.writeHead(200, { "content-type": types[path.extname(f)] || "text/plain" }); r.end(b); } catch { r.writeHead(404); r.end(); }
}).listen(8099);
const browser = await puppeteer.launch({ executablePath: "/usr/bin/chromium-browser", headless: true, args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"] });
const page = await browser.newPage();
const errs = []; page.on("pageerror", (e) => errs.push(String(e))); page.on("console", (m) => m.type() === "error" || m.type() === "warning" ? errs.push(m.text()) : 0);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fails = 0; const ok = (c, m) => { console.log((c ? "ok   " : "FAIL ") + m); if (!c) fails++; };
const ink = () => page.evaluate(() => { const c = document.querySelector("canvas"); const d = c.getContext("2d").getImageData(0, 0, c.width, c.height).data; let n = 0; for (let i = 0; i < d.length; i += 4) if (d[i] > 120) n++; return n; });
const state = () => page.evaluate(() => window.__sketch);
await page.setViewport({ width: 400, height: 860, deviceScaleFactor: 2 });
await page.goto("http://localhost:8099/"); await sleep(600);
const drag = async (pts) => { await page.mouse.move(...pts[0]); await page.mouse.down(); for (const p of pts.slice(1)) await page.mouse.move(...p, { steps: 8 }); await page.mouse.up(); await sleep(200); };
await drag([[100, 300], [200, 600], [300, 840]]);
await drag([[40, 120], [360, 160]]);
let st = JSON.parse(await page.evaluate(() => dump()));
ok(st.stroke.length === 2 && st.drawing.length === 1, `2 strokes saved in 1 drawing (${st.stroke.length}, ${st.drawing.length})`);
ok(st.drawing[0].width === 800 && st.drawing[0].height === 1720, `drawing box = portrait canvas ${st.drawing[0].width}x${st.drawing[0].height}`);
const p0 = await ink(); ok(p0 > 2000, `portrait ink pixels ${p0}`);
await page.setViewport({ width: 900, height: 400, deviceScaleFactor: 2 }); await sleep(500);
st = await state();
ok(st.size[0] === 1800 && st.size[1] === 800, `landscape canvas ${st.size}`);
const r = st.extent, v = st.view;
ok(v.ox + r.x0 * v.s >= -1 && v.oy + r.y0 * v.s >= -1 && v.ox + r.x1 * v.s <= 1801 && v.oy + r.y1 * v.s <= 801, `whole drawing fits landscape (scale ${v.s.toFixed(3)})`);
const p1 = await ink(); ok(p1 > p0 * v.s * v.s * 0.7, `landscape ink ${p1} (~ ${Math.round(p0 * v.s * v.s)} expected at scale^2)`);
// The stroke's bottom end (300,840 css -> 600,1680 drawing) is on screen and painted.
const bottom = await page.evaluate(({ v }) => { const c = document.querySelector("canvas"); const x = Math.round(v.ox + 600 * v.s), y = Math.round(v.oy + 1676 * v.s); const d = c.getContext("2d").getImageData(x - 3, y - 3, 7, 7).data; let m = 0; for (let i = 0; i < d.length; i += 4) m = Math.max(m, d[i]); return { x, y, m }; }, { v });
ok(bottom.m > 120 && bottom.y < 800, `bottom of the long stroke drawn at ${bottom.x},${bottom.y}`);
// Draw in landscape outside the portrait box, then rotate back: nothing cropped.
await drag([[20, 200], [120, 250]]);
await page.setViewport({ width: 400, height: 860, deviceScaleFactor: 2 }); await sleep(500);
st = await state(); const r2 = st.extent, v2 = st.view;
ok(v2.ox + r2.x0 * v2.s >= -1 && v2.ox + r2.x1 * v2.s <= 801 && v2.oy + r2.y1 * v2.s <= 1721, `back to portrait, all 3 strokes fit (scale ${v2.s.toFixed(3)}, strokes ${st.strokes})`);
// Undo / redo / clear.
const click = (label) => page.evaluate((l) => document.querySelector(`[aria-label="${l}"]`).click(), label);
await click("undo"); await sleep(200); st = await state(); ok(st.strokes === 2, `undo -> ${st.strokes} strokes`);
await click("redo"); await sleep(200); st = await state(); ok(st.strokes === 3, `redo -> ${st.strokes} strokes`);
await click("clear"); await sleep(200); st = await state(); ok(st.strokes === 0, `clear -> ${st.strokes}`);
await click("undo"); await sleep(200); st = await state(); ok(st.strokes === 3, `undo clear -> ${st.strokes}`);
await sleep(1900);
const saved = await page.evaluate(() => dump());
ok(JSON.parse(saved).drawing[0].image.startsWith("data:image/"), `picture made for the gallery/widget (${JSON.parse(saved).drawing[0].image.length} chars)`);
// Restart: a new page with the same database draws the same drawing.
await page.evaluate((s) => sessionStorage.setItem("seed", s), saved);
await page.reload(); await sleep(800);
st = await state(); ok(st.strokes === 3, `after a restart: ${st.strokes} strokes redrawn`);
const p2 = await ink(); ok(p2 > 1500, `after restart ink ${p2}`);
await sleep(1800);

// The infinite canvas: two fingers pan and pinch (touches through CDP), one finger still draws; the view is saved.
const cdp = await page.target().createCDPSession();
const touch = async (type, pts) => { await cdp.send("Input.dispatchTouchEvent", { type, touchPoints: pts.map(([x, y], i) => ({ x, y, id: i + 1 })) }); };
const two = async (a0, b0, a1, b1, steps = 10) => {
  await touch("touchStart", [a0]); await touch("touchMove", [a0]); await touch("touchStart", [a0, b0]);
  for (let i = 1; i <= steps; i++) { const t = i / steps, l = (p, q) => [p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t]; await touch("touchMove", [l(a0, a1), l(b0, b1)]); await sleep(16); }
  await touch("touchEnd", []); await sleep(250);
};
const rows = (s) => JSON.stringify({ d: s.drawing.map(({ image, ...r }) => r), s: s.stroke });
const at = (v, x, y) => [(x * 2 - v.ox) / v.s, (y * 2 - v.oy) / v.s]; // css px -> drawing space (dpr 2)
const near = (a, b, e = 0.5) => Math.abs(a - b) <= e;
const data0 = rows(JSON.parse(await page.evaluate(() => dump())));
st = await state(); const fv = st.view; ok(st.mode === "fit", `opens fitted (mode ${st.mode})`);
const under = at(fv, 200, 400);
await two([150, 400], [250, 400], [100, 420], [300, 420]);
st = await state(); let v3 = st.view;
ok(st.mode === "free" && near(v3.s, fv.s * 2, 0.02), `pinch zooms 2x (scale ${fv.s.toFixed(3)} -> ${v3.s.toFixed(3)})`);
const moved = at(v3, 200, 420);
ok(near(moved[0], under[0], 2) && near(moved[1], under[1], 2), `zoom around the pinch centre: ${under.map(Math.round)} stays under it (${moved.map(Math.round)})`);
await two([150, 500], [250, 500], [90, 420], [190, 420]);
st = await state();
ok(near(st.view.s, v3.s, 0.01) && near(st.view.ox - v3.ox, -120, 2) && near(st.view.oy - v3.oy, -160, 2), `two-finger pan moves the view (${Math.round(st.view.ox - v3.ox)}, ${Math.round(st.view.oy - v3.oy)} px)`);
v3 = st.view;
await two([195, 400], [205, 400], [5, 400], [395, 400]); await two([195, 400], [205, 400], [5, 400], [395, 400]);
await two([195, 400], [205, 400], [5, 400], [395, 400]);
st = await state(); ok(st.view.s <= 100.001 && st.view.s > 99 && st.drawn < st.strokes, `max zoom ${st.view.s.toFixed(2)} (100), off-screen strokes skipped (${st.drawn}/${st.strokes})`);
for (let i = 0; i < 4; i++) await two([5, 400], [395, 400], [199, 400], [201, 400]);
st = await state(); ok(st.view.s >= 0.0199 && st.view.s < 0.021, `min zoom ${st.view.s.toFixed(3)} (0.02)`);
await two([150, 400], [250, 400], [50, 400], [350, 400]);
let n0 = (await state()).strokes;
await drag([[60, 300], [120, 330]]);
st = await state(); ok(st.strokes === n0 + 1 && st.mode === "free", `one finger still draws in a moved view (${st.strokes} strokes)`);
const kept = JSON.parse(await page.evaluate(() => dump()));
const vrow = kept.viewport.find((v) => v.key === st.key);
ok(vrow && !vrow.fit && vrow.zoom > 0, `view saved per drawing (${JSON.stringify(vrow)})`);
// At rest nothing paints.
const pa = (await state()).paints; await sleep(1200); ok((await state()).paints === pa, `no frames at rest (${pa} paints, unchanged)`);
// Rotation keeps the spot: same centre and zoom.
const keep = await state(); const c0 = at(keep.view, 200, 430);
await page.setViewport({ width: 900, height: 400, deviceScaleFactor: 2 }); await sleep(500);
st = await state(); const c1 = at(st.view, 450, 200);
ok(st.mode === "free" && near(st.view.s, keep.view.s, 0.01) && near(c0[0], c1[0], 1) && near(c0[1], c1[1], 1), `rotation keeps centre ${c0.map(Math.round)} and zoom (${c1.map(Math.round)}, ${st.view.s.toFixed(3)})`);
await page.setViewport({ width: 400, height: 860, deviceScaleFactor: 2 }); await sleep(500);
// Restart: the view comes back from the database.
const before = (await state()).view;
await page.evaluate((s) => sessionStorage.setItem("seed", s), await page.evaluate(() => dump()));
await page.evaluate(() => localStorage.clear());
await page.reload(); await sleep(800);
st = await state();
ok(st.mode === "free" && near(st.view.s, before.s, 0.01) && near(st.view.ox, before.ox, 2) && near(st.view.oy, before.oy, 2), `after a restart the view is back (scale ${st.view.s.toFixed(3)}, ${Math.round(st.view.ox)},${Math.round(st.view.oy)})`);
// Fit all, then a double tap back to the page at 100%: neither draws anything.
await click("fit all"); await sleep(300);
st = await state(); const fr = st.extent, fw = st.view;
ok(st.mode === "fit" && fw.ox + fr.x0 * fw.s >= -1 && fw.ox + fr.x1 * fw.s <= 801 && fw.oy + fr.y0 * fw.s >= -1 && fw.oy + fr.y1 * fw.s <= 1721, `fit all shows the whole drawing (scale ${fw.s.toFixed(3)})`);
n0 = st.strokes;
const tap = async (x, y) => { await page.mouse.move(x, y); await page.mouse.down(); await page.mouse.up(); };
await tap(200, 300); await sleep(60); await tap(203, 302); await sleep(500);
st = await state(); ok(st.mode === "free" && near(st.view.s, 1, 0.001) && st.strokes === n0, `double tap resets to 100% (scale ${st.view.s}), no dots kept (${st.strokes} strokes)`);
await tap(100, 700); await sleep(500);
st = await state(); ok(st.strokes === n0 + 1, `a single tap is still a dot (${st.strokes} strokes)`);
const data1 = JSON.parse(await page.evaluate(() => dump()));
const old = JSON.parse(data0);
ok(old.s.every((o) => data1.stroke.some((s) => s.uid === o.uid && JSON.stringify(s.points) === JSON.stringify(o.points) && s.hidden === o.hidden)) &&
  JSON.stringify(old.d) === JSON.stringify(rows(data1) && JSON.parse(rows(data1)).d),
  `the drawing's own strokes are untouched by view changes`);
await sleep(1800);

// Legacy: a raster drawing (no key) opens as its picture; a stroke adopts it, keeping the picture as base.
const png = await page.evaluate(() => { const c = document.createElement("canvas"); c.width = 800; c.height = 1720; const g = c.getContext("2d"); g.fillStyle = "#121216"; g.fillRect(0, 0, 800, 1720); g.fillStyle = "#fff"; g.fillRect(100, 100, 200, 200); return c.toDataURL("image/png"); });
await page.evaluate((png) => sessionStorage.setItem("seed", JSON.stringify({ drawing: [{ id: "1", title: "Sketch 1", image: png, width: 800, height: 1720, key: "", base: "" }], stroke: [], next: 5 })), png);
await page.evaluate(() => localStorage.clear());
await page.reload(); await sleep(800);
const pl = await ink(); ok(pl > 30000, `legacy picture shown (${pl} px)`);
await drag([[200, 500], [300, 600]]);
st = JSON.parse(await page.evaluate(() => dump()));
ok(st.drawing.length === 1 && st.drawing[0].key !== "" && st.drawing[0].base === png && st.stroke.length === 1, `legacy adopted: key set, base = old picture, 1 stroke`);


// Crisp at any zoom: a test drawing (one red line), pinched to 10x and 50x. While the fingers move the last render is
// only moved (a CSS translate + scale, no repaint); when they lift the strokes are re-rendered as vectors, so the
// line's edge stays ~1 px wide (a scaled raster's edge would be ~10 / ~50 px of blur).
const RED = []; for (let x = 300; x <= 500; x += 5) RED.push(x, 860.37, 6);
await page.evaluate((r) => sessionStorage.setItem("seed", JSON.stringify({ drawing: [{ id: "1", title: "Test", image: "", width: 800, height: 1720, key: "t", base: "" }],
  stroke: [{ id: "2", drawing: "1", uid: "r", color: "#ff5c5c", eraser: false, points: r, hidden: false }], viewport: [{ key: "t", cx: 400, cy: 860, zoom: 0.5, fit: false }], next: 9 })), RED);
await page.reload(); await sleep(800);
// The red channel down the canvas's centre column: how many pixels are part-way across an edge (anti-aliasing / blur).
// raster = the control: the 1x render scaled up by `raster` (what zooming a picture would show), measured the same way.
const blur = (raster = 0) => page.evaluate((k) => { let c = document.querySelector("canvas"), g = c.getContext("2d");
  if (k) { const o = document.createElement("canvas"); o.width = c.width; o.height = c.height; const q = o.getContext("2d"); q.imageSmoothingEnabled = true;
    q.drawImage(c, c.width / 2 * (1 - k), c.height / 2 * (1 - k), c.width * k, c.height * k); c = o; g = q; }
  const d = g.getImageData(c.width >> 1, 0, 1, c.height).data;
  let lo = 255, hi = 0; for (let i = 0; i < d.length; i += 4) (lo = Math.min(lo, d[i])), (hi = Math.max(hi, d[i]));
  let mid = 0, on = 0; for (let i = 0; i < d.length; i += 4) { const t = (d[i] - lo) / (hi - lo || 1); if (t > 0.1 && t < 0.9) mid++; if (t >= 0.9) on++; } return { mid, on, lo, hi }; }, raster);
const pinchHeld = async (a0, b0, a1, b1) => { // a pinch, read mid-way (fingers still down), then lifted
  await touch("touchStart", [a0]); await touch("touchMove", [a0]); await touch("touchStart", [a0, b0]);
  const p0 = (await state()).paints;
  for (let i = 1; i <= 10; i++) { const t = i / 10, l = (p, q) => [p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t]; await touch("touchMove", [l(a0, a1), l(b0, b1)]); await sleep(16); }
  await sleep(50);
  const mid = await page.evaluate(() => document.querySelector("canvas").style.transform), p1 = (await state()).paints;
  await touch("touchEnd", []); await sleep(250);
  return { mid, painted: p1 - p0 };
};
st = await state(); ok(near(st.view.s, 1, 0.001), `test drawing at 1x (${st.view.s})`);
const r10 = await blur(10), r50 = await blur(50);
let g = await pinchHeld([190, 430], [210, 430], [100, 430], [300, 430]);
ok(/^translate\([-\d.e]+px, [-\d.e]+px\) scale\([\d.e]+\)$/.test(g.mid) && g.painted === 0, `mid-pinch: the last render moved by "${g.mid}" (translate + scale, no rotation), ${g.painted} repaints`);
st = await state(); const b10 = await blur();
ok(near(st.view.s, 10, 0.05) && (await page.evaluate(() => document.querySelector("canvas").style.transform)) === "", `pinched to ${st.view.s.toFixed(2)}x, transform cleared on settle`);
ok(b10.on >= 50 && b10.mid <= 4 && r10.mid >= 4 * Math.max(1, b10.mid), `crisp at 10x: ${b10.on} px solid line, ${b10.mid} edge px (the 1x render scaled: ${r10.mid})`);
g = await pinchHeld([180, 430], [220, 430], [100, 430], [300, 430]);
st = await state(); const b50 = await blur();
ok(near(st.view.s, 50, 0.3) && b50.on >= 290 && b50.mid <= 4 && r50.mid >= 4 * Math.max(1, b50.mid), `crisp at ${st.view.s.toFixed(1)}x: ${b50.on} px solid, ${b50.mid} edge px (the 1x render scaled: ${r50.mid})`);
// The background has no edge: at extreme pans and zooms every pixel away from a stroke is the background.
const allBg = () => page.evaluate(() => { const c = document.querySelector("canvas"), d = c.getContext("2d").getImageData(0, 0, c.width, c.height).data;
  let bad = 0; for (let i = 0; i < d.length; i += 4 * 97) if (Math.abs(d[i] - 0x12) > 2 || Math.abs(d[i + 1] - 0x12) > 2 || Math.abs(d[i + 2] - 0x16) > 2) bad++; return bad; });
const pageBg = await page.evaluate(() => getComputedStyle(document.querySelector("canvas").parentElement).backgroundColor);
ok(pageBg === "rgb(18, 18, 22)", `the page behind the canvas is the background too (${pageBg}): a pinch never shows a void`);
for (const [cx, cy, zoom] of [[1e6, -1e6, 50], [-3e5, 4e5, 0.01], [400, 860 + 5000, 50], [-1e4, 860, 1]]) {
  await page.evaluate(([cx, cy, zoom]) => { const s = JSON.parse(dump()); s.viewport = [{ key: "t", cx, cy, zoom, fit: false }]; sessionStorage.setItem("seed", JSON.stringify(s)); }, [cx, cy, zoom]);
  await page.reload(); await sleep(600);
  ok((await allBg()) === 0, `background fills the viewport at ${cx},${cy} zoom ${zoom} (scale ${(await state()).view.s.toFixed(2)})`);
}
// An older drawing's picture has no rectangle: around its corner at 10x, inside and outside read as the background.
const legacy = await page.evaluate(() => { const c = document.createElement("canvas"); c.width = 800; c.height = 1720; const g = c.getContext("2d"); g.fillStyle = "#121216"; g.fillRect(0, 0, 800, 1720); g.fillStyle = "#fff"; g.fillRect(400, 400, 100, 100); return c.toDataURL("image/webp", 0.85); });
await page.evaluate((png) => sessionStorage.setItem("seed", JSON.stringify({ drawing: [{ id: "1", title: "Old", image: png, width: 800, height: 1720, key: "o", base: png }], stroke: [], viewport: [{ key: "o", cx: 0, cy: 0, zoom: 5, fit: false }], next: 5 })), legacy);
await page.reload(); await sleep(800);
ok((await allBg()) === 0, `an older picture's edge never shows (its corner at 10x reads as the background)`);
const data2 = JSON.parse(await page.evaluate(() => dump()));
ok(data2.drawing[0].base === legacy && data2.drawing[0].image === legacy, `the older picture itself is unchanged`);

ok(errs.length === 0, `no page errors ${errs.join(" | ")}`);
await browser.close(); srv.close(); process.exit(fails ? 1 : 0);

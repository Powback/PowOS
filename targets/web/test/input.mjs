// Input reaches PowOS's desktop in the browser: resumes the published snapshot, waits for the desktop on the canvas,
// then right-clicks the desktop (Plasma's context menu) and presses Alt+Space (KRunner), each time checking that the
// canvas changes. Screenshots: OUT/input-{0-desktop,1-rightclick,2-krunner}.png.
//   URL, OUT, TIMEOUT (seconds per step, default 120)
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/';
const out = process.env.OUT || '/out';
const step = Number(process.env.TIMEOUT || 120) * 1000;
fs.mkdirSync(out, { recursive: true });

const browser = await chromium.launch({ args: ['--host-resolver-rules=MAP powos-web.pow traefik'] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 800 } });
const log = fs.createWriteStream(`${out}/input-console.log`);
page.on('console', (m) => log.write(m.text() + '\n'));
page.on('pageerror', (e) => log.write('PAGEERROR ' + e.message + '\n'));

// The canvas, downscaled: a fingerprint to compare frames with.
const grab = () => page.evaluate(() => {
  const src = document.getElementById('screen');
  const c = document.createElement('canvas');
  c.width = 160; c.height = 100;
  const g = c.getContext('2d');
  g.drawImage(src, 0, 0, c.width, c.height);
  return Array.from(g.getImageData(0, 0, c.width, c.height).data);
});
const lit = (px) => { let n = 0; for (let i = 0; i < px.length; i += 4) if (px[i] + px[i + 1] + px[i + 2] > 48) n++; return n / (px.length / 4); };
const diff = (a, b) => { let n = 0; for (let i = 0; i < a.length; i += 4) if (Math.abs(a[i] - b[i]) + Math.abs(a[i + 1] - b[i + 1]) + Math.abs(a[i + 2] - b[i + 2]) > 60) n++; return n / (a.length / 4); };
const shot = (name) => page.locator('#screen').screenshot({ path: `${out}/input-${name}.png` });

async function waitFor(cond, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await cond()) return true; await page.waitForTimeout(1000); }
  return false;
}

const t0 = Date.now();
await page.goto(url, { waitUntil: 'load' });
let base;
const ok0 = await waitFor(async () => (base = await grab()) && lit(base) > 0.2, step);
console.log(`desktop on canvas: ${ok0} after ${((Date.now() - t0) / 1000).toFixed(1)} s`);
if (!ok0) process.exit(1);
await page.waitForTimeout(5000);
base = await grab();
await shot('0-desktop');

const box = await page.locator('#screen').boundingBox();
const results = {};
// 1. Right-click on an empty part of the desktop: Plasma opens its context menu there.
await page.mouse.move(box.x + box.width * 0.6, box.y + box.height * 0.4);
await page.mouse.down({ button: 'right' });
await page.mouse.up({ button: 'right' });
let t = Date.now();
results.rightclick = await waitFor(async () => diff(base, await grab()) > 0.01, step);
console.log(`right-click changed the screen: ${results.rightclick} after ${((Date.now() - t) / 1000).toFixed(1)} s`);
await shot('1-rightclick');
await page.keyboard.press('Escape');
await page.waitForTimeout(3000);
const stats = () => page.evaluate(() => { const m = window.Module || {}; const s = m.powosStats; return s ? { frames: s.frames, events: s.events, ring: s.ring() } : null; });
console.log('after right-click:', JSON.stringify(await stats()));

// 2. Keyboard: Alt+Space opens KRunner.
base = await grab();
await page.keyboard.press('Alt+Space');
t = Date.now();
results.keyboard = await waitFor(async () => diff(base, await grab()) > 0.01, step);
console.log(`Alt+Space changed the screen: ${results.keyboard} after ${((Date.now() - t) / 1000).toFixed(1)} s`);
await shot('2-krunner');
console.log('after Alt+Space:', JSON.stringify(await stats()));

await browser.close();
process.exit(results.rightclick && results.keyboard ? 0 : 1);

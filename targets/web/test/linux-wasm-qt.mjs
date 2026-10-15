// A Qt program on Linux/Wasm: starts /powos/apps/qthello (Qt Widgets on linuxfb = the canvas) from the page's
// terminal, waits for QTHELLO READY, screenshots the canvas, then types on it and clicks (CLICK_X/CLICK_Y: canvas
// coordinates of the button, default from qthello's layout) and checks the program saw both. URL, OUT
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/linux-wasm/';
const out = process.env.OUT || '/out';
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ channel: process.env.CHANNEL || undefined, args: [`--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 1000 } });
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
const text = () => page.evaluate(() => {
  const b = window.lwTerm?.buffer.active, l = [];
  if (b) for (let i = 0; i < b.length; i++) l.push((b.getLine(i)?.translateToString(true) || '').trimEnd());
  return l.join('\n');
});
async function until(re, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const t = await text(); if (re.test(t)) return t; await page.waitForTimeout(200); }
  return null;
}
const t0 = Date.now();
await page.goto(url, { waitUntil: 'load' });
if (!await until(/^~ #( |$)/m, 120000)) { console.log('no shell'); process.exit(1); }
for (let last = '', same = 0; same < 10; await page.waitForTimeout(200)) { const t = await text(); same = t === last ? same + 1 : 0; last = t; }
await page.locator('#terminal').click();
const qtCmd = process.env.QT_CMD || 'qthello &'; // e.g. QT_CMD='QT_LOGGING_RULES=qt.qpa.input=true qthello &'
await page.keyboard.type(qtCmd);
await page.keyboard.press('Enter');
const tStart = Date.now();
const ready = await until(/QTHELLO READY|rror|not found|Abort|crash/i, (Number(process.env.TIMEOUT) || 120) * 1000);
const lines = (await text()).split('\n');
console.log(lines.slice(Math.max(0, lines.findLastIndex((l) => l.includes(qtCmd.slice(-12))))).filter(Boolean).slice(0, 25).join('\n'));
const canvas = page.locator('#screen');
await canvas.scrollIntoViewIfNeeded();
const box = await canvas.boundingBox();
await page.waitForTimeout(1500);
await page.screenshot({ path: `${out}/qthello.png`, clip: box });
if (!ready || !/QTHELLO READY/.test(ready)) { await page.waitForTimeout(1000); console.log('FAILED: no QTHELLO READY\n' + errors.slice(-3).join('\n')); await browser.close(); process.exit(1); }
console.log(`qthello ready after ${((Date.now() - tStart) / 1000).toFixed(1)} s (page load to ready ${((Date.now() - t0) / 1000).toFixed(1)} s)`);
// The canvas is 1280x800 in kernel pixels, scaled to the box.
const sx = box.width / 1280, sy = box.height / 800;
const editX = Number(process.env.EDIT_X || 640), editY = Number(process.env.EDIT_Y || 98);
const clickX = Number(process.env.CLICK_X || 640), clickY = Number(process.env.CLICK_Y || 130);
await page.mouse.click(box.x + editX * sx, box.y + editY * sy);
await page.keyboard.type('hi', { delay: 80 });
await page.mouse.click(box.x + clickX * sx, box.y + clickY * sy);
const typed = await until(/QTHELLO TEXT hi/, 15000);
const clicked = await until(/QTHELLO CLICKED/, 15000);
await page.waitForTimeout(1000);
await page.screenshot({ path: `${out}/qthello-after.png`, clip: box });
console.log((await text()).split('\n').filter((l) => /qt\.|evdev|QTHELLO/i.test(l)).slice(-25).join('\n'));
console.log(`typed ${!!typed}, clicked ${!!clicked}, input events ${await page.evaluate(() => globalThis.powosInputEvents)}`);
if (errors.length) console.log('page errors:\n' + errors.slice(-3).join('\n'));
await browser.close();
process.exit(typed && clicked ? 0 : 2);

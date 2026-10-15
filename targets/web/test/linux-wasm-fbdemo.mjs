// A PowOS graphical program in Linux/Wasm: starts /powos/apps/fbdemo (framebuffer + input), moves the pointer and
// types on the canvas, and screenshots the page. URL, OUT
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/linux-wasm/';
const out = process.env.OUT || '/out';
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ channel: process.env.CHANNEL || undefined, args: [`--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`] });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 900 } });
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
await page.goto(url, { waitUntil: 'load' });
if (!await until(/^~ #( |$)/m, 120000)) { console.log('no shell'); process.exit(1); }
await page.locator('#terminal').click();
await page.keyboard.type('/powos/apps/fbdemo &');
await page.keyboard.press('Enter');
const started = await until(/fbdemo: \d+x\d+|mmap fb0|not found|can.t open/m, 30000);
await page.waitForTimeout(1000);
console.log((started || '').split('\n').filter((l) => /fbdemo|fb0|found|can't/.test(l)).slice(-3).join('\n'));
const canvas = page.locator('#screen');
// Clicking the terminal scrolls the page: bring the canvas into view and measure it after that (a stale box put the
// pointer moves above the canvas).
await canvas.scrollIntoViewIfNeeded();
const box = await canvas.boundingBox();
await canvas.click({ position: { x: box.width / 2, y: box.height / 2 } });
await page.keyboard.type('PowOS on Wasm');
for (let i = 0; i <= 30; i++) await page.mouse.move(box.x + 100 + i * 25, box.y + 300 + Math.sin(i / 3) * 80);
await page.waitForTimeout(2000);
await page.screenshot({ path: `${out}/fbdemo.png`, clip: { x: box.x, y: box.y, width: box.width, height: box.height } });
console.log(`input events ${await page.evaluate(() => globalThis.powosInputEvents)}, frames ${await page.evaluate(() => globalThis.powosFrames)}`);
await browser.close();

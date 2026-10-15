// The shell on the canvas (tty1 on the framebuffer console): types commands on the canvas itself and screenshots it.
// URL, OUT
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
const t0 = Date.now();
await page.goto(url, { waitUntil: 'load' });
while (Date.now() - t0 < 120000 && !/^~ #( |$)/m.test(await text())) await page.waitForTimeout(300); // kernel lines may follow the prompt
await page.waitForTimeout(1500);
const canvas = page.locator('#screen');
await canvas.scrollIntoViewIfNeeded();
await canvas.click({ position: { x: 300, y: 300 } });
for (const cmd of ['ls /powos', 'uname -a', 'ls /powos/apps']) {
  await page.keyboard.type(cmd, { delay: 30 });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(1500);
}
const box = await canvas.boundingBox();
await page.screenshot({ path: `${out}/canvas-shell.png`, clip: { x: box.x, y: box.y, width: box.width, height: Math.min(box.height, 400) } });
console.log(`boot+commands ${((Date.now() - t0) / 1000).toFixed(1)} s, input events ${await page.evaluate(() => globalThis.powosInputEvents)}`);
await browser.close();

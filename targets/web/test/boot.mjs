// Boots PowOS Web in headless Chromium and waits for the login prompt on the serial console.
// Reports the boot time and what the streamed disk fetched (QEMU's chunked driver logs it to the console).
//   URL      page to open (default https://powos-web.pow/)
//   TIMEOUT  seconds to wait (default 1800: emulated in wasm, a first boot is slow)
//   WAIT_FOR regex that means done (default: a login prompt; tcg-check: 'tcg-check done')
//   PRESS_ENTER  1: press Enter in the terminal every 2 s (a resumed snapshot sits at its prompt silently)
//   OUT      directory for console.log, serial.txt, screen.png
//   DESKTOP  1: done means the DESKTOP is on the canvas (a fifth of it lit and many colours), not a serial prompt.
//            A black canvas or a text console never passes - "a frame arrived" is not "PowOS is showing".
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/';
const timeout = Number(process.env.TIMEOUT || 1800) * 1000;
const out = process.env.OUT || '/out';
const waitFor = new RegExp(process.env.WAIT_FOR || 'login:\\s*$', 'm');
fs.mkdirSync(out, { recursive: true });

const browser = await chromium.launch({
  channel: process.env.CHANNEL || undefined, // CHANNEL=chrome: the installed Google Chrome (test/boot-mac.sh)
  args: [
    // Inside Docker the LAN name doesn't resolve: send it to Traefik on the shared network (RESOLVE overrides).
    `--host-resolver-rules=MAP powos-web.pow ${process.env.RESOLVE || 'traefik'}`,
    '--enable-features=SharedArrayBuffer',
  ],
});
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 800 } });
const log = fs.createWriteStream(`${out}/console.log`);
let lastFetch = '';
page.on('console', (m) => {
  const t = m.text();
  log.write(t + '\n');
  if (t.startsWith('chunked:')) lastFetch = t;
});
page.on('pageerror', (e) => log.write('PAGEERROR ' + e.message + '\n'));

const start = Date.now();
await page.goto(url, { waitUntil: 'load' });
const isolated = await page.evaluate(() => crossOriginIsolated);
console.log(`crossOriginIsolated=${isolated}`);

const serial = () => page.evaluate(() => {
  const b = window.powosTerm?.buffer.active;
  if (!b) return '';
  const lines = [];
  for (let i = 0; i < b.length; i++) lines.push(b.getLine(i)?.translateToString(true) ?? '');
  return lines.join('\n');
});

// What the canvas shows: share of lit pixels and how many distinct (quantised) colours.
const canvasLook = () => page.evaluate(() => {
  const src = document.getElementById('screen');
  if (!src || !src.width) return { lit: 0, colours: 0 };
  const c = document.createElement('canvas');
  c.width = 320; c.height = 200;
  const g = c.getContext('2d');
  g.drawImage(src, 0, 0, c.width, c.height);
  const d = g.getImageData(0, 0, c.width, c.height).data;
  let lit = 0;
  const colours = new Set();
  for (let i = 0; i < d.length; i += 4) {
    if (d[i] + d[i + 1] + d[i + 2] > 48) lit++;
    colours.add((d[i] >> 4) << 8 | (d[i + 1] >> 4) << 4 | d[i + 2] >> 4);
  }
  return { lit: lit / (d.length / 4), colours: colours.size };
});
const desktop = process.env.DESKTOP === '1';

let text = '';
let ok = false;
let look = { lit: 0, colours: 0 };
while (Date.now() - start < timeout) {
  text = await serial();
  fs.writeFileSync(`${out}/serial.txt`, text); // as it goes: a hung boot still leaves its log
  if (desktop) {
    look = await canvasLook();
    if (look.lit > 0.2 && look.colours > 40) { ok = true; break; }
  } else if (waitFor.test(text)) { ok = true; break; }
  if (/Freezing execution|Kernel panic|Aborted\(/.test(text)) {
    console.log('BOOT FAILED:\n' + text.trim().split('\n').slice(-25).join('\n'));
    break;
  }
  if (process.env.PRESS_ENTER === '1') {
    await page.evaluate(() => window.powosTerm?.focus());
    await page.keyboard.press('Enter');
    await page.waitForTimeout(2000);
  } else {
    await page.waitForTimeout(5000);
  }
  const s = Math.round((Date.now() - start) / 1000);
  if (s % 60 < 5) console.log(`${s}s: ${text.trim().split('\n').pop()?.slice(0, 120) || '(no serial output yet)'} | ${lastFetch}`);
}
const secs = Math.round((Date.now() - start) / 1000);
fs.writeFileSync(`${out}/serial.txt`, text);
await page.screenshot({ path: `${out}/screen.png` });
const goal = desktop ? 'desktop on the canvas' : waitFor;
console.log(ok ? `DONE (${goal}) after ${secs}s` : `NOT DONE (${goal}) after ${secs}s`);
if (desktop) console.log(`canvas: ${Math.round(look.lit * 100)}% lit, ${look.colours} colours`);
console.log(`disk: ${lastFetch || '(nothing reported)'}`);
await browser.close();
process.exit(ok ? 0 : 1);

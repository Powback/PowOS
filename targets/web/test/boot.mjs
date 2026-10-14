// Boots PowOS Web in headless Chromium and waits for the login prompt on the serial console.
// Reports the boot time and what the streamed disk fetched (QEMU's chunked driver logs it to the console).
//   URL      page to open (default https://powos-web.pow/)
//   TIMEOUT  seconds to wait (default 1800: emulated in wasm, a first boot is slow)
//   WAIT_FOR regex that means done (default: a login prompt; tcg-check: 'tcg-check done')
//   OUT      directory for console.log, serial.txt, screen.png
import { chromium } from 'playwright';
import fs from 'node:fs';

const url = process.env.URL || 'https://powos-web.pow/';
const timeout = Number(process.env.TIMEOUT || 1800) * 1000;
const out = process.env.OUT || '/out';
const waitFor = new RegExp(process.env.WAIT_FOR || 'login:\\s*$', 'm');
fs.mkdirSync(out, { recursive: true });

const browser = await chromium.launch({
  args: [
    // Inside Docker the LAN name doesn't resolve: send it to Traefik on the shared network.
    '--host-resolver-rules=MAP powos-web.pow traefik',
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

let text = '';
let ok = false;
while (Date.now() - start < timeout) {
  text = await serial();
  fs.writeFileSync(`${out}/serial.txt`, text); // as it goes: a hung boot still leaves its log
  if (waitFor.test(text)) { ok = true; break; }
  if (/Freezing execution|Kernel panic|Aborted\(/.test(text)) {
    console.log('BOOT FAILED:\n' + text.trim().split('\n').slice(-25).join('\n'));
    break;
  }
  await page.waitForTimeout(5000);
  const s = Math.round((Date.now() - start) / 1000);
  if (s % 60 < 5) console.log(`${s}s: ${text.trim().split('\n').pop()?.slice(0, 120) || '(no serial output yet)'} | ${lastFetch}`);
}
const secs = Math.round((Date.now() - start) / 1000);
fs.writeFileSync(`${out}/serial.txt`, text);
await page.screenshot({ path: `${out}/screen.png` });
console.log(ok ? `DONE (${waitFor}) after ${secs}s` : `NOT DONE (${waitFor}) after ${secs}s`);
console.log(`disk: ${lastFetch || '(nothing reported)'}`);
await browser.close();
process.exit(ok ? 0 : 1);

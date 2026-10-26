/**
 * A contact sheet of two shot runs (dev/shots.mjs): one row per scene - before | after, folded and unfolded - as one
 * PNG. Mounted: /a (before), /b (after), /out. Env: SHEET_TITLE, SHEET_NAME (default sheet.png).
 */
import fs from "node:fs";
import puppeteer from "puppeteer";

const shots = (d) => (fs.existsSync(d) ? fs.readdirSync(d).filter((f) => f.endsWith(".png")) : []);
const names = [...new Set([...shots("/a"), ...shots("/b")].map((f) => f.replace(/-(folded|unfolded)\.png$/, "")))];
const order = ["home", "home-p2", "edit", "edit-theme", "edit-picker", "drawer", "search-typing", "ai", "ai-compose", "widget-screen", "notifications", "settings", "assist", "shade", "control", "switcher", "lock"];
names.sort((x, y) => (order.indexOf(x) + 1 || 99) - (order.indexOf(y) + 1 || 99));
const img = (d, n, s) => {
  const f = `${d}/${n}-${s}.png`;
  return fs.existsSync(f) ? `<img src="data:image/png;base64,${fs.readFileSync(f).toString("base64")}">` : `<div class="none">-</div>`;
};
const rows = names
  .map((n) => `<tr><th>${n}</th><td>${img("/a", n, "folded")}</td><td>${img("/b", n, "folded")}</td><td class="gap"></td><td class="w">${img("/a", n, "unfolded")}</td><td class="w">${img("/b", n, "unfolded")}</td></tr>`)
  .join("");
const html = `<html><head><style>
body { margin: 0; background: #111; color: #ddd; font: 14px monospace; }
h1 { font-size: 18px; margin: 12px 16px; }
table { border-spacing: 8px; }
th { writing-mode: vertical-rl; transform: rotate(180deg); font-size: 15px; }
td img { width: 202px; display: block; } td.w img { width: 410px; }
td.gap { width: 16px; } .none { width: 202px; text-align: center; }
thead td { text-align: center; color: #999; }
</style></head><body><h1>${process.env.SHEET_TITLE ?? ""}</h1><table>
<thead><tr><td></td><td>before · folded</td><td>after · folded</td><td></td><td>before · unfolded</td><td>after · unfolded</td></tr></thead>
${rows}</table></body></html>`;
const browser = await puppeteer.launch({ executablePath: process.env.CHROME || "/usr/bin/chromium-browser", headless: true, args: ["--no-sandbox", "--disable-dev-shm-usage"] });
const page = await browser.newPage();
await page.setViewport({ width: 1340, height: 800, deviceScaleFactor: 1 });
await page.setContent(html, { waitUntil: "load" });
await page.screenshot({ path: `/out/${process.env.SHEET_NAME ?? "sheet.png"}`, fullPage: true });
await browser.close();

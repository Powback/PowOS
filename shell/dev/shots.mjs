/**
 * Design QA's renders (shell/dev/gate.sh --shots DIR runs it, in the gate's headless Chromium, after the boot check):
 * every surface of the shell - home's pages, edit mode, the widget picker, the theme popover, the drawer, search idle
 * and typing, PowOS AI's page and its compose, the assistant, the shade and the control center, the switcher, the lock
 * face, the settings screen - at the phone's two screens (the cover: 404x899 CSS px, the inner: 821x883), over a
 * wallpaper, in a theme, as the phone draws them (insets, html.glass-native emulated: the compositor's blur behind each
 * surface is a backdrop-filter here). docs/DESIGN-LANGUAGE.md is what they're judged against.
 *
 * Out: DIR/<scene>-<folded|unfolded>.png, and DIR/report.json - per shot, the text below 4.5:1 contrast (3:1 for
 * large text) against what is actually drawn behind it (the shot again with all text transparent, the box's pixels
 * averaged), and the page's errors.
 *
 * Mounted: /shell (the composed shell), /out (DIR), optionally /wallpaper.jpg. Env: SHOTS_THEME (gruvbox|kanagawa|
 * flexoki-light, default gruvbox: the user's), SHOTS_ONLY (a regex over scene names), SHOTS_SCALE (device scale, 1).
 */
import fs from "node:fs";
import path from "node:path";
import puppeteer from "puppeteer";

const ORIGIN = "https://shell.powos";
const ROOT = "/shell";
const OUT = "/out";
const SCALE = Number(process.env.SHOTS_SCALE || 1);
const ONLY = process.env.SHOTS_ONLY ? new RegExp(process.env.SHOTS_ONLY) : null;
/** A shot had overlapping tiles or missing glyphs (SHOTS_STRICT=1 fails the run on it). */
let strictFailed = false;

/** The phone's screens (OnePlus Open, density 442: 2.7625 px a CSS px) and its insets there. */
const SIZES = {
  folded: { width: 404, height: 899, insets: { top: 45.6, bottom: 16.3 } },
  unfolded: { width: 821, height: 883, insets: { top: 45.6, bottom: 16.3 } },
};
/** The desktop's home (mode=desktop, powos-shell): the phone's own Plasma session's screen, and a laptop's. */
const DESKTOP_SIZES = {
  plasma: { width: 558, height: 1198, insets: { top: 0, bottom: 0 } },
  laptop: { width: 1280, height: 800, insets: { top: 0, bottom: 0 } },
};

/**
 * Themes as the host hands them over (ShellBridge.themeColors from ui/Theme.kt's palette: surface = lighter_background,
 * muted = dark_foreground, border = muted, overlay = background at 90%).
 */
const THEMES = {
  gruvbox: {
    light: false,
    bg: "#282828", surface: "#3c3836", fg: "#d4be98", muted: "#7c6f64", accent: "#7daea3", border: "#665c54", red: "#ea6962", green: "#a9b665",
  },
  kanagawa: {
    light: false,
    bg: "#1f1f28", surface: "#2a2a37", fg: "#dcd7ba", muted: "#727169", accent: "#7e9cd8", border: "#54546d", red: "#e82424", green: "#98bb6c",
  },
  "flexoki-light": {
    light: true,
    bg: "#fffcf0", surface: "#f2f0e5", fg: "#100f0f", muted: "#6f6e69", accent: "#205ea6", border: "#cecdc3", red: "#af3029", green: "#66800b",
  },
};
const THEME_NAME = THEMES[process.env.SHOTS_THEME] ? process.env.SHOTS_THEME : "gruvbox";
const THEME = THEMES[THEME_NAME];
/**
 * The mock home's OWL trees, evaluated in the theme rendered (dev/sample-trees.sh writes one set per theme): served
 * for dev/sample-trees.json. Trees of another theme carry its colours, which owl.tsx can't map to this theme's tokens
 * (a gruvbox grey drawn in kanagawa measured 4.0:1 the phone doesn't have) - so a missing or mismatched set refuses
 * the run, and every page checks what it was given.
 */
const TREES = path.join(ROOT, "dev/sample-trees", `${THEME_NAME}.json`);
{
  const t = fs.existsSync(TREES) ? JSON.parse(fs.readFileSync(TREES, "utf8"))._theme : null;
  if (t !== THEME_NAME) {
    console.error(`shots: the mock OWL trees for ${THEME_NAME} ${t ? `are ${t}'s` : "are missing"} (${TREES}) - run shell/dev/sample-trees.sh ${THEME_NAME}`);
    process.exit(2);
  }
}
let treesWrong = 0;

function mime(p) {
  const ext = p.slice(p.lastIndexOf(".") + 1).toLowerCase();
  return (
    { html: "text/html", js: "text/javascript", mjs: "text/javascript", ts: "text/plain", tsx: "text/plain", css: "text/css", json: "application/json",
      wasm: "application/wasm", svg: "image/svg+xml", png: "image/png", jpg: "image/jpeg", webp: "image/webp", woff2: "font/woff2", ttf: "font/ttf" }[ext] ??
    "application/octet-stream"
  );
}

const WALLPAPER = fs.existsSync("/wallpaper.jpg") ? "/wallpaper.jpg" : null;
/** Without one: a busy gradient, so glass and seams show. */
const FALLBACK_WP =
  "data:image/svg+xml," +
  encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="900"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">` +
      `<stop offset="0" stop-color="#0b1020"/><stop offset=".5" stop-color="#5a7fb0"/><stop offset="1" stop-color="#c08050"/></linearGradient></defs>` +
      `<rect width="400" height="900" fill="url(#g)"/><circle cx="300" cy="420" r="160" fill="#a8d0ff" opacity=".6"/></svg>`,
  );

/** A conversation with every kind of rich part (ui/rich.tsx), for the chat scenes. */
const CHAT_SAMPLE = JSON.stringify([
  { kind: "user", text: "is the phone healthy? anything I should clean up?" },
  { kind: "tool", name: "Bash", hint: "powos status", ok: true, out: "Layers  custom,updates,base\nRAM     1.2G of 8G used\nUSB     connected, synced 30s ago" },
  { kind: "tool", name: "Read", hint: "/home/powos/.local/state/powos/units.json", ok: true },
  { kind: "tool", name: "Bash", hint: "df -h /var", ok: true, out: "Filesystem  Size  Used Avail Use%\n/dev/sda3   200G  182G   18G  91%" },
  { kind: "tool", name: "mcp__comms__send_message", hint: "devops", ok: false, out: "Error: devops inbox is full" },
  { kind: "assistant", text: "Mostly **healthy**. One thing:\n\n- `/var` is at **91%**: old container images take 40 GB\n- the devops inbox is full, so I couldn't hand it over\n\n```\npowos containers prune --older 30d\n```\nSee [the units](https://powos.pow/units)." },
  { kind: "assistant", text: "```choices\n" + JSON.stringify({ question: "Prune the old images?", options: ["Prune all 12", "Only the unused ones", "Not now"] }) + "\n```" },
]);

/** Two presented documents (```present): a Markdown plan and an HTML review sheet. */
const PLAN_MD = [
  "# Cleanup plan",
  "Frees about **38 GB** on `/var`, nothing running is touched.",
  "## Steps",
  "1. Stop the idle containers (`powos containers autosleep status`)",
  "2. Prune images older than 30 days",
  "   - keeps the ones a unit names",
  "3. Re-check `df -h /var`",
  "| image | size | last used |",
  "|---|---|---|",
  "| spacetimedb:1.2 | 14 GB | 41 days |",
  "| builder:old | 11 GB | 63 days |",
  "| fex-rootfs | 9 GB | 90 days |",
  "> Rollback: images can be pulled again; nothing else is deleted.",
  "```",
  "powos containers prune --older 30d",
  "```",
  "Details: [the units](https://powos.pow/units)",
].join("\n");
const SHEET_HTML = `<style>body{margin:0;font:13px system-ui}h1{font-size:18px;margin:0 0 10px}.g{display:grid;grid-template-columns:1fr 1fr;gap:10px}.c{border-radius:10px;padding:10px;background:color-mix(in srgb,currentColor 10%,transparent)}.c b{display:block;margin-bottom:6px}.sw{height:60px;border-radius:8px;background:linear-gradient(135deg,#3a5f8f,#c08050)}</style><h1>Review: chat cards</h1><div class="g"><div class="c"><b>Before</b><div class="sw"></div>raw tool lines</div><div class="c"><b>After</b><div class="sw" style="filter:saturate(1.6)"></div>one line per run</div></div>`;
const PRESENT_SAMPLE = JSON.stringify([
  { kind: "user", text: "plan the cleanup and show me the review sheet" },
  { kind: "tool", name: "mcp__comms__present", hint: "", ok: true },
  { kind: "assistant", text: "Here's the plan:" },
  { kind: "assistant", text: "```present\n" + JSON.stringify({ title: "Cleanup plan", format: "md", body: PLAN_MD }) + "\n```" },
  { kind: "assistant", text: "```present\n" + JSON.stringify({ title: "Review: chat cards", format: "html", body: SHEET_HTML }) + "\n```" },
]);

/** The work board as it was live (dev/sample-board.json, ages as offsets), for PowOS AI's page. */
const BOARD = (() => {
  // In the render container the shell is at /shell (dev/shot.sh, gate.sh); run in place, next to this file.
  for (const f of ["/shell/dev/sample-board.json", new URL("./sample-board.json", import.meta.url)])
    try {
      return fs.readFileSync(f, "utf8");
    } catch {}
  return "[]";
})();
/** The same, the waiting items' notes written as what to do (how agents are asked to write them). */
const ACTIONS = JSON.stringify({
  "phone-kernel-build-build-only": "Plug the phone into the Mac's USB once, for the kernel build",
  "search-bar-as-a-movable-widget-below-dock-too": "Long-press home, then drag the search bar below the dock",
  "broforce-doesn-t-start-proton-under-fex": "Play Broforce for ten minutes and say if it stutters",
});
const board = (actions) =>
  `const B = ${BOARD}; const A = ${actions ? ACTIONS : "{}"}; const now = Date.now(); const P = await U('./ui/powai.tsx');` +
  ` P.board.value = B.map((r) => ({ ...r, note: A[r.id] ?? r.note, created: now - r.createdAgo, updated: now - r.updatedAgo, done: r.doneAgo ? now - r.doneAgo : 0 }));` +
  ` P.boardSeen.value = true; S.chat.value = { busy: false, items: [{ kind: "user", text: "what changed overnight?" }, { kind: "assistant", text: "Three pushes: the shade, the pet, the speech fix." }, ...${CHAT_SAMPLE}] }; S.page.value = -1; await sleep(300);`;

/**
 * The scenes: [name, mode, setup] - setup runs in the page once it's ready (S: state.ts, U: an import by path, E: the
 * mock's events, sleep). `behind`: what the window is over - "wallpaper" (home: native glass), "blurred" (the shade,
 * the switcher: the host blurs the app under them), "app" (the assistant, over an app as it is).
 */
/**
 * The desktop's first home as hosts/desktop.ts makes it (no OWL widgets there; islands without STDB show their fault
 * tile headless). The launcher's will-change dropped: as a backdrop root it kept the emulated blur from reaching the
 * wallpaper (KWin blurs its region on the device).
 */
const DESKTOP_HOME = `{ const B = (await U('./bridge.ts')).powos; for (const i of (await B.home.get()).items) await B.home.remove(i.key); const cols = Math.max(4, Math.round(innerWidth / 100)); const w = cols >= 8 ? 3 : Math.max(2, Math.floor((cols - 1) / 2)); const across = Math.max(1, Math.floor((cols + 1) / (w + 1))); let i = 0, y = 0, rowH = 0; for (const [n, h] of [['agents', 2], ['app:local.lights/main', 2], ['app:local.shopping/main', 2]]) { if (i % across === 0 && i > 0) { y += rowH + 1; rowH = 0; } rowH = Math.max(rowH, h); await B.home.addPanel(n, 1, { x: (i % across) * (w + 1), y, w, h }); i++; } await sleep(300); S.home.value = { ...S.home.value, columns: cols }; const st = document.createElement('style'); st.textContent = '.launcher { will-change: auto !important; transform: none !important; }'; document.head.append(st); await sleep(300); }`;
const SCENES = [
  ["home", "home", "", "wallpaper"],
  ["home-p2", "home", "S.page.value = 1;", "wallpaper"],
  ["edit", "home", "S.editing.value = true;", "wallpaper"],
  ["edit-theme", "home", "S.editing.value = true; await sleep(200); [...document.querySelectorAll('.edit-act')].find(b => b.textContent.trim() === 'theme')?.click();", "wallpaper"],
  ["edit-picker", "home", "S.editing.value = true; await sleep(150); (await U('./ui/appwidget.tsx')).picker.value = true;", "wallpaper"],
  ["drawer", "home", "S.drawer.value = 1;", "wallpaper"],
  ["swipe-up-right", "home", "", "wallpaper", { from: [0.73, 0.72], to: [0.73, 0.28], ms: 220 }],
  ["swipe-up-left", "home", "", "wallpaper", { from: [0.25, 0.72], to: [0.25, 0.28], ms: 220 }],
  ["search-widget", "home", "await (await U('./bridge.ts')).powos.home.addPanel('search', 0, { x: 0, y: 4, w: 6, h: 1 }); await sleep(300);", "wallpaper"],
  ["pill-below-dock", "home", "(await U('./ui/searchwidget.tsx')).footBelow.value = '1';", "wallpaper"],
  ["ai-panel", "home", "S.openPanel('ai');", "wallpaper"],
  ["search-typing", "home", "const f = document.querySelector('.bar textarea, .bar input'); f?.focus(); if (f) { f.value = 'weather tomorrow in oslo and remind me to bring an umbrella'; f.dispatchEvent(new Event('input', { bubbles: true })); }", "wallpaper"],
  ["ai", "home", "S.page.value = -1;", "wallpaper"],
  ["chat", "home", `S.chat.value = { busy: false, items: ${CHAT_SAMPLE} }; S.chatting.value = true; S.drawer.value = 1;`, "wallpaper"],
  ["chat-open", "home", `S.chat.value = { busy: false, items: ${CHAT_SAMPLE} }; S.chatting.value = true; S.drawer.value = 1; await sleep(300); document.querySelector('.chat .tl-row')?.click(); await sleep(100); document.querySelectorAll('.chat .tl-row.has-out')[0]?.click(); document.querySelectorAll('.chat .tl-row.has-out')[2]?.click();`, "wallpaper"],
  ["present", "home", `S.chat.value = { busy: false, items: ${PRESENT_SAMPLE} }; S.chatting.value = true; S.drawer.value = 1;`, "wallpaper"],
  ["present-md", "home", `S.chat.value = { busy: false, items: ${PRESENT_SAMPLE} }; S.chatting.value = true; S.drawer.value = 1; await sleep(300); document.querySelectorAll('.chat .present')[0]?.click();`, "wallpaper"],
  ["present-html", "home", `S.chat.value = { busy: false, items: ${PRESENT_SAMPLE} }; S.chatting.value = true; S.drawer.value = 1; await sleep(300); document.querySelectorAll('.chat .present')[1]?.click(); await sleep(200);`, "wallpaper"],
  ["ai-v2", "home", board(false), "wallpaper"],
  ["ai-v2-actions", "home", board(true), "wallpaper"],
  ["ai-v2-open", "home", board(true) + " document.querySelectorAll('.ai-work-list .ai-fold, .ai-history .ai-fold').forEach((b) => b.click()); await sleep(100); document.querySelector('.ai-screen .ai-item')?.click(); await sleep(100); document.querySelector('.ai-work-list').scrollIntoView();", "wallpaper"],
  ["ai-v2-calm", "home", board(true).replace("P.board.value = B.map", "P.board.value = B.filter((r) => r.status !== 'waiting').map"), "wallpaper"],
  ["queued", "home", `S.chat.value = { busy: true, items: ${CHAT_SAMPLE}.slice(0, 3), queued: [{ id: 1, text: "also check the battery health" }, { id: 2, text: "and remind me at 6 to charge it" }] }; S.chatting.value = true; S.drawer.value = 1;`, "wallpaper"],
  ["queued-ai", "home", `S.chat.value = { busy: true, items: ${CHAT_SAMPLE}.slice(0, 3), queued: [{ id: 1, text: "also check the battery health" }, { id: 2, text: "and remind me at 6 to charge it" }] }; S.page.value = -1;`, "wallpaper"],
  ["kbd-chat", "home", `E.emit('system.insets', { top: 45, bottom: 16, left: 0, right: 0, keyboard: 330 }); S.chat.value = { busy: false, items: ${CHAT_SAMPLE} }; S.chatting.value = true; S.drawer.value = 1;`, "wallpaper"],
  ["kbd-ai", "home", `E.emit('system.insets', { top: 45, bottom: 16, left: 0, right: 0, keyboard: 330 }); S.page.value = -1;`, "wallpaper"],
  ["kbd-assist", "assist", "E.emit('system.insets', { top: 45, bottom: 16, left: 0, right: 0, keyboard: 0 }); await sleep(200); E.emit('assist.context', { text: 'Inbox - 3 unread', screenshot: window.__shotsApp });", "app"],
  ["ai-chat", "home", `S.chat.value = { busy: false, items: ${CHAT_SAMPLE} }; S.page.value = -1;`, "wallpaper"],
  ["ai-compose", "home", "S.page.value = -1; await sleep(300); const f = document.querySelector('.ai-compose textarea, .ai-compose input'); f?.focus(); if (f) { f.value = 'summarise what the agents did overnight and what needs me'; f.dispatchEvent(new Event('input', { bubbles: true })); }", "wallpaper"],
  ["widget-screen", "home", "const w = S.home.value.items.find((i) => i.kind === 'widget'); S.screen.value = { key: w.key, title: 'weather' };", "wallpaper"],
  ["settings", "home", "(await U('./screens.ts')).openScreen('settings');", "wallpaper"],
  // The desktop's home: a laptop-wide grid (as hosts/desktop.ts's first home: ~110 px a column), the launcher, the chat.
  ["desktop", "desktop", DESKTOP_HOME, "wallpaper"],
  ["desktop-launcher", "desktop", DESKTOP_HOME + " S.drawer.value = 1;", "wallpaper"],
  ["desktop-chat", "desktop", DESKTOP_HOME + ` S.chat.value = { busy: false, items: ${CHAT_SAMPLE} }; S.chatting.value = true; S.drawer.value = 1;`, "wallpaper"],
  ["pull-apps", "pull", "E.emit('pull.begin', { kind: 'apps' }); E.emit('pull.drag', { p: 0.6 }); E.emit('pull.end', { open: true });", "blurred"],
  ["pull-ai", "pull", "E.emit('pull.begin', { kind: 'ai' }); E.emit('pull.end', { open: true });", "blurred"],
  ["assist", "assist", "await sleep(200); E.emit('assist.context', { text: 'Inbox - 3 unread', screenshot: window.__shotsApp });", "app"],
  // Its field is the one pill: a long question wraps to three rows, then scrolls inside; dictation streams in, newest in view.
  ["assist-typing", "assist", "await sleep(200); E.emit('assist.context', { text: 'Inbox - 3 unread', screenshot: window.__shotsApp }); await sleep(1500); const f = document.querySelector('.assist-ask textarea'); if (f) { f.value = 'which of these three unread mails need an answer from me today, and draft a short reply to the one from the landlord about the heating'; f.dispatchEvent(new Event('input', { bubbles: true })); } await sleep(200);", "app"],
  ["assist-dictating", "assist", "await sleep(1500); E.emit('assist.reset', null); E.emit('assist.context', { text: 'Inbox - 3 unread', screenshot: window.__shotsApp }); E.emit('assist.held', null); const B = (await U('./bridge.ts')).powos; await B.speech.cancel(); E.emit('speech.state', { listening: true, error: null, text: 'okay so look at this inbox and tell me which of these mails I actually have to answer today because I keep forgetting the one from the landlord about the heating and the plumber is coming on thursday' }); await sleep(250);", "app"],
  ["shade", "shade", "S.panel.value = 'notifications'; S.notif.value = true;", "blurred"],
  ["shade-group-open", "shade", "S.panel.value = 'notifications'; S.notif.value = true; await sleep(300); [...document.querySelectorAll('.notif-stack .notif')].find((c) => c.textContent.includes('Gmail'))?.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, clientX: 50, clientY: 50 })); document.querySelectorAll('.notif-stack .notif')[0] && [...document.querySelectorAll('.notif-stack .notif')].find((c) => c.textContent.includes('Gmail'))?.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, clientX: 50, clientY: 50 }));", "blurred"],
  ["pull-3-start", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.panel.value = 'notifications'; (await U('./ui/gesture.ts')).notifDrag.value = 0.25;", "blurred"],
  ["pull-3-half", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.panel.value = 'notifications'; (await U('./ui/gesture.ts')).notifDrag.value = 0.5;", "blurred"],
  ["pull-3-open", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.panel.value = 'notifications'; S.notif.value = true;", "blurred"],
  ["pull-15-start", "shade", "const now = Math.floor(Date.now() / 1000); const apps = ['Signal', 'Gmail', 'Calendar', 'Slack', 'Spotify', 'Maps', 'Bank', 'Weather']; E.emit('notifications.changed', { available: true, items: Array.from({ length: 15 }, (_, i) => ({ key: 'm' + i, app: apps[i % apps.length], icon: null, title: 'Notification ' + (i + 1), text: 'Something happened ' + (i * 7 + 2) + ' min ago.', time: now - i * 420 - 60, clearable: true, profile: null, conversation: i === 0 })) }); await sleep(200); S.panel.value = 'notifications'; (await U('./ui/gesture.ts')).notifDrag.value = 0.25;", "blurred"],
  ["pull-15-half", "shade", "const now = Math.floor(Date.now() / 1000); const apps = ['Signal', 'Gmail', 'Calendar', 'Slack', 'Spotify', 'Maps', 'Bank', 'Weather']; E.emit('notifications.changed', { available: true, items: Array.from({ length: 15 }, (_, i) => ({ key: 'm' + i, app: apps[i % apps.length], icon: null, title: 'Notification ' + (i + 1), text: 'Something happened ' + (i * 7 + 2) + ' min ago.', time: now - i * 420 - 60, clearable: true, profile: null, conversation: i === 0 })) }); await sleep(200); S.panel.value = 'notifications'; (await U('./ui/gesture.ts')).notifDrag.value = 0.5;", "blurred"],
  ["pull-15-open", "shade", "const now = Math.floor(Date.now() / 1000); const apps = ['Signal', 'Gmail', 'Calendar', 'Slack', 'Spotify', 'Maps', 'Bank', 'Weather']; E.emit('notifications.changed', { available: true, items: Array.from({ length: 15 }, (_, i) => ({ key: 'm' + i, app: apps[i % apps.length], icon: null, title: 'Notification ' + (i + 1), text: 'Something happened ' + (i * 7 + 2) + ' min ago.', time: now - i * 420 - 60, clearable: true, profile: null, conversation: i === 0 })) }); await sleep(200); S.panel.value = 'notifications'; S.notif.value = true;", "blurred"],
  ["drop-20", "shade", "S.panel.value = 'notifications'; (await U('./ui/gesture.ts')).notifDrag.value = 0.2;", "blurred"],
  ["drop-50", "shade", "S.panel.value = 'notifications'; (await U('./ui/gesture.ts')).notifDrag.value = 0.5;", "blurred"],
  ["drop-80", "shade", "S.panel.value = 'notifications'; (await U('./ui/gesture.ts')).notifDrag.value = 0.8;", "blurred"],
  ["drop-cc-20", "shade", "S.panel.value = 'control'; (await U('./ui/gesture.ts')).notifDrag.value = 0.2;", "blurred"],
  ["drop-cc-50", "shade", "S.panel.value = 'control'; (await U('./ui/gesture.ts')).notifDrag.value = 0.5;", "blurred"],
  ["drop-cc-80", "shade", "S.panel.value = 'control'; (await U('./ui/gesture.ts')).notifDrag.value = 0.8;", "blurred"],
  ["cascade-n-010", "shade", "S.panel.value = 'notifications'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.1;", "blurred"],
  ["cascade-cc-010", "shade", "S.panel.value = 'control'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.1;", "blurred"],
  ["cascade-n-025", "shade", "S.panel.value = 'notifications'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.25;", "blurred"],
  ["cascade-cc-025", "shade", "S.panel.value = 'control'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.25;", "blurred"],
  ["cascade-n-040", "shade", "S.panel.value = 'notifications'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.4;", "blurred"],
  ["cascade-cc-040", "shade", "S.panel.value = 'control'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.4;", "blurred"],
  ["cascade-n-055", "shade", "S.panel.value = 'notifications'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.55;", "blurred"],
  ["cascade-cc-055", "shade", "S.panel.value = 'control'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.55;", "blurred"],
  ["cascade-n-070", "shade", "S.panel.value = 'notifications'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.7;", "blurred"],
  ["cascade-cc-070", "shade", "S.panel.value = 'control'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.7;", "blurred"],
  ["cascade-n-085", "shade", "S.panel.value = 'notifications'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.85;", "blurred"],
  ["cascade-cc-085", "shade", "S.panel.value = 'control'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.85;", "blurred"],
  ["cascade-n-100", "shade", "S.panel.value = 'notifications'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 1.0;", "blurred"],
  ["cascade-cc-100", "shade", "S.panel.value = 'control'; const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 1.0;", "blurred"],
  // One panel (the default): the control center on top, the notifications under it; "split-*" the setting's old two.
  ["merged-panel-open", "shade", "S.notif.value = true;", "blurred"],
  ["merged-panel-3", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true;", "blurred"],
  ["merged-panel-15", "shade", "const now = Math.floor(Date.now() / 1000); const apps = ['Signal', 'Gmail', 'Calendar', 'Slack', 'Spotify', 'Maps', 'Bank', 'Weather']; E.emit('notifications.changed', { available: true, items: Array.from({ length: 15 }, (_, i) => ({ key: 'm' + i, app: apps[i % apps.length], icon: null, title: 'Notification ' + (i + 1), text: 'Something happened ' + (i * 7 + 2) + ' min ago.', time: now - i * 420 - 60, clearable: true, profile: null, conversation: i === 0 })) }); await sleep(200); S.notif.value = true;", "blurred"],
  ["merged-panel-15-scrolled", "shade", "const now = Math.floor(Date.now() / 1000); const apps = ['Signal', 'Gmail', 'Calendar', 'Slack', 'Spotify', 'Maps', 'Bank', 'Weather']; E.emit('notifications.changed', { available: true, items: Array.from({ length: 15 }, (_, i) => ({ key: 'm' + i, app: apps[i % apps.length], icon: null, title: 'Notification ' + (i + 1), text: 'Something happened ' + (i * 7 + 2) + ' min ago.', time: now - i * 420 - 60, clearable: true, profile: null, conversation: i === 0 })) }); await sleep(200); S.notif.value = true; await sleep(400); document.querySelector('.notif-panel .notif-list').scrollTop = 99999;", "blurred"],
  ["merged-panel-empty", "shade", "E.emit('notifications.changed', { available: true, items: [] }); await sleep(200); S.notif.value = true;", "blurred"],
  ["merged-panel-cascade-010", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.1;", "blurred"],
  ["merged-panel-cascade-025", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.25;", "blurred"],
  ["merged-panel-cascade-040", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.4;", "blurred"],
  ["merged-panel-cascade-055", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.55;", "blurred"],
  ["merged-panel-cascade-070", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.7;", "blurred"],
  ["merged-panel-cascade-085", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 0.85;", "blurred"],
  ["merged-panel-cascade-100", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); const G = await U('./ui/gesture.ts'); G.notifDrag.value = 0.01; await sleep(50); G.notifDrag.value = 1.0;", "blurred"],
  ["split-cc", "shade", "S.separatePanels.value = 'on'; S.panel.value = 'control'; S.notif.value = true;", "blurred"],
  ["split-n", "shade", "S.separatePanels.value = 'on'; S.panel.value = 'notifications'; S.notif.value = true;", "blurred"],
  // The one panel pulled further: every category's members in its tile (ccexpand.ts); 0-4 the finger's travel, then set.
  ["cc-expand-0-pull", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(500); const X = await U('./ui/ccexpand.ts'); X.stretch(0);", "blurred"],
  ["cc-expand-1-pull", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(500); const X = await U('./ui/ccexpand.ts'); X.stretch(20);", "blurred"],
  ["cc-expand-2-pull", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(500); const X = await U('./ui/ccexpand.ts'); X.stretch(45);", "blurred"],
  ["cc-expand-3-pull", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(500); const X = await U('./ui/ccexpand.ts'); X.stretch(70);", "blurred"],
  ["cc-expand-4-pull", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(500); const X = await U('./ui/ccexpand.ts'); X.stretch(110);", "blurred"],
  ["cc-expand-5-flip", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(500); const X = await U('./ui/ccexpand.ts'); X.stretch(70); await sleep(50); X.settle(true); await sleep(90);", "blurred"],
  ["cc-expand-6-open", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(500); const X = await U('./ui/ccexpand.ts'); X.setExpanded(true); await sleep(500);", "blurred"],
  ["cc-expand-7-folding", "shade", "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(500); const X = await U('./ui/ccexpand.ts'); X.setExpanded(true); await sleep(500); X.stretch(-50);", "blurred"],
  // Edit mode (ui/reorder.ts, as home's): lifted, carried over a neighbour, selected with its actions, the whole view.
  ["cc-edit-1-lifted", "shade", "S.notif.value = true; await sleep(600); const X = await U('./ui/ccexpand.ts'); const P = (el, type, x, y) => el.dispatchEvent(new PointerEvent(type, { bubbles: true, clientX: x, clientY: y, pointerId: 7, isPrimary: true, pointerType: 'touch' })); const t = document.querySelector('.cc-main [data-key=\"display\"] .cc-tile'); const r = t.getBoundingClientRect(); const x = r.left + r.width / 2, y = r.top + r.height / 2; P(t, 'pointerdown', x, y); await sleep(500); ", "blurred"],
  ["cc-edit-2-carried", "shade", "S.notif.value = true; await sleep(600); const X = await U('./ui/ccexpand.ts'); const P = (el, type, x, y) => el.dispatchEvent(new PointerEvent(type, { bubbles: true, clientX: x, clientY: y, pointerId: 7, isPrimary: true, pointerType: 'touch' })); const t = document.querySelector('.cc-main [data-key=\"display\"] .cc-tile'); const r = t.getBoundingClientRect(); const x = r.left + r.width / 2, y = r.top + r.height / 2; P(t, 'pointerdown', x, y); await sleep(500); P(t, 'pointermove', x - 60, y + 10); await sleep(60); P(t, 'pointermove', x - r.width - 10, y + 6); await sleep(900);", "blurred"],
  ["cc-edit-3-selected", "shade", "S.notif.value = true; await sleep(600); const X = await U('./ui/ccexpand.ts'); const P = (el, type, x, y) => el.dispatchEvent(new PointerEvent(type, { bubbles: true, clientX: x, clientY: y, pointerId: 7, isPrimary: true, pointerType: 'touch' })); const t = document.querySelector('.cc-main [data-key=\"display\"] .cc-tile'); const r = t.getBoundingClientRect(); const x = r.left + r.width / 2, y = r.top + r.height / 2; P(t, 'pointerdown', x, y); await sleep(500); P(t, 'pointerup', x, y); await sleep(300);", "blurred"],
  ["cc-edit-4-whole", "shade", "S.notif.value = true; await sleep(600); const X = await U('./ui/ccexpand.ts'); X.setExpanded(true); await sleep(400); X.ccEditing.value = true; await sleep(300);", "blurred"],
  ["pull-cc-start", "shade", "S.panel.value = 'control'; (await U('./ui/gesture.ts')).notifDrag.value = 0.25;", "blurred"],
  ["pull-cc-half", "shade", "S.panel.value = 'control'; (await U('./ui/gesture.ts')).notifDrag.value = 0.5;", "blurred"],
  ["pull-cc-open", "shade", "S.panel.value = 'control'; S.notif.value = true;", "blurred"],
  ["control-open", "shade", "S.panel.value = 'control'; S.notif.value = true; await sleep(300); document.querySelectorAll('.cc-main .cc-more')[1]?.click(); await sleep(400);", "blurred"],
  ["control-open-display", "shade", "S.panel.value = 'control'; S.notif.value = true; await sleep(300); [...document.querySelectorAll('.cc-main .cc-tile')].find((t) => t.textContent.includes('display'))?.querySelector('.cc-more')?.click(); await sleep(400);", "blurred"],
  ["control-tools-scrolled", "shade", "S.panel.value = 'control'; S.notif.value = true; await sleep(300); [...document.querySelectorAll('.cc-main .cc-tile')].find((t) => t.textContent.includes('tools'))?.querySelector('.cc-more')?.click(); await sleep(400); const r = document.querySelector('.cc-unfold.open .cc-subs'); if (r) r.scrollLeft = r.firstElementChild.offsetWidth + 6; await sleep(300);", "blurred"],
  ["cc-drag-pickup", "shade", "S.panel.value = 'control'; S.notif.value = true; await sleep(300); const t = [...document.querySelectorAll('.cc-main > .cc-grid .cc-tile')].find((x) => x.textContent.includes('focus')); const r = t.getBoundingClientRect(); const box = document.querySelector('.cc-main'); const ev = (type, x, y) => box.dispatchEvent(new PointerEvent(type, { bubbles: true, clientX: x, clientY: y, pointerId: 1, pointerType: 'touch' })); t.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, clientX: r.left + 30, clientY: r.top + 30, pointerId: 1, pointerType: 'touch' })); await sleep(600);", "blurred"],
  ["cc-drag-mid", "shade", "S.panel.value = 'control'; S.notif.value = true; await sleep(300); const t = [...document.querySelectorAll('.cc-main > .cc-grid .cc-tile')].find((x) => x.textContent.includes('focus')); const r = t.getBoundingClientRect(); const box = document.querySelector('.cc-main'); const ev = (type, x, y) => box.dispatchEvent(new PointerEvent(type, { bubbles: true, clientX: x, clientY: y, pointerId: 1, pointerType: 'touch' })); t.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, clientX: r.left + 30, clientY: r.top + 30, pointerId: 1, pointerType: 'touch' })); await sleep(600); const tgt = [...document.querySelectorAll('.cc-main > .cc-grid .cc-tile')].find((x) => x.textContent.includes('connect')).getBoundingClientRect(); for (let i = 1; i <= 8; i++) { ev('pointermove', r.left + 30 + (tgt.left - r.left) * i / 8, r.top + 30 + (tgt.top - r.top) * i / 8); await sleep(30); } await sleep(250);", "blurred"],
  ["cc-drag-sub", "shade", "S.panel.value = 'control'; S.notif.value = true; await sleep(300); [...document.querySelectorAll('.cc-main .cc-tile')].find((t) => t.textContent.includes('tools'))?.querySelector('.cc-more')?.click(); await sleep(400); const row = document.querySelector('.cc-unfold.open .cc-subs'); const items = row.querySelectorAll('.cc-sub'); const a = items[2].getBoundingClientRect(); const b = items[0].getBoundingClientRect(); items[2].dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, clientX: a.left + 20, clientY: a.top + 20, pointerId: 2, pointerType: 'touch' })); await sleep(600); for (let i = 1; i <= 8; i++) { row.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: a.left + 20 + (b.left - a.left) * i / 8, clientY: a.top + 20, pointerId: 2, pointerType: 'touch' })); await sleep(30); } await sleep(250);", "blurred"],
  ["control-open-row2", "shade", "S.panel.value = 'control'; S.notif.value = true; await sleep(300); [...document.querySelectorAll('.cc-main .cc-tile')].find((t) => t.textContent.includes('tools'))?.querySelector('.cc-more')?.click(); await sleep(400);", "blurred"],
  ["control", "shade", "S.panel.value = 'control'; S.notif.value = true;", "blurred"],
  ["switcher", "recents", "E.emit('recents.show', { open: true, from: 100, tasks: await (await U('./bridge.ts')).powos.tasks.list() });", "blurred"],
  ["lock", "lock", "", "wallpaper"],
  ["quicktools", "quicktools", "E.emit('qt.drag', { side: 'right', y: innerHeight * 0.7, q: 1 }); E.emit('qt.settle', { open: true }); await sleep(400);", "blurred"],
  ["gestures", "home", "(await U('./screens.ts')).openScreen('gestures'); await sleep(300); document.querySelector('.scr-edge-gesture .scr-row')?.click();", "wallpaper"],
].filter(([n]) => !ONLY || ONLY.test(n));

function file(url) {
  const u = new URL(url);
  const p = decodeURIComponent(u.pathname).replace(/^\/+/, "") || "index.html";
  if (p.split("/").includes("..")) return null;
  if (p === "__wallpaper.jpg" && WALLPAPER) return { path: WALLPAPER, name: p };
  if (p === "dev/sample-trees.json") return { path: TREES, name: p };
  // The symbols font (gate.sh mounts the real file): theme.css's ./fonts/ and the host's /_font/symbols.
  if ((p === "fonts/nerd_symbols.ttf" || p === "_font/symbols") && fs.existsSync("/fonts/nerd_symbols.ttf"))
    return { path: "/fonts/nerd_symbols.ttf", name: "nerd_symbols.ttf" };
  const f = path.join(ROOT, p);
  return fs.existsSync(f) && fs.statSync(f).isFile() ? { path: f, name: p } : null;
}

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || "/usr/bin/chromium-browser",
  headless: true,
  args: ["--no-sandbox", "--disable-dev-shm-usage", "--no-first-run", "--mute-audio", "--font-render-hinting=none"],
});
const report = [];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Text runs on the page: their boxes, colour, effective opacity and size. */
const collectText = () => {
  const out = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const range = document.createRange();
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const t = n.textContent.trim();
    if (!t) continue;
    const el = n.parentElement;
    if (!el || !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
    if (el.closest("svg, .xterm, canvas, [aria-hidden=true]")) continue;
    range.selectNodeContents(n);
    const r = range.getBoundingClientRect();
    if (r.width < 2 || r.height < 4 || r.right < 0 || r.bottom < 0 || r.left > innerWidth || r.top > innerHeight) continue;
    // Clipped away (scrolled out of its list): its middle outside a clipping ancestor's box - not seen, not measured.
    const cx = r.left + r.width / 2;
    const cy = r.top + r.height / 2;
    let clipped = false;
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      const ps = getComputedStyle(p);
      if (ps.overflowX === "visible" && ps.overflowY === "visible") continue;
      const b = p.getBoundingClientRect();
      if (cx < b.left || cx > b.right || cy < b.top || cy > b.bottom) {
        clipped = true;
        break;
      }
    }
    if (clipped) continue;
    const cs = getComputedStyle(el);
    let o = 1;
    for (let a = el; a; a = a.parentElement) o *= parseFloat(getComputedStyle(a).opacity);
    if (o < 0.05) continue;
    out.push({
      text: t.slice(0, 40),
      cls: `${el.tagName.toLowerCase()}.${[...el.classList].join(".")}`,
      color: cs.color,
      opacity: o,
      size: parseFloat(cs.fontSize),
      bold: parseInt(cs.fontWeight) >= 700,
      x: Math.max(0, r.left), y: Math.max(0, r.top), w: Math.min(innerWidth, r.right) - Math.max(0, r.left), h: Math.min(innerHeight, r.bottom) - Math.max(0, r.top),
    });
  }
  // Placeholders: their own colour (::placeholder) on the field.
  for (const f of document.querySelectorAll("input, textarea")) {
    if (f.value || !f.placeholder || !f.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
    const r = f.getBoundingClientRect();
    if (r.right < 0 || r.left > innerWidth || r.bottom < 0 || r.top > innerHeight) continue;
    const cs = getComputedStyle(f, "::placeholder");
    out.push({ text: `[${f.placeholder.slice(0, 30)}]`, cls: `${f.tagName.toLowerCase()}::placeholder`, color: cs.color, opacity: 1, size: parseFloat(cs.fontSize), bold: false,
      x: r.left + 4, y: r.top + r.height * 0.25, w: Math.min(r.width - 8, f.placeholder.length * parseFloat(cs.fontSize) * 0.6), h: r.height * 0.5 });
  }
  return out;
};

/** In a blank page: each run's background (the average of the text-less shot under its box) and its contrast. */
const contrastOf = async (png, runs) => {
  const img = new Image();
  img.src = "data:image/png;base64," + png;
  await img.decode();
  const c = document.createElement("canvas");
  c.width = img.width;
  c.height = img.height;
  const g = c.getContext("2d", { willReadFrequently: true });
  g.drawImage(img, 0, 0);
  const k = img.width / innerWidth;
  // Computed colours: rgb()/rgba(), or color(srgb r g b / a) (0-1) from a color-mix.
  const parse = (s) => {
    const m = (s.match(/[\d.]+/g) ?? ["0", "0", "0"]).map(Number);
    if (s.startsWith("color(")) return { r: m[0] * 255, g: m[1] * 255, b: m[2] * 255, a: m[3] ?? 1 };
    return { r: m[0], g: m[1], b: m[2], a: m[3] ?? 1 };
  };
  const lum = ({ r, g: gg, b }) => {
    const f = (v) => ((v /= 255) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
    return 0.2126 * f(r) + 0.7152 * f(gg) + 0.0722 * f(b);
  };
  return runs.map((t) => {
    const d = g.getImageData(Math.round(t.x * k), Math.round(t.y * k), Math.max(1, Math.round(t.w * k)), Math.max(1, Math.round(t.h * k))).data;
    let r = 0, gg = 0, b = 0, n = 0;
    for (let i = 0; i < d.length; i += 4) (r += d[i]), (gg += d[i + 1]), (b += d[i + 2]), n++;
    const bg = { r: r / n, g: gg / n, b: b / n };
    const fgc = parse(t.color);
    const a = fgc.a * t.opacity;
    const fg = { r: fgc.r * a + bg.r * (1 - a), g: fgc.g * a + bg.g * (1 - a), b: fgc.b * a + bg.b * (1 - a) };
    const [l1, l2] = [lum(fg), lum(bg)].sort((x, y) => y - x);
    return { ...t, ratio: +((l1 + 0.05) / (l2 + 0.05)).toFixed(2), bg: `rgb(${bg.r | 0} ${bg.g | 0} ${bg.b | 0})` };
  });
};


try {
  for (const [name, mode, setup, behind, touch] of SCENES) {
    for (const [sizeName, size] of Object.entries(mode === "desktop" ? DESKTOP_SIZES : SIZES)) {
      let timer;
      const limit = new Promise((_, no) => (timer = setTimeout(() => no(new Error("timed out (40 s)")), 40000)));
      await Promise.race([shoot(name, mode, setup, behind, sizeName, size, touch), limit])
        .catch((e) => { console.log(`shot ${name}-${sizeName}: FAILED ${e.message}`); report.push({ shot: `${name}-${sizeName}`, errors: [e.message] }); })
        .finally(() => clearTimeout(timer));
    }
  }
} finally {
  fs.writeFileSync(path.join(OUT, "report.json"), JSON.stringify(report, null, 1));
  await browser.close();
  if (treesWrong) console.error(`shots: ${treesWrong} shot(s) drew mock OWL trees of another theme than ${THEME_NAME}`);
  const strict = strictFailed && process.env.SHOTS_STRICT === "1";
  if (strict) console.error("shots: FAIL - overlapping tiles, uneven desktop gutters or missing glyphs (report.json)");
  process.exit(treesWrong || strict ? 1 : 0);
}

async function shoot(name, mode, setup, behind, sizeName, size, touch) {
  {
    {
      const t0 = Date.now();
      const step = (what) => process.env.SHOTS_DEBUG && console.log(`  ${name}-${sizeName} ${what} +${Date.now() - t0} ms`);
      const page = await browser.newPage();
      await page.setViewport({ width: size.width, height: size.height, deviceScaleFactor: SCALE, hasTouch: true, isMobile: true });
      const errors = [];
      page.on("pageerror", (e) => errors.push(e.message.split("\n")[0]));
      page.on("console", (m) => m.type() === "error" && errors.push(m.text().split("\n")[0]));
      await page.setRequestInterception(true);
      page.on("request", (req) => {
        const url = req.url();
        if (!url.startsWith(ORIGIN + "/")) return url.startsWith("data:") || url.startsWith("blob:") ? req.continue() : req.abort();
        const f = file(url);
        if (!f) return req.respond({ status: 404, contentType: "text/plain", body: "" });
        req.respond({ status: 200, contentType: mime(f.name), body: fs.readFileSync(f.path), headers: { "Cache-Control": "no-store" } });
      });
      await page.goto(`${ORIGIN}/index.html${mode === "home" ? "" : `?mode=${mode}`}`, { waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => window.__powosAlive === true, { timeout: 10000, polling: 50 }).catch(() => errors.push("not ready"));
      // The trees this page draws are the rendered theme's (see TREES), or the shot says so and the run fails.
      const treeTheme = await page.evaluate(() => fetch("./dev/sample-trees.json").then((r) => r.json()).then((j) => j._theme ?? null, () => null));
      if (treeTheme !== THEME_NAME) {
        errors.push(`mock OWL trees evaluated in ${treeTheme}, rendered in ${THEME_NAME}`);
        treesWrong++;
      }
      const wp = WALLPAPER ? `${ORIGIN}/__wallpaper.jpg` : FALLBACK_WP;
      await page
        .evaluate(
          async ({ theme, insets, wp, behind, setup, glassMode }) => {
            const root = document.documentElement;
            const css = { background: theme.bg, surface: theme.surface, overlay: `color-mix(in srgb, ${theme.bg} 90%, transparent)`, foreground: theme.fg,
              muted: theme.muted, accent: theme.accent, border: theme.border, red: theme.red, green: theme.green };
            // As the host would: through app.tsx's applyTheme (what it derives from the theme included).
            if (window.__mockEvents) window.__mockEvents.emit("theme.changed", { name: "shots", light: theme.light, css, colors: { background: theme.bg, foreground: theme.fg } });
            else for (const [k, v] of Object.entries(css)) root.style.setProperty(`--color-${k}`, v), (root.dataset.light = String(theme.light));
            await new Promise((r) => setTimeout(r, 300)); // the theme crossfade (html.theme-fade, 260 ms)
            root.style.setProperty("--inset-top", `${insets.top}px`);
            root.style.setProperty("--inset-bottom", `${insets.bottom}px`);
            // What the window is over, drawn behind the page (the WebView's own background is the wallpaper/app).
            // A stand-in app screen (the assistant's window is over one): a header, rows - drawn 1:1 behind the page.
            window.__shotsApp = "data:image/svg+xml," + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="${innerWidth}" height="${innerHeight}"><rect width="100%" height="100%" fill="#f6f6f6"/><rect width="100%" height="110" fill="#3b6fb6"/><text x="20" y="80" font-family="sans-serif" font-size="28" fill="#fff">Inbox</text>${Array.from({ length: 9 }, (_, i) => `<rect x="20" y="${140 + i * 80}" width="${innerWidth - 40}" height="60" rx="8" fill="#e2e2e2"/><text x="36" y="${178 + i * 80}" font-family="sans-serif" font-size="18" fill="#333">Message ${i + 1}</text>`).join("")}</svg>`);
            const back = document.createElement("style");
            const pic = `url("${wp}") center / cover no-repeat fixed`;
            // SHOTS_GLASS=native (default, the live path): the compositor's regions emulated - the wallpaper behind the
            // window, a backdrop blur on each top-level glass surface; =page: the page draws the wallpaper (glass.ts).
            back.textContent =
              behind === "wallpaper"
                ? glassMode === "page"
                  ? ""
                  : `html { background: ${pic}; } .glass-native :is(.tile, .notif-panel):not(:is(.tile, .notif-panel) *) { backdrop-filter: blur(30px); }`
                : behind === "blurred"
                  ? `html::before { content: ""; position: fixed; inset: -40px; z-index: -1; background: ${pic}; filter: blur(30px) brightness(.8); }`
                  : `html { background: url("${window.__shotsApp}") 0 0 / 100% 100% no-repeat; }`;
            document.head.append(back);
            if (glassMode === "page" || !["home", "desktop"].includes(root.dataset.mode)) window.__glass?.use(wp);
            else {
              root.classList.add("glass-native");
              // The wallpaper's tone, as glass.ts reads it from the host's picture.
              await window.__glass?.tone?.(wp);
            }
            await new Promise((r) => setTimeout(r, 200)); // the wallpaper decoded
            const S = await importShim("./state.ts");
            const U = (p) => importShim(p);
            const E = window.__mockEvents;
            const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
            await new (Object.getPrototypeOf(async function () {}).constructor)("S", "U", "E", "sleep", setup)(S, U, E, sleep);
          },
          { theme: THEME, insets: size.insets, wp, behind, setup, glassMode: process.env.SHOTS_GLASS || "native" },
        )
        .catch((e) => errors.push(`setup: ${e.message.split("\n")[0]}`));
      step("setup");
      await sleep(600);
      // A finger's swipe (fractions of the screen), as the phone's touch events: the gestures' own path.
      if (touch) {
        const [x0, y0] = [touch.from[0] * size.width, touch.from[1] * size.height];
        const [x1, y1] = [touch.to[0] * size.width, touch.to[1] * size.height];
        const n = Math.max(4, Math.round(touch.ms / 16));
        await page.touchscreen.touchStart(x0, y0);
        for (let i = 1; i <= n; i++) {
          await page.touchscreen.touchMove(x0 + ((x1 - x0) * i) / n, y0 + ((y1 - y0) * i) / n);
          await sleep(touch.ms / n);
        }
        await page.touchscreen.touchEnd();
      }
      await sleep(900);
      // SHOTS_PROBE: an expression evaluated in the page once it settled, its value printed (debugging a render).
      if (process.env.SHOTS_PROBE)
        console.log(`probe ${name}-${sizeName}:`, JSON.stringify(await page.evaluate(process.env.SHOTS_PROBE).catch((e) => e.message)));
      // Layout checks: tiles that overlap (more than touching - merged tiles touch) and glyphs that can't render
      // (a font that failed or 404'd draws tofu). SHOTS_STRICT=1 fails the run on either.
      const layout = await page
        .evaluate(() => {
          const vw = innerWidth;
          const vh = innerHeight;
          const tiles = [...document.querySelectorAll(".home-tile")]
            .map((t) => ({ name: (t.querySelector("[data-key], .owl, .island-face, .ag-panel") ?? t).className.toString().slice(0, 24) || t.className.slice(0, 24), r: t.getBoundingClientRect() }))
            .filter(({ r }) => r.width > 0 && r.right > 0 && r.left < vw && r.bottom > 0 && r.top < vh);
          const overlaps = [];
          for (let i = 0; i < tiles.length; i++)
            for (let j = i + 1; j < tiles.length; j++) {
              const a = tiles[i].r;
              const b = tiles[j].r;
              const w = Math.min(a.right, b.right) - Math.max(a.left, b.left);
              const h = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
              if (w > 1 && h > 1) overlaps.push(`${tiles[i].name} x ${tiles[j].name} (${Math.round(w)}x${Math.round(h)} px)`);
            }
          // The desktop's grid: one even gutter between neighbouring tiles in a row (its tiles never merge or touch).
          const gutters = [];
          if (document.documentElement.dataset.mode === "desktop") {
            const rows = new Map();
            for (const t of tiles) {
              const k = [...rows.keys()].find((y) => Math.abs(y - t.r.top) <= 2) ?? t.r.top;
              rows.set(k, [...(rows.get(k) ?? []), t.r]);
            }
            const gaps = [];
            for (const row of rows.values()) {
              row.sort((a, b) => a.left - b.left);
              for (let i = 1; i < row.length; i++) gaps.push(Math.round(row[i].left - row[i - 1].right));
            }
            if (gaps.length && Math.max(...gaps) - Math.min(...gaps) > 2) gutters.push(`uneven gutters: ${gaps.join(", ")} px`);
          }
          const fonts = [...document.fonts].filter((f) => f.status === "error").map((f) => f.family);
          const missing = performance
            .getEntriesByType("resource")
            .filter((e) => e.responseStatus >= 400 && /font|\.ttf|\.woff/.test(e.name))
            .map((e) => e.name.replace(location.origin, ""));
          return { overlaps: [...overlaps, ...gutters], glyphs: [...new Set([...fonts, ...missing])] };
        })
        .catch(() => ({ overlaps: [], glyphs: [] }));
      for (const o of layout.overlaps) errors.push(`overlap: ${o}`);
      for (const g of layout.glyphs) errors.push(`missing glyphs: ${g}`);
      if (layout.overlaps.length || layout.glyphs.length) strictFailed = true;
      const out = path.join(OUT, `${name}-${sizeName}.png`);
      await page.screenshot({ path: out });
      // Contrast: the same frame without its text, under each run of text.
      step("shot");
      const runs = await page.evaluate(collectText).catch(() => []);
      step("texts");
      await page.addStyleTag({ content: "*, *::placeholder { color: transparent !important; -webkit-text-fill-color: transparent !important; caret-color: transparent !important; }" });
      await sleep(80);
      const bare = await page.screenshot({ encoding: "base64" });
      step("bare");
      const measured = await page.evaluate(contrastOf, bare, runs).catch((e) => (errors.push(`contrast: ${e.message}`), []));
      const low = measured.filter((t) => t.ratio < (t.size >= 24 || (t.size >= 18.66 && t.bold) ? 3 : 4.5));
      report.push({ shot: `${name}-${sizeName}`, errors: [...new Set(errors)].slice(0, 8), lowContrast: low, texts: measured.length });
      console.log(`shot ${name}-${sizeName}: ${measured.length} texts, ${low.length} below contrast${errors.length ? `, ${errors.length} errors` : ""}`);
      await page.close();
    }
  }
}

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
/** The phone's screens plus a wide desktop window: for pages whose layout follows their width (the AI page). */
const WIDE_SIZES = { ...SIZES, window: { width: 1600, height: 1000, insets: { top: 0, bottom: 0 } } };

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
/** Agents' mail in a conversation (PowosAiChat's "mail from <agent>: ..." notes): the mail cards' scenes. */
const MAIL_SAMPLE = JSON.stringify([{ kind: "user", text: "status?" }, { kind: "note", error: false, text: "mail from coder: coder: ack - phone slow (611b9f8a): the perf expert (ae943ed) has the app spin (my sample just now: app 65 / renderer 42 / SF 34 percent of a core, screen awake); the desktop expert (a365c81) makes powos-shell dormant when the desktop is not shown. Before/after to follow." }, { kind: "note", error: false, text: "mail from coder: coder: speed rules applied (handbook updated); experts unqueued. SHIPPED: - perf (ae943ed): app CPU spin fixed - design (ab9f89b): CC v3 with the 2 tweaks, review /home/powos/design-qa/queued-folded.png IN PROGRESS: - desktop (a365c81): powos-shell dormant when hidden BLOCKED: - kernel test: needs the phone on the Mac's USB" }, { kind: "assistant", text: "Two updates from coder: the CPU spin is fixed, the desktop work goes on." }]);
const board = (actions) =>
  `const B = ${BOARD}; const A = ${actions ? ACTIONS : "{}"}; const now = Date.now(); const P = await U('./ui/powai.tsx');` +
  ` P.board.value = B.map((r) => ({ ...r, note: A[r.id] ?? r.note, created: now - r.createdAgo, updated: now - r.updatedAgo, done: r.doneAgo ? now - r.doneAgo : 0, activity: r.activityAgo ? now - r.activityAgo : 0 }));` +
  ` P.boardSeen.value = true; S.chat.value = { busy: false, items: [{ kind: "user", text: "what changed overnight?" }, { kind: "assistant", text: "Three pushes: the shade, the pet, the speech fix." }, ...${CHAT_SAMPLE}] }; S.page.value = -1; await sleep(300);`;

/** Rows with queued phone checks (queue.sh's marker), a failed check (its screenshot) and a passed one: "test now". */
const TEST_NOW =
  " const R = P.board.value; const w = R.filter((r) => r.status === 'working'); w[0].step = 'phone check queued'; w[1].step = 'phone check queued';" +
  " w[2].step = 'verify FAIL rc=1: FAIL: not freeform (log ~/.cache/powos-verify-queue/done/x.log)'; w[2].images = JSON.stringify(['/home/powos/design-qa/verify-x.png']);" +
  " w[3].step = 'verify PASS: 3 swipes ok (log ~/.cache/powos-verify-queue/done/y.log)'; P.board.value = [...R]; await sleep(200); document.querySelector('.ai-work-list').scrollIntoView();";
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
  ["chrome-status", "statusbar", "E.emit('chrome.changed', {kind:'status', battery:74, charging:true, network:'wifi', vpn:true, left:44});", "blurred", null, { folded: {width:404,height:46,insets:{top:0,bottom:0}}, unfolded: {width:821,height:46,insets:{top:0,bottom:0}} }],
  ["chrome-window", "windowbar", "E.emit('chrome.changed', {kind:'window', title:'Calculator'});", "blurred", null, { narrow: {width:280,height:27,insets:{top:0,bottom:0}}, wide: {width:650,height:27,insets:{top:0,bottom:0}} }],
  ["chrome-restore", "windowbar", "E.emit('chrome.changed', {kind:'window', title:'A long document title that must leave all three window controls visible', maximised:true});", "blurred", null, { narrow: {width:280,height:27,insets:{top:0,bottom:0}} }],
  ["chrome-grip", "windowgrip", "", "blurred", null, { grip: {width:28,height:28,insets:{top:0,bottom:0}} }],
  ["home", "home", "", "wallpaper"],
  ["home-p2", "home", "S.page.value = 1;", "wallpaper"],
  ["edit", "home", "S.editing.value = true;", "wallpaper"],
  ["edit-theme", "home", "S.editing.value = true; await sleep(200); [...document.querySelectorAll('.edit-act')].find(b => b.textContent.trim() === 'theme')?.click();", "wallpaper"],
  // Picking tiles in edit mode (ui/homeselect.ts) and a folder made of them, open (ui/folders.tsx).
  ["edit-add-app", "home", "S.editing.value = true; await sleep(300); [...document.querySelectorAll('.edit-act')].find((b) => b.textContent.trim() === '+ app').click(); await sleep(400);", "wallpaper"],
  ["edit-chosen", "home", "S.editing.value = true; const H = await U('./ui/homeselect.ts'); H.chosen.value = S.home.value.items.filter((i) => i.kind === 'app').slice(0, 2).map((i) => i.key); await sleep(200);", "wallpaper"],
  ["folder-open", "home", "S.editing.value = true; const H = await U('./ui/homeselect.ts'); H.chosen.value = S.home.value.items.filter((i) => i.kind === 'app').slice(0, 3).map((i) => i.key); await sleep(200); document.querySelector('.chosen-actions .group-folder')?.click(); await sleep(600); S.editing.value = false; await sleep(200);", "wallpaper"],
  // A PowOS app's page (ui/appscreen.tsx) over home: its ground is the frost.
  ["app-page", "home", "(await U('./apps/pages.ts')).openApp('local.lights'); await sleep(500);", "wallpaper"],
  // The app library, home's last page (ui/library.tsx), and a search in it.
  ["library", "home", "S.page.value = S.pages.value.length; await sleep(400);", "wallpaper"],
  ["library-open", "home", "S.page.value = S.pages.value.length; await sleep(400); document.querySelectorAll('.page.library .lib-card')[2]?.click(); await sleep(500);", "wallpaper"],
  ["library-opening", "home", "S.page.value = S.pages.value.length; await sleep(400); document.querySelectorAll('.page.library .lib-card')[2]?.click(); await sleep(90);", "wallpaper"],
  ["edit-picker", "home", "S.editing.value = true; await sleep(150); (await U('./ui/appwidget.tsx')).picker.value = true;", "wallpaper"],
  ["drawer", "home", "S.drawer.value = 1;", "wallpaper"],
  // The running bar under icons (ui/running.ts; the mock: Chrome, Konsole, Spotify, Signal running, Dolphin and Steam
  // frozen): the pinned dock, and the drawer with its recent row.
  ["running-dock", "home", "S.dock.value = ['a:chrome', 'l:steam', 'a:maps', 'l:konsole', 'l:dolphin']; await sleep(200); document.querySelector('.dock-pages').scrollLeft = 0; await sleep(300);", "wallpaper"],
  // Uniform icons (ui/iconshape.ts): Linux-like pictures swapped in - a wide monitor (Konsole), a folder (Dolphin), a
  // tiny glyph with wide padding (Foot, as Terminal), a full-bleed square (Kate), a circle (Steam) - in the drawer and dock.
  ["icons-mixed", "home", `const B = (await U('./bridge.ts')).powos; const list = B.apps.list.bind(B.apps); const svg = (b) => 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="192" height="192">' + b + '</svg>'); const I = { Konsole: svg('<rect x="40" y="58" width="112" height="76" rx="6" fill="#31363b"/><rect x="40" y="58" width="112" height="14" rx="4" fill="#7f8c8d"/><text x="54" y="118" font-size="32" fill="#eff0f1" font-family="monospace">&gt;_</text>'), Dolphin: svg('<path d="M28 58h48l12 12h76v66H28z" fill="#1d99f3"/><path d="M28 78h136v58H28z" fill="#3daee9"/>'), Terminal: svg('<rect x="80" y="80" width="32" height="32" rx="4" fill="#da4453"/><path d="M86 90l8 6-8 6" stroke="#fff" stroke-width="3" fill="none"/>'), Kate: svg('<rect width="192" height="192" fill="#f67400"/><path d="M60 50v92M60 96l50-46M60 96l50 46" stroke="#fff" stroke-width="14" fill="none"/>'), Steam: svg('<circle cx="96" cy="96" r="84" fill="#1b2838"/><circle cx="120" cy="80" r="22" fill="none" stroke="#c7d5e0" stroke-width="8"/>') }; B.apps.list = async () => (await list()).map((a) => (I[a.label] ? { ...a, icon: I[a.label] } : a)); E.emit('apps.changed'); await sleep(600); S.dock.value = ['l:konsole', 'l:dolphin', 'a:chrome', 'l:steam', 'a:maps']; await sleep(1500); S.drawer.value = 1; await sleep(300);`, "wallpaper"],
  ["icons-mixed-dock", "home", `const B = (await U('./bridge.ts')).powos; const list = B.apps.list.bind(B.apps); const svg = (b) => 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="192" height="192">' + b + '</svg>'); const I = { Konsole: svg('<rect x="40" y="58" width="112" height="76" rx="6" fill="#31363b"/><rect x="40" y="58" width="112" height="14" rx="4" fill="#7f8c8d"/><text x="54" y="118" font-size="32" fill="#eff0f1" font-family="monospace">&gt;_</text>'), Dolphin: svg('<path d="M28 58h48l12 12h76v66H28z" fill="#1d99f3"/><path d="M28 78h136v58H28z" fill="#3daee9"/>'), Terminal: svg('<rect x="80" y="80" width="32" height="32" rx="4" fill="#da4453"/><path d="M86 90l8 6-8 6" stroke="#fff" stroke-width="3" fill="none"/>'), Kate: svg('<rect width="192" height="192" fill="#f67400"/><path d="M60 50v92M60 96l50-46M60 96l50 46" stroke="#fff" stroke-width="14" fill="none"/>'), Steam: svg('<circle cx="96" cy="96" r="84" fill="#1b2838"/><circle cx="120" cy="80" r="22" fill="none" stroke="#c7d5e0" stroke-width="8"/>') }; B.apps.list = async () => (await list()).map((a) => (I[a.label] ? { ...a, icon: I[a.label] } : a)); E.emit('apps.changed'); await sleep(600); S.dock.value = ['l:konsole', 'l:dolphin', 'a:chrome', 'l:steam', 'a:maps']; await sleep(1500);`, "wallpaper"],
  // The unfolded home's dock as a taskbar: pinned apps (one with a window in front, one running), an unpinned app's
  // minimised window and a Linux app's window after them.
  ["taskbar", "home", "S.dock.value = ['a:chrome', 'a:maps', 'l:konsole']; S.windows.value = [{ id: 1, pkg: 'chrome', label: 'Chrome', minimised: false, app: 'a:chrome' }, { id: 2, pkg: 'spotify', label: 'Spotify', minimised: true, app: 'a:spotify' }, { id: 3, pkg: 'powos', label: 'Dolphin', minimised: false, app: 'l:dolphin' }]; await sleep(500);", "wallpaper"],
  ["running-drawer", "home", "(await U('./ui/drawer.tsx')).drawerRecents.value = 'on'; S.drawer.value = 1; await sleep(200);", "wallpaper"],
  // A finger held on the A-Z bar at M (drawer.tsx highlight): M's apps bright and lifted, the rest dim, M enlarged.
  ["drawer-scrub", "home", `S.drawer.value = 1; await sleep(300); const m = [...document.querySelectorAll('.letter-bar span')].find((s) => s.textContent === 'M'); const r = m.getBoundingClientRect(); Element.prototype.setPointerCapture = () => {}; m.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, pointerId: 1, buttons: 1, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2 })); await sleep(400);`, "wallpaper"],
  ["swipe-up-right", "home", "", "wallpaper", { from: [0.73, 0.72], to: [0.73, 0.28], ms: 220 }],
  ["swipe-up-left", "home", "", "wallpaper", { from: [0.25, 0.72], to: [0.25, 0.28], ms: 220 }],
  ["search-widget", "home", "await (await U('./bridge.ts')).powos.home.addPanel('search', 0, { x: 0, y: 4, w: 6, h: 1 }); await sleep(300);", "wallpaper"],
  // The user's unfolded home as a mock (2026-10-22, never their real layout): a 3x3 beside a 3x2 over a 3x1 (one
  // rectangle), and a 6x3 over a half-width 3x3 on the right page (the L), a row of apps under the first.
  ["home-merged", "home", "{ const B = (await U('./bridge.ts')).powos; const h = await B.home.get(); const wide = innerWidth >= 700; const pg = h.pages[0] ?? 1; const R = wide ? 7 : 0; const P = wide ? pg : (h.pages[1] ?? pg + 1); await B.home.remove('terminal.owl'); let k = 0; for (const i of h.items.filter((i) => i.kind === 'app' && i.page === pg)) await B.home.place(i.key, { x: k++, y: 3, w: 1, h: 1 }, pg); for (const [key, c, p] of [['clock.owl', { x: 0, y: 0, w: 3, h: 3 }, pg], ['weather.owl', { x: 3, y: 0, w: 3, h: 2 }, pg], ['monitor.owl', { x: R, y: 0, w: 6, h: 3 }, P], ['glance.owl', { x: R + 3, y: 3, w: 3, h: 3 }, P]]) await B.home.place(key, c, p); await B.home.addPanel('app:local.lights/main', pg, { x: 3, y: 2, w: 3, h: 1 }); await sleep(600); }", "wallpaper"],
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
  ["progress", "home", board(false) + " document.querySelector('.ai-work-list').scrollIntoView();", "wallpaper"],
  ["progress-open", "home", board(false) + " [...document.querySelectorAll('.ai-item-row')].find((b) => /queued/i.test(b.textContent))?.click(); await sleep(300); document.querySelector('.ai-item-more')?.scrollIntoView({ block: 'center' }); await sleep(300);", "wallpaper"],
  ["test-now", "home", board(false) + TEST_NOW, "wallpaper"],
  ["test-now-testing", "home", board(false) + TEST_NOW + " document.querySelector('.ai-test')?.click(); await sleep(200);", "wallpaper"],
  ["ai-wide", "home", board(true), "wallpaper", undefined, WIDE_SIZES],
  // The same AiView in home's AI panel and the pull-up over apps: one column folded, two panes wide.
  ["ai-panel-wide", "home", board(true).replace(" S.page.value = -1;", "") + " S.openPanel('ai'); await sleep(500);", "wallpaper", undefined, WIDE_SIZES],
  ["pull-ai-wide", "pull", board(true).replace(" S.page.value = -1;", "") + " E.emit('pull.begin', { kind: 'ai' }); E.emit('pull.end', { open: true }); await sleep(500);", "blurred", undefined, WIDE_SIZES],
  ["ai-v2-calm", "home", board(true).replace("P.board.value = B.map", "P.board.value = B.filter((r) => r.status !== 'waiting').map"), "wallpaper"],
  ["queued", "home", `S.chat.value = { busy: true, items: ${CHAT_SAMPLE}.slice(0, 3), queued: [{ id: 1, text: "also check the battery health" }, { id: 2, text: "and remind me at 6 to charge it" }] }; S.chatting.value = true; S.drawer.value = 1;`, "wallpaper"],
  ["queued-ai", "home", `S.chat.value = { busy: true, items: ${CHAT_SAMPLE}.slice(0, 3), queued: [{ id: 1, text: "also check the battery health" }, { id: 2, text: "and remind me at 6 to charge it" }] }; S.page.value = -1;`, "wallpaper"],
  ["kbd-chat", "home", `E.emit('system.insets', { top: 45, bottom: 16, left: 0, right: 0, keyboard: 330 }); S.chat.value = { busy: false, items: ${CHAT_SAMPLE} }; S.chatting.value = true; S.drawer.value = 1;`, "wallpaper"],
  ["kbd-ai", "home", `E.emit('system.insets', { top: 45, bottom: 16, left: 0, right: 0, keyboard: 330 }); S.page.value = -1;`, "wallpaper"],
  ["kbd-assist", "assist", "E.emit('system.insets', { top: 45, bottom: 16, left: 0, right: 0, keyboard: 0 }); await sleep(200); E.emit('assist.context', { text: 'Inbox - 3 unread', screenshot: window.__shotsApp });", "app"],
  ["mail", "home", `S.chat.value = { busy: false, items: ${MAIL_SAMPLE} }; S.chatting.value = true; S.drawer.value = 1; await sleep(200); document.querySelectorAll('.chat .mail-head')[1]?.click();`, "wallpaper"],
  ["mail-ai", "home", `S.chat.value = { busy: false, items: ${MAIL_SAMPLE} }; S.page.value = -1;`, "wallpaper", undefined, WIDE_SIZES],
  ["kbd-panel", "home", `E.emit('system.insets', { top: 45, bottom: 16, left: 0, right: 0, keyboard: 330 }); S.chat.value = { busy: false, items: ${MAIL_SAMPLE} }; S.openPanel('ai');`, "wallpaper"],
  ["kbd-ai-wide", "home", `E.emit('system.insets', { top: 45, bottom: 16, left: 0, right: 0, keyboard: 330 }); S.chat.value = { busy: false, items: ${MAIL_SAMPLE} }; S.page.value = -1;`, "wallpaper", undefined, WIDE_SIZES],
  ["ai-chat", "home", `S.chat.value = { busy: false, items: ${CHAT_SAMPLE} }; S.page.value = -1;`, "wallpaper"],
  ["ai-compose", "home", "S.page.value = -1; await sleep(300); const f = document.querySelector('.ai-compose textarea, .ai-compose input'); f?.focus(); if (f) { f.value = 'summarise what the agents did overnight and what needs me'; f.dispatchEvent(new Event('input', { bubbles: true })); }", "wallpaper"],
  ["widget-screen", "home", "const w = S.home.value.items.find((i) => i.kind === 'widget'); S.screen.value = { key: w.key, title: 'weather' };", "wallpaper"],
  ["settings", "home", "(await U('./screens.ts')).openScreen('settings');", "wallpaper"],
  // The desktop's home: a laptop-wide grid (as hosts/desktop.ts's first home: ~110 px a column), the launcher, the chat.
  ["desktop", "desktop", DESKTOP_HOME, "wallpaper"],
  ["desktop-launcher", "desktop", DESKTOP_HOME + " S.drawer.value = 1;", "wallpaper"],
  ["desktop-chat", "desktop", DESKTOP_HOME + ` S.chat.value = { busy: false, items: ${CHAT_SAMPLE} }; S.chatting.value = true; S.drawer.value = 1;`, "wallpaper"],
  ["pull-apps", "pull", "E.emit('pull.begin', { kind: 'apps' }); E.emit('pull.drag', { p: 0.6 }); E.emit('pull.end', { open: true });", "blurred"],
  // Home's dock on the right: the launcher shows it as that column (its recents too), the list clear of it.
  ["pull-apps-right", "pull", "S.dockPlacement.value = 'right'; await sleep(100); E.emit('pull.begin', { kind: 'apps' }); E.emit('pull.drag', { p: 0.6 }); E.emit('pull.end', { open: true });", "blurred"],
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
  ["host-pull-mid", "shade", "E.emit('shade.panel', { panel: 'notifications' }); E.emit('shade.drag', { q: 0.1 }); await sleep(60); E.emit('shade.drag', { q: 0.5 }); await sleep(200);", "blurred"],
  ["host-pull-open", "shade", "E.emit('shade.panel', { panel: 'control' }); E.emit('shade.drag', { q: 0.1 }); await sleep(60); E.emit('shade.drag', { q: 0.7 }); await sleep(60); E.emit('shade.settle', { open: true }); await sleep(700);", "blurred"],
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
  // The control center v3 (state.ts ccV3): the first pull, the further pull, edit mode carrying a toggle.
  ["cc-v3-1-first", "shade", "S.ccV3.value = 'v3'; const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(700); const X = await U('./ui/ccexpand.ts'); ", "blurred"],
  ["cc-v3-2-over", "shade", "S.ccV3.value = 'v3'; const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(700); const X = await U('./ui/ccexpand.ts'); X.setExpanded(true); await sleep(600);", "blurred"],
  ["cc-v3-2b-over-end", "shade", "S.ccV3.value = 'v3'; const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(700); const X = await U('./ui/ccexpand.ts'); X.setExpanded(true); await sleep(600); document.querySelector('.notif-panel .notif-list').scrollTop = 99999; await sleep(300);", "blurred"],
  ["cc-v3-3-pulling", "shade", "S.ccV3.value = 'v3'; const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(700); const X = await U('./ui/ccexpand.ts'); X.stretch(60); await sleep(100);", "blurred"],
  ["cc-v3-4-edit", "shade", "S.ccV3.value = 'v3'; const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); S.notif.value = true; await sleep(700); const X = await U('./ui/ccexpand.ts'); X.setExpanded(true); await sleep(500); X.ccEditing.value = true; await sleep(200); const P = (el, type, x, y) => el.dispatchEvent(new PointerEvent(type, { bubbles: true, clientX: x, clientY: y, pointerId: 7, isPrimary: true, pointerType: 'touch' })); const t = document.querySelector('.cc3-all [data-key=\"bt\"] .cc3-t'); const r = t.getBoundingClientRect(); const x = r.left + r.width / 2, y = r.top + r.height / 2; P(t, 'pointerdown', x, y); await sleep(500); P(t, 'pointermove', x - 30, y + 4); await sleep(60); P(t, 'pointermove', x - r.width * 2 - 10, y + 6); await sleep(900);", "blurred"],
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
  // The host's review images (ShellHost _qa/: the phone's /home/powos/design-qa) from local copies in dev/.qa/ (untracked).
  if (p.startsWith("_qa/")) {
    const f = path.join(ROOT, "dev/.qa", path.basename(p));
    return fs.existsSync(f) ? { path: f, name: path.basename(p) } : null;
  }
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

/** In the page: what the layout checks read - the tiles', the merged tiles' and the seams' boxes, the gutter, fonts. */
const layoutBoxes = () => {
  const box = (r) => ({ left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width });
  const nameOf = (t) => (t.querySelector("[data-key], .owl, .island-face, .ag-panel") ?? t).className.toString().slice(0, 24);
  const all = (sel) => [...document.querySelectorAll(sel)];
  const missing = performance
    .getEntriesByType("resource")
    .filter((e) => e.responseStatus >= 400 && /font|\.ttf|\.woff/.test(e.name))
    .map((e) => e.name.replace(location.origin, ""));
  return {
    vw: innerWidth,
    vh: innerHeight,
    halfGap: (parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--gap")) || 8) / 2,
    desktop: document.documentElement.dataset.mode === "desktop",
    tiles: all(".home-tile").map((t) => ({ name: nameOf(t) || t.className.slice(0, 24), r: box(t.getBoundingClientRect()) })),
    joined: all(".home-tile.joined").map((t) => ({ name: nameOf(t), cell: box(t.getBoundingClientRect()), face: box((t.querySelector(":scope > .tile") ?? t).getBoundingClientRect()) })),
    seams: all(".seam").map((e) => ({ cls: e.className, bridge: e.classList.contains("bridge"), r: box(e.getBoundingClientRect()) })),
    glyphs: [...new Set([...[...document.fonts].filter((f) => f.status === "error").map((f) => f.family), ...missing])],
  };
};

/** Two boxes overlapping by more than touching: the overlap's width and height, or null. */
const overlap = (a, b) => {
  const w = Math.min(a.right, b.right) - Math.max(a.left, b.left);
  const h = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
  return w > 1 && h > 1 ? [w, h] : null;
};

/** Tiles that overlap (more than touching - merged tiles touch). */
function tileOverlaps(tiles) {
  const out = [];
  tiles.forEach((A, i) =>
    tiles.slice(i + 1).forEach((B) => {
      const o = overlap(A.r, B.r);
      if (o) out.push(`${A.name} x ${B.name} (${Math.round(o[0])}x${Math.round(o[1])} px)`);
    }),
  );
  return out;
}

/** The seam between A and B (B under A, or right of A when [vertical]): its geometry, or null where they don't share one. */
function seamOf(A, B, vertical) {
  const meet = vertical ? Math.abs(B.cell.left - A.cell.right) <= 1 : Math.abs(B.cell.top - A.cell.bottom) <= 1;
  if (!meet) return null;
  const [a0, a1, b0, b1] = vertical ? [A.face.top, A.face.bottom, B.face.top, B.face.bottom] : [A.face.left, A.face.right, B.face.left, B.face.right];
  const u0 = Math.max(a0, b0);
  const u1 = Math.min(a1, b1);
  if (u1 - u0 < 2) return null;
  const [aEnd, bStart] = vertical ? [A.face.right, B.face.left] : [A.face.bottom, B.face.top];
  return { u0, u1, aEnd, bStart, side: vertical ? "right" : "bottom" };
}

/**
 * Merged tiles touching over PART of an edge (the user's steam-over-fetch, 2026-10-22) must still be one surface,
 * their edges level: along the shared span the gutter is filled (the faces meet, or a .seam.bridge fills exactly
 * between them), and a partly-joined edge keeps its face where an unjoined edge's is (half a gutter in from its cell
 * line - a whole-edge extension there was the ragged step).
 */
function seamProblems(A, B, vertical, { bridges, halfGap, joined }) {
  const s = seamOf(A, B, vertical);
  if (!s) return [];
  const out = [];
  const [x0, y0, x1, y1] = vertical ? [s.aEnd, s.u0, s.bStart, s.u1] : [s.u0, s.aEnd, s.u1, s.bStart];
  const fills = (r) => Math.abs(r.left - x0) <= 1 && Math.abs(r.right - x1) <= 1 && Math.abs(r.top - y0) <= 1 && Math.abs(r.bottom - y1) <= 1;
  if (s.bStart - s.aEnd > 0.5 && !bridges.some(fills))
    out.push(`partial join: ${A.name} ${s.side} edge not merged with ${B.name} (${Math.round(s.bStart - s.aEnd)} px gap along the shared span)`);
  const aSpan = vertical ? A.cell.bottom - A.cell.top : A.cell.right - A.cell.left;
  const want = (vertical ? A.cell.right : A.cell.bottom) - halfGap;
  // Covered whole by its neighbours together (a 3x3 beside a 3x2 over a 3x1): that side reaches half the gutter, rightly.
  const covered = joined.reduce((n, C) => n + (C === A ? 0 : ((c) => (c ? c.u1 - c.u0 : 0))(seamOf(A, C, vertical))), 0);
  if (covered < aSpan - 2 * halfGap - 2 && Math.abs(s.aEnd - want) > 1) out.push(`partial join: ${A.name} ${s.side} edge off its row line by ${Math.round(s.aEnd - want)} px`);
  return out;
}

/** Every pair of merged tiles' seams, and no seam piece over a face (a fillet where a third tile fills the corner). */
function joinProblems(joined, seams, halfGap) {
  const ctx = { bridges: seams.filter((e) => e.bridge).map((e) => e.r), halfGap, joined };
  const pairs = joined.flatMap((A) => joined.filter((B) => B !== A).flatMap((B) => [...seamProblems(A, B, false, ctx), ...seamProblems(A, B, true, ctx)]));
  const over = seams.flatMap((e) => joined.filter((T) => overlap(e.r, T.face)).map((T) => `partial join: a seam piece (${e.cls.replace("tile seam ", "")}) over ${T.name}'s face`));
  return [...pairs, ...over];
}

/** The desktop's grid: one even gutter between neighbouring tiles in a row (its tiles never merge or touch). */
function desktopGutters(tiles) {
  const rows = new Map();
  for (const t of tiles) {
    const k = [...rows.keys()].find((y) => Math.abs(y - t.r.top) <= 2) ?? t.r.top;
    rows.set(k, [...(rows.get(k) ?? []), t.r]);
  }
  const gaps = [...rows.values()].flatMap((row) => row.sort((a, b) => a.left - b.left).slice(1).map((r, i) => Math.round(r.left - row[i].right)));
  return gaps.length && Math.max(...gaps) - Math.min(...gaps) > 2 ? [`uneven gutters: ${gaps.join(", ")} px`] : [];
}

/**
 * Layout checks: tiles that overlap, partly-merged tiles, seams over faces, the desktop's gutters, and glyphs that can't
 * render (a font that failed or 404'd draws tofu). SHOTS_STRICT=1 fails the run on any.
 */
function layoutProblems(b) {
  const onScreen = (r) => r.width > 0 && r.right > 0 && r.left < b.vw && r.bottom > 0 && r.top < b.vh;
  const tiles = b.tiles.filter((t) => onScreen(t.r));
  const joined = b.joined.filter(({ cell }) => cell.width > 0 && cell.right > 0 && cell.left < b.vw);
  const overlaps = [...tileOverlaps(tiles), ...joinProblems(joined, b.seams, b.halfGap), ...(b.desktop ? desktopGutters(tiles) : [])];
  return { overlaps, glyphs: b.glyphs };
}

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


// The shade's pull as a filmstrip (dev/filmstrip.mjs): 3 Gmail cards (a stack) + others, the host's pull 0..1, the
// control center's expand pull 0..its height, then the host's pull shut. Folded only.
const FILM_N = "const now = Math.floor(Date.now() / 1000); E.emit('notifications.changed', { available: true, items: [['Signal', 'Mats', 'are we still on for tonight?', 120, true], ['Gmail', 'Your order has shipped', 'It arrives Thursday.', 3600], ['Gmail', 'Invoice 4411', 'Paid, thanks.', 3700], ['Gmail', 'Weekly digest', 'Five new posts.', 3800], ['Calendar', 'Dentist', 'Tomorrow 09:30', 7200]].map(([app, title, text, ago, conversation], i) => ({ key: 'f' + i, app, icon: null, title, text, time: now - ago, clearable: true, profile: null, conversation: !!conversation })) }); await sleep(200); ";
const FOLDED = { folded: SIZES.folded };
for (let i = 0; i <= 10; i++)
  SCENES.push([`film-a-${String(i).padStart(2, "0")}`, "shade", FILM_N + `E.emit('shade.panel', { panel: 'notifications' }); E.emit('shade.drag', { q: 0.01 }); await sleep(60); E.emit('shade.drag', { q: ${i / 10} }); await sleep(120);`, "blurred", undefined, FOLDED]);
for (let i = 0; i <= 10; i++)
  SCENES.push([`film-b-${String(i).padStart(2, "0")}`, "shade", FILM_N + `S.notif.value = true; await sleep(500); const X = await U('./ui/ccexpand.ts'); X.stretch(1); await sleep(30); const h = document.querySelector('.cc-more, .cc-ext, .cc')?.scrollHeight ?? 300; X.stretch(${i / 10} * (window.__ccH ?? 260)); await sleep(60);`, "blurred", undefined, FOLDED]);
for (let i = 0; i <= 5; i++)
  SCENES.push([`film-c-${String(i).padStart(2, "0")}`, "shade", FILM_N + `E.emit('shade.panel', { panel: 'notifications' }); S.notif.value = true; await sleep(500); E.emit('shade.drag', { q: 0.99 }); await sleep(60); E.emit('shade.drag', { q: ${1 - i / 5} }); await sleep(120);`, "blurred", undefined, FOLDED]);

// The launcher's close as a filmstrip: open, then a finger takes it down p 1 -> 0 - the pill and the dock (bottom folded,
// the right column unfolded) leave with the panel on the same --p.
const PULL_OPEN = "E.emit('pull.begin', { kind: 'apps' }); E.emit('pull.end', { open: true }); await sleep(500); E.emit('pull.drag', { p: 1 }); await sleep(60); ";
for (let i = 0; i <= 4; i++) {
  SCENES.push([`film-l-${String(i).padStart(2, "0")}`, "pull", PULL_OPEN + `E.emit('pull.drag', { p: ${1 - i / 4} }); await sleep(120);`, "blurred", undefined, FOLDED]);
  SCENES.push([`film-lr-${String(i).padStart(2, "0")}`, "pull", "S.dockPlacement.value = 'right'; await sleep(100); " + PULL_OPEN + `E.emit('pull.drag', { p: ${1 - i / 4} }); await sleep(120);`, "blurred", undefined, { unfolded: SIZES.unfolded }]);
}


try {
  for (const [name, mode, setup, behind, touch, sizes] of SCENES) {
    for (const [sizeName, size] of Object.entries(sizes ?? (mode === "desktop" ? DESKTOP_SIZES : SIZES))) {
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
  if (strict) console.error("shots: FAIL - overlapping tiles, partial joins, uneven desktop gutters or missing glyphs (report.json)");
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
                  : `html { background: ${pic}; } .glass-native :is(.tile, .notif-panel):not(:is(.tile, .notif-panel) *) { backdrop-filter: blur(calc(var(--glass-blur-native, 140px) * 0.22)); }`
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
        .evaluate(layoutBoxes)
        .then(layoutProblems)
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

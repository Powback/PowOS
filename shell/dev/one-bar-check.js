/**
 * OB1 (the user, 2026-11-01 17:52 / 18:24 / 18:25: "one single search bar that acts differently depending on which page
 * you're on ... the launcher also needs the full search bar"): runs in home's page (gate.mjs "one-bar-*") against the
 * mock bridge. On home, in the launcher and on PowOS AI's page: exactly one bar (.bar[data-role]) - none folded on home
 * while it's the dock's button - its role (data-role, the placeholder) the page's; the AI page's bar seated on the page's
 * .ai-bar-slot under the tabs, on screen, and its send going into the chat thread (powos.ai.send), the field cleared.
 * BM1 (18:25: "the launcher also needs the full search bar"): folded, that one bar's glass grows from the dock button's
 * box into the full bar on the launcher and the AI page (a mid-animation frame between the two) and back home into it.
 * BM2 ("why is the dock showing in the AI launcher page?"): unfolded, the launcher's AI panel has no dock showing, the
 * bar in the "ai" role the foot's full width, and its chat the AI page's own (.ai-page-chat), nothing in it monospace.
 */
const BAR = ".bar[data-role]";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function barIs(where, role, hint) {
  const bars = document.querySelectorAll(BAR);
  if (bars.length !== 1) return [`${where}: ${bars.length} bars, not one`];
  const b = bars[0];
  const f = [];
  if (b.dataset.role !== role) f.push(`${where}: the bar's role is "${b.dataset.role}", not "${role}"`);
  const ph = b.querySelector("textarea")?.getAttribute("placeholder") ?? "";
  if (hint && ph !== hint) f.push(`${where}: the bar says "${ph}", not "${hint}"`);
  return f;
}

const box = (r) => `${Math.round(r.left)}..${Math.round(r.right)}, ${Math.round(r.top)}..${Math.round(r.bottom)}`;
const onScreen = (p) => p.left >= -1 && p.right <= innerWidth + 1 && p.bottom <= innerHeight + 1 && p.top >= 0;
const onSlot = (p, s) => Math.abs(p.left - s.left) <= 24 && Math.abs(p.right - s.right) <= 24 && p.top >= s.top - 24 && p.bottom <= s.bottom + 8;

/** The AI page: the bar's pill on the slot (under the tabs: the slot's row before it), fully on screen. */
function seated(where) {
  const slot = document.querySelector(".ai-screen [data-bar-slot=ai]");
  const pill = document.querySelector(`${BAR} .bar-pill`);
  if (!slot || !pill) return [`${where}: no slot (${!!slot}) or no pill (${!!pill})`];
  const s = slot.getBoundingClientRect(), p = pill.getBoundingClientRect();
  const tabs = slot.previousElementSibling?.matches(".ai-segs") ? slot.previousElementSibling.getBoundingClientRect() : null;
  return [
    [onScreen(p), `${where}: the bar is off screen (${box(p)})`],
    [onSlot(p, s), `${where}: the bar (${box(p)}) isn't on the slot (${box(s)})`],
    [!tabs || tabs.bottom <= p.top + 4, `${where}: the tabs (${tabs && box(tabs)}) aren't just above the bar (${box(p)})`],
  ].filter(([ok]) => !ok).map(([, why]) => why);
}

async function aiSends(where, powos, S) {
  const sent = [];
  const was = powos.ai.send;
  powos.ai.send = async (t, ...rest) => (sent.push(t), was?.call(powos.ai, t, ...rest));
  S.query.value = "hello manager";
  await window.__gw.frames(2);
  document.querySelector(BAR).requestSubmit();
  await sleep(300);
  powos.ai.send = was;
  const f = [];
  if (!sent.some((t) => String(t).startsWith("hello manager"))) f.push(`${where}: the send didn't reach the chat thread (ai.send got [${sent}])`);
  if (S.query.value) f.push(`${where}: the field kept "${S.query.value}" after the send`);
  if (S.page.value !== -1) f.push(`${where}: the send left PowOS AI's page (page ${S.page.value})`);
  return f;
}

/** Home folded is the dock's button (no bar); unfolded the bar, searching. */
function homeIs(where, folded) {
  if (!folded) return barIs(where, "search");
  const f = document.querySelector(BAR) ? [`${where} folded: a bar, not the dock's button`] : [];
  return document.querySelector(".home .dock .dock-search") ? f : [...f, `${where} folded: no dock button`];
}

/** The bar's glass as shown: its morph pieces' union (launchmorph.ts) while it morphs, else its pill. */
function glassBox() {
  const parts = [...document.querySelectorAll(`${BAR} .launch-glass`)].map((e) => e.getBoundingClientRect());
  if (!parts.length) return document.querySelector(`${BAR} .bar-pill`)?.getBoundingClientRect() ?? null;
  const l = Math.min(...parts.map((r) => r.left)), r = Math.max(...parts.map((p) => p.right));
  return { left: l, right: r, width: r - l, top: Math.min(...parts.map((p) => p.top)), bottom: Math.max(...parts.map((p) => p.bottom)) };
}

const faceBox = () => document.querySelector(".home .dock .dock-search-face")?.getBoundingClientRect() ?? null;

/**
 * [go] starts it; the morph's frames sampled (its animations paused at 0 and half way): the glass starts as the
 * button ([button]: the face before [go]), half way it's wider than that and narrower than the bar, then the pieces go.
 */
async function morphs(where, G, go, button) {
  const anims = () => document.getAnimations().filter((a) => a.id === "launch-morph");
  go();
  if (!(await G.until(() => anims().length && document.querySelector(`${BAR} .launch-glass`), 2000))) return [`${where}: no morph (the bar didn't grow out of the button)`];
  const all = anims();
  all.forEach((a) => a.pause());
  const at = (k) => (all.forEach((a) => (a.currentTime = a.effect.getComputedTiming().duration * k)), glassBox());
  const start = at(0), mid = at(0.5), full = document.querySelector(`${BAR} .bar-pill`).getBoundingClientRect();
  all.forEach((a) => a.play());
  const f = [];
  const [from, to] = where.endsWith("home") ? [full, button] : [button, full];
  const near = (a, b) => Math.abs(a.left - b.left) <= 6 && Math.abs(a.width - b.width) <= 6;
  if (!near(start, from)) f.push(`${where}: its first frame (${box(start)}) isn't ${where.endsWith("home") ? "the bar" : "the button"} (${box(from)})`);
  if (!(mid.width > Math.min(from.width, to.width) + 8 && mid.width < Math.max(from.width, to.width) - 8)) f.push(`${where}: half way its width ${Math.round(mid.width)} isn't between the button's ${Math.round(button.width)} and the bar's ${Math.round(full.width)}`);
  if (!(await G.until(() => !document.querySelector(".launch-glass"), 2000))) f.push(`${where}: the morph's pieces stayed`);
  return f;
}

/** Back home after a morph: no bar, the button shown again (not left away). */
function buttonBack(where) {
  const b = document.querySelector(".home .dock .dock-search");
  if (document.querySelector(BAR)) return [`${where}: the bar stayed after the morph back`];
  return b && !b.classList.contains("away") ? [] : [`${where}: the button isn't back`];
}

async function launcherIs(G, S, folded) {
  S.pullKind.value = "apps";
  const button = faceBox();
  const f = folded && button ? await morphs("launcher", G, () => (S.drawer.value = 1), button) : ((S.drawer.value = 1), []);
  await G.until(() => document.querySelector(`${BAR}[data-role=apps]`), 3000);
  await sleep(350);
  f.push(...barIs("launcher", "apps", "Search apps"));
  if (folded && button) f.push(...(await morphs("launcher back home", G, () => (S.drawer.value = 0), button)), ...buttonBack("launcher back home"));
  else S.drawer.value = 0;
  await sleep(400);
  return f;
}

async function aiPageIs(G, S, powos, folded) {
  const button = faceBox();
  const f = folded && button ? await morphs("AI page", G, () => (S.page.value = -1), button) : ((S.page.value = -1), []);
  await G.until(() => document.querySelector(`${BAR}.seated`), 3000);
  await sleep(450);
  f.push(...barIs("AI page", "ai", "Message the manager"), ...seated("AI page"), ...(folded ? fullBar("AI page") : []));
  return f.length ? f : aiSends("AI page", powos, S);
}

const shows = (d) => {
  const r = d.getBoundingClientRect(), cs = getComputedStyle(d);
  return r.width > 0 && r.bottom > 0 && r.top < innerHeight && +cs.opacity > 0.05 && cs.visibility !== "hidden";
};
function noDock() {
  const seen = [...document.querySelectorAll(".home:not(.pull-screen) > :is(.dock, .dock-tray)")].filter(shows);
  return seen.length ? [`AI panel: the dock shows over it (${seen.map((d) => d.className).join(" | ")})`] : [];
}
function fullFoot() {
  const p = document.querySelector(`${BAR} .bar-pill`)?.getBoundingClientRect();
  const wide = document.querySelector(".home .launcher-frame")?.getBoundingClientRect().width || innerWidth;
  const ok = p && p.width >= wide - 64 && p.bottom >= innerHeight - 96;
  return ok ? [] : [`AI panel: the bar (${p && box(p)}) isn't the foot's full width (${Math.round(wide)}) at the bottom`];
}
function pageChat() {
  const chat = document.querySelector(".home .ai-panel .ai-chat");
  if (!chat?.matches(".ai-page-chat") || !document.querySelector(".ai-screen .ai-page-chat")) return ["AI panel: its chat isn't the AI page's (.ai-page-chat)"];
  const mono = [chat, ...chat.querySelectorAll("*")].find((e) => /mono/i.test(getComputedStyle(e).fontFamily));
  return mono ? [`AI panel: monospace in its chat (${mono.tagName.toLowerCase()}.${mono.className})`] : [];
}

/** The user, 19:03 ("the search bar turns into the input bar for the chat"): folded, the AI page's full bar is visible at the foot. */
function fullBar(where) {
  const pill = document.querySelector(`${BAR} .bar-pill`);
  const p = pill?.getBoundingClientRect();
  const cs = pill && getComputedStyle(pill.closest(".bar"));
  const ok = p && cs && shows(pill) && +cs.opacity > 0.9 && p.width >= innerWidth - 64 && p.bottom >= innerHeight - 120;
  return ok ? [] : [`${where}: the full bar isn't visible at the foot (${p && box(p)}, ${innerWidth}x${innerHeight})`];
}

/** BM2: unfolded, the launcher's AI panel open - no dock showing, the "ai" bar full width at the foot, the page's chat. */
async function aiPanelIs(G, S) {
  S.pullKind.value = "ai";
  S.drawer.value = 1;
  await G.until(() => document.querySelector(".home .ai-panel") && document.querySelector(`${BAR}[data-role=ai]`), 3000);
  await sleep(450);
  const f = [...barIs("AI panel", "ai", "Message the manager"), ...noDock(), ...fullFoot(), ...pageChat()];
  S.drawer.value = 0;
  await sleep(450);
  if (S.pullKind.value === "ai") S.pullKind.value = "apps";
  return f;
}

export async function oneBarCheck(label) {
  const G = window.__gw;
  const S = await importShim("./state.ts");
  const { powos } = await importShim("./bridge.ts");
  const folded = label === "folded";
  if (folded) {
    if (S.dock.value.length < 6) S.dock.value = S.recent.value.slice(0, 6);
    S.searchTry.value = "dock";
  }
  await G.settled(() => document.querySelector(".home > .dock"), ".home > .dock");
  if (!folded) S.chat.value = { busy: false, items: [{ kind: "user", text: "hi" }, { kind: "assistant", text: "Hello - `code` here." }] };
  const fails = [...homeIs("home", folded), ...(await launcherIs(G, S, folded)), ...(folded ? [] : await aiPanelIs(G, S)), ...(await aiPageIs(G, S, powos, folded))];
  // Back home: the role goes back, the bar off the AI page (folded: morphing back into the button).
  const button = folded && faceBox();
  if (button) fails.push(...(await morphs("AI page back home", G, () => (S.page.value = 0), button)), ...buttonBack("AI page back home"));
  else S.page.value = 0;
  await sleep(450);
  fails.push(...homeIs("home again", folded));
  S.searchTry.value = "";
  return fails.map((f) => `${label}: ${f}`);
}

/** The launcher overlay's window (mode=pull): its one bar filters apps. */
export async function oneBarPull() {
  const S = await importShim("./state.ts");
  S.pullKind.value = "apps";
  S.drawer.value = 1;
  await window.__gw.until(() => document.querySelector(BAR), 3000);
  return barIs("launcher overlay", "apps", "Search apps");
}

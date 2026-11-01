/**
 * OB1 (the user, 2026-11-01 17:52 / 18:24 / 18:25: "one single search bar that acts differently depending on which page
 * you're on ... the launcher also needs the full search bar"): runs in home's page (gate.mjs "one-bar-*") against the
 * mock bridge. On home, in the launcher and on PowOS AI's page: exactly one bar (.bar[data-role]) - none folded on home
 * while it's the dock's button - its role (data-role, the placeholder) the page's; the AI page's bar seated on the page's
 * .ai-bar-slot under the tabs, on screen, and its send going into the chat thread (powos.ai.send), the field cleared.
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

async function launcherIs(G, S) {
  S.pullKind.value = "apps";
  S.drawer.value = 1;
  await G.until(() => document.querySelector(`${BAR}[data-role=apps]`), 3000);
  await sleep(350);
  const f = barIs("launcher", "apps", "Search apps");
  S.drawer.value = 0;
  await sleep(400);
  return f;
}

async function aiPageIs(G, S, powos) {
  S.page.value = -1;
  await G.until(() => document.querySelector(`${BAR}.seated`), 3000);
  await sleep(450);
  const f = [...barIs("AI page", "ai", "Message the manager"), ...seated("AI page")];
  return f.length ? f : aiSends("AI page", powos, S);
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
  const fails = [...homeIs("home", folded), ...(await launcherIs(G, S)), ...(await aiPageIs(G, S, powos))];
  // Back home: the role goes back, the bar off the AI page.
  S.page.value = 0;
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

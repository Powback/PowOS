/**
 * S8'' - the shade's one scroll (board task shade-streamlined-no-drawer-panel-cc-floats-on-t; the user, 2026-10-30:
 * "the control center should be sticky at the top and just be able to like collapse"): gate.mjs's
 * shade-scroll-{folded,unfolded} cases, in the shade's page (mode=shade), 16 notifications seeded.
 * SC1 folded, the control center expanded: the notification list is the one scroller; its header row (date, edit,
 *     settings) never moves; the card's drawn bottom edge comes up 1:1 with the scroll until it is compact, then stays;
 *     the notification cards move exactly with the scroll; just under the card's edge it is the list that is hit, not the card.
 * SC2 back at the top: everything as it was (no .cc-sticky, no vars left on the panel body).
 * SC3 unfolded (two columns): scrolling the notifications column leaves the control center exactly where it was.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
const APPS = ["Signal", "Gmail", "Calendar", "Slack", "Spotify", "Maps", "Bank", "Weather"];

function seed() {
  const now = Math.floor(Date.now() / 1000);
  const items = Array.from({ length: 16 }, (_, i) => ({
    key: `sc${i}`, app: APPS[i % APPS.length], pkg: `test.${APPS[i % APPS.length].toLowerCase()}`, icon: null,
    title: `Notification ${i + 1}`, text: `Something happened ${i * 7 + 2} min ago.`, time: now - i * 420 - 60,
    clearable: true, profile: null, conversation: false,
  }));
  window.__mockEvents.emit("notifications.changed", { available: true, items });
}

/** The card's drawn bottom: its box's bottom less its clip-path's bottom inset (shell.css .cc-sticky > .cc). */
function drawnBottom(card) {
  const m = /inset\(\s*[-\d.]+px\s+[-\d.]+px\s+([-\d.]+)px/.exec(getComputedStyle(card).clipPath);
  return card.getBoundingClientRect().bottom - (m ? parseFloat(m[1]) : 0);
}

async function at(l, s) {
  l.scrollTop = s;
  await frame();
  return l.scrollTop;
}

/** The folded one-panel shade's parts, or why there are none. */
function parts() {
  const body = document.querySelector(".notif-panel.shown .panel-body.together:not(.two)");
  const card = body?.querySelector(":scope > .cc");
  const l = body?.querySelector(":scope > .notif-own > .notif-list");
  const head = card?.querySelector(":scope > .notif-bar");
  const first = l?.querySelector(".notif");
  if (body && card && l && head && first) return { body, card, l, head, first };
  return { why: `folded: SC1: no one-panel shade (body ${!!body}, card ${!!card}, list ${!!l}, header ${!!head}, a card ${!!first})` };
}

/** SC1 at scroll [s]: the header pinned, the card's edge up by min(s, room), the cards 1:1, the list hit under the edge. */
function sc1(p, base, s, room) {
  const h = p.head.getBoundingClientRect().top, b = drawnBottom(p.card), n = p.first.getBoundingClientRect().top;
  const fails = [];
  if (Math.abs(h - base.h) > 0.5) fails.push(`the header row moved ${(h - base.h).toFixed(1)} px (want pinned)`);
  if (Math.abs(base.b - b - Math.min(s, room)) > 1) fails.push(`the card's edge came up ${(base.b - b).toFixed(1)} px (want ${Math.min(s, room)}, room ${room})`);
  if (Math.abs(base.n - n - s) > 1) fails.push(`the notifications moved ${(base.n - n).toFixed(1)} px (want 1:1)`);
  const r = p.l.getBoundingClientRect();
  const hit = document.elementFromPoint(r.left + r.width / 2, b + 4);
  if (hit && p.card.contains(hit)) fails.push(`4 px under the card's edge is the card (${hit.className}), not the list`);
  return fails.map((f) => `folded: SC1: scrolled ${s} px, ${f}`);
}

/** SC2: back at the top, nothing of the collapse left. */
function sc2(p, base) {
  const left = ["--sc-room", "--sc-a", "--sc-up"].filter((k) => p.body.style.getPropertyValue(k));
  const on = p.body.classList.contains("cc-sticky");
  const fails = [];
  if (on || left.length) fails.push(`folded: SC2: back at the top and .cc-sticky ${on ? "on" : "off"}, vars left: ${left.join(" ") || "none"}`);
  if (Math.abs(drawnBottom(p.card) - base.b) > 0.5) fails.push(`folded: SC2: back at the top the card's edge is ${(drawnBottom(p.card) - base.b).toFixed(1)} px off`);
  return fails;
}

async function folded() {
  const p = parts();
  if (p.why) return [p.why];
  const over = p.l.scrollHeight - p.l.clientHeight;
  if (over < 300) return [`folded: SC1: the list can scroll only ${over} px with 16 notifications`];
  await at(p.l, 0);
  const base = { h: p.head.getBoundingClientRect().top, b: drawnBottom(p.card), n: p.first.getBoundingClientRect().top };
  const fails = [];
  let room = 0;
  for (const want of [1, 24, 80, 160, 260, 400]) {
    const s = await at(p.l, want);
    if (!p.body.classList.contains("cc-sticky")) return [...fails, `folded: SC1: scrolled ${s} px and the control center isn't sticky (.cc-sticky off)`];
    room ||= parseFloat(p.body.style.getPropertyValue("--sc-room")) || 0;
    fails.push(...sc1(p, base, s, room));
  }
  if (!room) fails.push("folded: SC1: the expanded control center had no room to collapse (--sc-room 0)");
  await at(p.l, 0);
  return [...fails, ...sc2(p, base)];
}

async function unfolded() {
  const body = document.querySelector(".notif-panel.shown .panel-body.two");
  const l = body?.querySelector(".notif-list.notif-col");
  const cc = body?.querySelector(".cc");
  if (!body || !l || !cc) return [`unfolded: SC3: no two-column shade (body ${!!body}, list ${!!l}, control center ${!!cc})`];
  if (l.scrollHeight - l.clientHeight < 100) return [`unfolded: SC3: the notifications column can scroll only ${l.scrollHeight - l.clientHeight} px`];
  const r0 = JSON.stringify(cc.getBoundingClientRect());
  const fails = [];
  for (const want of [40, 200, 0]) {
    const s = await at(l, want);
    if (JSON.stringify(cc.getBoundingClientRect()) !== r0) fails.push(`unfolded: SC3: the notifications scrolled to ${s} px and the control center moved`);
    if (body.classList.contains("cc-sticky")) fails.push(`unfolded: SC3: .cc-sticky on at ${s} px (two columns: nothing collapses)`);
  }
  return fails;
}

export async function scroll(label) {
  const [S, E] = await Promise.all(["./state.ts", "./ui/ccexpand.ts"].map((m) => importShim(m)));
  try {
    S.ccV3.value = "v3";
    seed();
    S.notif.value = true;
    E.ccExpanded.value = true;
    await sleep(700);
    await window.__gw.settled(() => document.querySelector(".notif-panel.shown .notif-list .notif"), ".notif-panel");
    return label === "folded" ? await folded() : await unfolded();
  } finally {
    E.ccExpanded.value = E.expandedByDefault();
    S.notif.value = false;
  }
}

/**
 * The shade's notification groups (notifications.tsx Stack; the user, 11-01 16:39: "no, just show like 3 cards and
 * then an 'x more' hint"): gate.mjs's shade-notif-stacks-* cases. Three groups - of 1, 3 and 7 - in the open shade,
 * folded and unfolded, top- and bottom-aligned:
 * NS1: all three groups shown (scrolled to, folded: three full cards each don't fit one screen), nothing expanded.
 * NS2: the 3-group shows 3 full cards, one after another: each its whole height (not clipped), its own title, the
 *      group's full width (no narrower, offset strip), no overlap; newest nearest the thumb.
 * NS3: the 7-group the same 3 full cards plus "+4 more" (on the side away from the thumb).
 * NS4: a tap on "+4 more" opens that group only (all 7 laid out), a tap on its head folds it again.
 * NS8 (11-01 17:04: "If there's just one notification for something, group those together at the top"): the two
 *      single-app notifications (Solo, Uno) first, one list without any group head, each card its own app name; then
 *      the groups by their newest (Trio, Seven); bottom-aligned the same mirrored.
 * NS9 (11-01 17:03: "I should be able to tap them to expand them and see them"): Uno's long text is clamped; a tap on
 *      its body expands it in place (all of it laid out, no clamp) without opening the app, an Open button then
 *      opens it; a tap again folds it.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const frames = (n) => new Promise((r) => { const f = () => (--n <= 0 ? r() : requestAnimationFrame(f)); requestAnimationFrame(f); });
const r0 = (v) => Math.round(v);

// Newest app first: Solo, Trio, Seven, then Uno - the oldest, but a single, so above both groups (NS8).
const GROUPS = [["Solo", 1], ["Trio", 3], ["Seven", 7], ["Uno", 1]];
const ORDER = ["Solo", "Uno", "Trio", "Seven"];
const LONG = 12;
const title = (app, i) => `${app} title ${i + 1}`;
const text = (app, i) =>
  app === "Uno" ? Array.from({ length: LONG }, (_, l) => `Uno ${l ? "line" : "first line"} ${l + 1}`).join("\n") : `${app} first line ${i + 1}\nsecond line`;

/** The mock's notifications: the groups (the newest app first: Solo, then Trio, then Seven), then the shade open. */
const seedItems = (now) =>
  GROUPS.flatMap(([app, n], g) =>
    Array.from({ length: n }, (_, i) => ({
      key: `${app}-${i}`, app, pkg: `test.${app.toLowerCase()}`, title: title(app, i), text: text(app, i),
      time: now - 60 * (g * 10 + i + 1), icon: null, clearable: true, profile: null, conversation: false,
    })),
  );
export async function stacksSeed() {
  const items = seedItems(Math.floor(Date.now() / 1000));
  window.__mockEvents.emit("notifications.changed", { available: true, items });
  (await importShim("./state.ts")).notif.value = true;
  await sleep(700);
  return [];
}

/** [app]'s group: its stack (or lone card), its shown cards and its "+N more". */
function groupOf(app) {
  const heads = [...document.querySelectorAll(".notif-panel.shown .notif-stack")];
  const stack = heads.find((st) => st.querySelector(":scope > .notif-group-head .notif-app")?.textContent === app);
  if (stack) return { stack, cards: [...stack.querySelectorAll(":scope > .notif-shown > .notif")], more: stack.querySelector(":scope > .notif-show-more") };
  const card = [...document.querySelectorAll(".notif-panel.shown .notif.tile")].find((c) => c.textContent.includes(title(app, 0)));
  return { stack: null, cards: card ? [card] : [], more: null };
}

const onScreen = (b, cx, cy) => b.height > 0 && b.width > 0 && cy >= 0 && cy <= innerHeight && cx >= 0 && cx <= innerWidth;

/**
 * [el] on screen (scrolled to: on a folded phone the control center and three full cards per group are taller than the
 * screen) and on top at its centre: the failure, or null.
 */
function seen(el, what, at) {
  el.scrollIntoView({ block: "nearest" });
  const b = el.getBoundingClientRect();
  const cy = b.top + b.height / 2, cx = b.left + b.width / 2;
  if (!onScreen(b, cx, cy)) return `${at}: ${what} not on screen (${r0(b.top)}..${r0(b.bottom)} of ${innerHeight})`;
  const top = document.elementFromPoint(cx, cy);
  return top && (el.contains(top) || top.contains(el)) ? null : `${at}: ${what} is covered by ${top?.className || top?.tagName}`;
}

/** Card [i] of [app]: a full card - its whole height laid out (its text not clipped), its title, the group's width. */
function cardOk(c, i, o) {
  const { app, at, width } = o;
  const what = `${app}'s card ${i + 1}`;
  const fails = [seen(c, what, at)].filter(Boolean);
  const b = c.getBoundingClientRect();
  if (c.scrollHeight > c.clientHeight + 1 || b.height < 40) fails.push(`${at}: ${what} is ${r0(b.height)} px tall of ${c.scrollHeight} (clipped)`);
  if (Math.abs(b.width - width) > 1) fails.push(`${at}: ${what} is ${r0(b.width)} px wide, not the group's ${r0(width)} (a strip)`);
  const t = c.querySelector(".notif-title")?.textContent;
  if (t !== title(app, i)) fails.push(`${at}: ${what} reads "${t}", not "${title(app, i)}"`);
  if (!c.querySelector(".notif-text")?.textContent.includes(`${app} first line ${i + 1}`)) fails.push(`${at}: ${what}'s text isn't shown`);
  return fails;
}

/** [cards] one after another, newest nearest the thumb (lowest bottom-aligned), none overlapping the next. */
function orderOk(cards, app, bottom, at) {
  const fails = [];
  for (let i = 1; i < cards.length; i++) {
    const p = cards[i - 1].getBoundingClientRect(), b = cards[i].getBoundingClientRect();
    const gap = bottom ? p.top - b.bottom : b.top - p.bottom;
    if (gap < 0) fails.push(`${at}: ${app}'s card ${i + 1} is ${bottom ? "not above" : "not below"} card ${i} (overlap ${r0(-gap)} px)`);
  }
  return fails;
}

/** The "+N more" past [o].app's group of [n]: on the far side of its cards from the thumb. */
function moreOk(g, n, o) {
  const { more, cards } = g;
  const { app, bottom, at } = o;
  if (n <= 3) return more ? [`${at}: ${app} (${n}) says "${more.textContent}"`] : [];
  if (more?.textContent !== `+${n - 3} more`) return [`${at}: ${app} says "${more?.textContent ?? "nothing"}", not "+${n - 3} more"`];
  const fails = [seen(more, `${app}'s "+${n - 3} more"`, at)].filter(Boolean);
  const mb = more.getBoundingClientRect(), last = cards[cards.length - 1].getBoundingClientRect();
  if (bottom ? mb.bottom > last.top + 1 : mb.top < last.bottom - 1) fails.push(`${at}: ${app}'s "+${n - 3} more" isn't ${bottom ? "above" : "below"} its cards`);
  return fails;
}

/** One group of [n] at [o].at: a lone card, or min(n, 3) full cards and its "+N more". */
function groupOk(app, n, o) {
  const { at, bottom } = o;
  const g = groupOf(app);
  if (!g.cards.length) return [`${at}: no ${app} notification in the shade`];
  if (n === 1) return [seen(g.cards[0], `${app}'s card`, at)].filter(Boolean);
  if (!g.stack) return [`${at}: ${app} (${n}) isn't a group`];
  const fails = [];
  if (g.stack.classList.contains("open")) fails.push(`${at}: ${app}'s group is open unasked`);
  if (g.cards.length !== Math.min(3, n)) return [...fails, `${at}: ${app} shows ${g.cards.length} cards, not ${Math.min(3, n)}`];
  const width = g.stack.getBoundingClientRect().width;
  const s = { app, at, width };
  return [...fails, ...g.cards.flatMap((c, i) => cardOk(c, i, s)), ...orderOk(g.cards, app, bottom, at), ...moreOk(g, n, { app, bottom, at })];
}

/** [app]'s lone card: in the singles list, no group head, its own app name - the failure, or null. */
function single(app, at) {
  const c = groupOf(app).cards[0];
  if (!c?.closest(".notif-singles")) return `${at}: ${app}'s lone card isn't in the singles list`;
  if (c.closest(".notif-stack")) return `${at}: ${app}'s lone card has a group head`;
  return c.querySelector(".notif-app")?.textContent === app ? null : `${at}: ${app}'s lone card doesn't name its app`;
}

/** NS8: the singles first in one headless list (each card its own app name), then the groups by newest; mirrored bottom-aligned. */
function singlesOk(bottom, at) {
  const fails = ["Solo", "Uno"].map((app) => single(app, at)).filter(Boolean);
  const tops = ORDER.map((app) => (groupOf(app).stack ?? groupOf(app).cards[0])?.getBoundingClientRect().top ?? NaN);
  const sign = bottom ? -1 : 1;
  if (!tops.every((t, i) => !i || sign * (t - tops[i - 1]) > 0))
    fails.push(`${at}: not ${ORDER.join(", ")} ${bottom ? "from the bottom up" : "from the top down"} (${ORDER.map((a, i) => `${a} ${r0(tops[i])}`).join(", ")})`);
  return fails;
}

/** NS1-NS3, NS8 at [at], [bottom]-aligned or not. */
const layered = (bottom, at) => [...GROUPS.flatMap(([app, n]) => groupOk(app, n, { bottom, at })), ...singlesOk(bottom, at)];

const tap = (el) => {
  const b = el.getBoundingClientRect();
  const o = { bubbles: true, clientX: b.left + b.width / 2, clientY: b.top + Math.min(b.height / 2, 12), pointerId: 7, isPrimary: true };
  el.dispatchEvent(new PointerEvent("pointerdown", o));
  el.dispatchEvent(new PointerEvent("pointerup", o));
};
/** Cut short: its text overflows its box, or a line clamp in force (the "…"). */
const clamped = (t) => {
  const cs = getComputedStyle(t);
  return t.scrollHeight > t.clientHeight + 1 || (cs.display === "-webkit-box" && cs.webkitLineClamp !== "none");
};

/** A tap on Uno's text (folds the card the render left open). */
export async function stacksUnoTap() {
  const t = groupOf("Uno").cards[0]?.querySelector(".notif-text");
  if (t) tap(t);
  await frames(3);
  return [];
}

/** Uno's card expanded by a tap: whole, not clipped, the app not opened, an Open button - the failures. */
function expandedOk(card, t, opened, at) {
  const fails = [];
  if (!card.classList.contains("expanded")) fails.push(`${at}: a tap on Uno's card didn't expand it`);
  if (clamped(t) || !t.textContent.includes(`Uno line ${LONG}`)) fails.push(`${at}: Uno expanded is still clamped (${t.scrollHeight}/${t.clientHeight} px, clamp ${getComputedStyle(t).webkitLineClamp})`);
  if (card.scrollHeight > card.clientHeight + 1) fails.push(`${at}: Uno expanded is clipped (${card.scrollHeight}/${card.clientHeight} px)`);
  if (opened.length) fails.push(`${at}: a tap on Uno's body opened the app`);
  if (!card.querySelector(".notif-open")) fails.push(`${at}: Uno expanded has no Open button`);
  return fails;
}

/** Folded again by a second tap, then expanded and opened by its Open button: the shade shuts (reopened after). */
async function foldThenOpen(card, t, opened, at) {
  const fails = [];
  tap(t);
  await frames(3);
  if (card.classList.contains("expanded") || !clamped(t)) fails.push(`${at}: a second tap didn't fold Uno back`);
  tap(t);
  await frames(3);
  card.querySelector(".notif-open")?.click();
  if (opened[0] !== "Uno-0") fails.push(`${at}: Uno's Open didn't open it (${opened.join() || "nothing"})`);
  const S = await importShim("./state.ts");
  if (S.notif.value) fails.push(`${at}: Open left the shade open`);
  S.notif.value = true;
  await sleep(600);
  return fails;
}

/** NS9: Uno's long text clamped, a tap expands it whole without opening the app, a tap folds it, Open opens it. */
export async function stacksCardExpand(at, keepOpen) {
  const B = await importShim("./bridge.ts");
  const opened = [];
  const real = B.powos.notifications.open;
  B.powos.notifications.open = async (k) => void opened.push(k);
  try {
    const card = groupOf("Uno").cards[0];
    const t = card?.querySelector(".notif-text");
    if (!t) return [`${at}: no Uno card with its text`];
    card.scrollIntoView({ block: "nearest" });
    if (!clamped(t)) return [`${at}: Uno's ${LONG}-line text isn't clamped folded (${t.scrollHeight}/${t.clientHeight} px)`];
    tap(t);
    await frames(3);
    const fails = expandedOk(card, t, opened, at);
    return keepOpen ? fails : [...fails, ...(await foldThenOpen(card, t, opened, at))];
  } finally {
    B.powos.notifications.open = real;
  }
}

/** NS4: a tap on Seven's "+4 more" opens it alone, all 7 laid out; its head folds it back. */
export async function stacksExpand(at) {
  const fails = [];
  const seven = groupOf("Seven"), trio = groupOf("Trio");
  seven.more.click();
  await sleep(450);
  if (!seven.stack.classList.contains("open")) return [`${at}: a tap on Seven's "+4 more" didn't open it`];
  if (trio.stack.classList.contains("open")) fails.push(`${at}: a tap on Seven's "+4 more" opened Trio's too`);
  const all = [...seven.stack.querySelectorAll(".notif")].filter((c) => c.getBoundingClientRect().height > 40 && !c.closest("[inert]"));
  if (all.length !== 7) fails.push(`${at}: Seven open lays out ${all.length} of its 7 cards`);
  if (groupOf("Trio").cards.length !== 3) fails.push(`${at}: Trio shows ${groupOf("Trio").cards.length} cards with Seven open`);
  seven.stack.querySelector(":scope > .notif-group-head").click();
  await sleep(450);
  if (seven.stack.classList.contains("open")) fails.push(`${at}: a tap on Seven's head didn't fold it back`);
  return fails;
}

/** The shade's notifications in [align] (a check's try, not stored): NS1-NS3. */
export async function stacksAt(align, at) {
  const A = await importShim("./ui/align.ts");
  A.alignTry.value = { ...A.alignTry.value, shade: align };
  await frames(3);
  await sleep(300);
  if (document.documentElement.dataset.alignShade !== align) return [`${at}: html shows shade ${document.documentElement.dataset.alignShade}, not ${align}`];
  const fails = layered(align === "bottom", at);
  // The render: the list at its thumb end, the newest in view.
  const card = document.querySelector(".notif-panel.shown .notif-items .notif");
  for (let el = card?.parentElement; el; el = el.parentElement) if (el.scrollHeight > el.clientHeight + 1) el.scrollTop = align === "bottom" ? el.scrollHeight : 0;
  await frames(2);
  return fails;
}

/**
 * NS5 (the user, 11-01 16:47: "Let's move the notifications to the top"): nothing stored, the shade's list is top-
 * aligned folded and unfolded: the singles, then the groups newest first - Solo, Uno, Trio, Seven from the top.
 */
export async function stacksDefault(at) {
  await frames(2);
  const a = document.documentElement.dataset.alignShade;
  if (a !== "top") return [`${at}: no stored setting, the notifications are ${a}-aligned, not top`];
  return singlesOk(false, at);
}

/** NS6: bottom-aligned, an overflowing list opens (shade shut, then opened) scrolled to its thumb end, newest in view. */
export async function stacksOpenEnd(at) {
  const S = await importShim("./state.ts");
  const A = await importShim("./ui/align.ts");
  A.alignTry.value = { ...A.alignTry.value, shade: "bottom" };
  // Enough to overflow the unfolded column too: ten more apps of one card each, then the shade shut and opened again.
  const now = Math.floor(Date.now() / 1000);
  const extra = Array.from({ length: 10 }, (_, i) => ({
    key: `Extra-${i}`, app: `Extra${i}`, pkg: `test.extra${i}`, title: `Extra ${i}`, text: "one line\nsecond line",
    time: now - 3600 - 60 * i, icon: null, clearable: true, profile: null, conversation: false,
  }));
  window.__mockEvents.emit("notifications.changed", { available: true, items: [...seedItems(now), ...extra] });
  S.notif.value = false;
  await sleep(500);
  S.notif.value = true;
  await sleep(800);
  const l = [...document.querySelectorAll(".notif-panel.shown .notif-list")].find((el) => el.querySelector(".notif-items"));
  if (!l) return [`${at}: no notification list in the open shade`];
  const max = l.scrollHeight - l.clientHeight;
  if (max < 40) return [`${at}: the list doesn't overflow (${max} px) - the check needs it to`];
  return max - l.scrollTop > 2 ? [`${at}: bottom-aligned, the list opens at ${r0(l.scrollTop)} of ${r0(max)} px, not its thumb end`] : [];
}

/**
 * NS7: the one-time move of the user's stored pick (ui/align.ts shadeMoved), on a fresh copy of the module as a new
 * page loads it: a stored "bottom" with no marker reads top (stored as top, marker set); then an explicit bottom, the
 * marker in place, stays bottom on the next load. The launcher's stored pick is untouched.
 */
const ls = (k) => localStorage.getItem(`powos.${k}`);
const MIGRATE_KEYS = ["align.shade.folded", "align.shade.unfolded", "align.launcher.unfolded", "align.shade-moved-top"];

/** The old state: the notifications and the launcher stored bottom, no marker; then a fresh module load. */
async function movedOnce(at) {
  localStorage.removeItem("powos.align.shade-moved-top");
  for (const k of MIGRATE_KEYS.slice(0, 3)) localStorage.setItem(`powos.${k}`, "bottom");
  const A = await importShim(`./ui/align.ts?ns7a=${Date.now()}`);
  const fails = ["folded", "unfolded"].flatMap((m) => {
    const v = A.alignChoice("shade", m).value;
    return v === "top" && ls(`align.shade.${m}`) === "top" ? [] : [`${at}: a stored old bottom (${m}) reads ${v} (stored ${ls(`align.shade.${m}`)}) after the move, not top`];
  });
  if (ls("align.shade-moved-top") !== "1") fails.push(`${at}: the move left no marker`);
  if (ls("align.launcher.unfolded") !== "bottom") fails.push(`${at}: the move touched the launcher's pick (${ls("align.launcher.unfolded")})`);
  return { A, fails };
}

export async function stacksMigrate(at) {
  const keep = MIGRATE_KEYS.map((k) => [k, ls(k)]);
  try {
    const { A, fails } = await movedOnce(at);
    A.alignChoice("shade", "unfolded").value = "bottom";
    const v = (await importShim(`./ui/align.ts?ns7b=${Date.now()}`)).alignChoice("shade", "unfolded").value;
    return v === "bottom" ? fails : [...fails, `${at}: a later pick of bottom didn't stick (reads ${v})`];
  } finally {
    for (const [k, v] of keep) v == null ? localStorage.removeItem(`powos.${k}`) : localStorage.setItem(`powos.${k}`, v);
  }
}

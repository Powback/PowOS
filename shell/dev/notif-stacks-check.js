/**
 * The shade's notification groups (notifications.tsx Stack; the user, 11-01 16:39: "no, just show like 3 cards and
 * then an 'x more' hint"): gate.mjs's shade-notif-stacks-* cases. Three groups - of 1, 3 and 7 - in the open shade,
 * folded and unfolded, top- and bottom-aligned:
 * NS1: all three groups shown (scrolled to, folded: three full cards each don't fit one screen), nothing expanded.
 * NS2: the 3-group shows 3 full cards, one after another: each its whole height (not clipped), its own title, the
 *      group's full width (no narrower, offset strip), no overlap; newest nearest the thumb.
 * NS3: the 7-group the same 3 full cards plus "+4 more" (on the side away from the thumb).
 * NS4: a tap on "+4 more" opens that group only (all 7 laid out), a tap on its head folds it again.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const frames = (n) => new Promise((r) => { const f = () => (--n <= 0 ? r() : requestAnimationFrame(f)); requestAnimationFrame(f); });
const r0 = (v) => Math.round(v);

const GROUPS = [["Solo", 1], ["Trio", 3], ["Seven", 7]];
const title = (app, i) => `${app} title ${i + 1}`;
const text = (app, i) => `${app} first line ${i + 1}\nsecond line`;

/** The mock's notifications: the groups (the newest app first: Solo, then Trio, then Seven), then the shade open. */
export async function stacksSeed() {
  const now = Math.floor(Date.now() / 1000);
  const items = GROUPS.flatMap(([app, n], g) =>
    Array.from({ length: n }, (_, i) => ({
      key: `${app}-${i}`, app, pkg: `test.${app.toLowerCase()}`, title: title(app, i), text: text(app, i),
      time: now - 60 * (g * 10 + i + 1), icon: null, clearable: true, profile: null, conversation: false,
    })),
  );
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

/** NS1-NS3 at [at], [bottom]-aligned or not. */
const layered = (bottom, at) => GROUPS.flatMap(([app, n]) => groupOk(app, n, { bottom, at }));

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

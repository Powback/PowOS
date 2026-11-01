/**
 * The shade's notification stacks (notifications.tsx Stack/Peeks; the user, 11-01 15:43: "doesn't show like 3 of
 * each"): gate.mjs's shade-notif-stacks-* cases. Three groups - of 1, 3 and 7 - in the open shade, folded and unfolded,
 * top- and bottom-aligned:
 * NS1: all three groups on screen at once, nothing expanded.
 * NS2: the 3-group shows 3 layered: its newest in full, the 2nd and 3rd as strips peeking out from behind it, each
 *      narrower than the one in front and offset past it (away from the thumb bottom-aligned), first line readable
 *      (its line uncovered, not clipped to nothing, the right text).
 * NS3: the 7-group the same 3 plus "+4 more".
 * NS4: a tap on a stack opens that group only (its others laid out), a tap on its head folds it again.
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

/** [app]'s group: its stack (or lone card), its front card and its strips. */
function groupOf(app) {
  const heads = [...document.querySelectorAll(".notif-panel.shown .notif-stack")];
  const stack = heads.find((st) => st.querySelector(":scope > .notif-group-head .notif-app")?.textContent === app);
  if (stack) return { stack, front: stack.querySelector(":scope > .notif"), peeks: [...stack.querySelectorAll(":scope > .notif-peeks .notif-peek")] };
  const card = [...document.querySelectorAll(".notif-panel.shown .notif.tile")].find((c) => c.textContent.includes(title(app, 0)));
  return { stack: null, front: card, peeks: [] };
}

const onScreen = (b, cx, cy) => b.height > 0 && b.width > 0 && cy >= 0 && cy <= innerHeight && cx >= 0 && cx <= innerWidth;

/** [el] on screen and on top at its centre: the failure, or null. */
function seen(el, what, at) {
  const b = el.getBoundingClientRect();
  const cy = b.top + b.height / 2, cx = b.left + b.width / 2;
  if (!onScreen(b, cx, cy)) return `${at}: ${what} not on screen (${r0(b.top)}..${r0(b.bottom)} of ${innerHeight})`;
  const top = document.elementFromPoint(cx, cy);
  return top && (el.contains(top) || top.contains(el)) ? null : `${at}: ${what} is covered by ${top?.className || top?.tagName}`;
}

/** A strip's line: laid out, uncovered, the right words. */
function lineOk(line, want, what, at) {
  const lb = line?.getBoundingClientRect();
  if (!lb || lb.height < 8) return [`${at}: ${what}'s line is ${r0(lb?.height ?? 0)} px tall (clipped)`];
  const fails = [seen(line, `${what}'s line`, at)].filter(Boolean);
  if (line.textContent !== want) fails.push(`${at}: ${what} reads "${line.textContent}", not "${want}"`);
  return fails;
}

/** Strip [i] of [app] ([p]) behind [front] (the one in front of it; [o].bottom: bottom-aligned): narrower, out past it, readable. */
function stripOk(p, front, i, o) {
  const { app, bottom, at } = o;
  const pb = p.getBoundingClientRect(), fb = front.getBoundingClientRect();
  const what = `${app}'s strip ${i + 2}`;
  const fails = [];
  if (!(pb.width < fb.width - 8)) fails.push(`${at}: ${what} is ${r0(pb.width)} px wide, not narrower than the one in front (${r0(fb.width)})`);
  const out = bottom ? fb.top - pb.top : pb.bottom - fb.bottom;
  if (!(out >= 14)) fails.push(`${at}: ${what} peeks out ${r0(out)} px past the one in front (${bottom ? "above" : "below"} it), not a line's worth`);
  return [...fails, ...lineOk(p.querySelector(".notif-peek-line"), `${title(app, i + 1)} · ${app} first line ${i + 2}`, what, at)];
}

/** The "+N more" under (over, bottom-aligned) a stack of [n]. */
function moreOk(stack, app, n, at) {
  const more = stack.querySelector(".notif-peek-more");
  if (n <= 3) return more ? [`${at}: ${app} (${n}) says "${more.textContent}"`] : [];
  if (more?.textContent !== `+${n - 3} more`) return [`${at}: ${app} says "${more?.textContent ?? "nothing"}", not "+${n - 3} more"`];
  return [seen(more, `${app}'s "+${n - 3} more"`, at)].filter(Boolean);
}

/** One group of [n] at [o].at: its newest seen; a stack: folded, two strips layered, its "+N more". */
function groupOk(app, n, o) {
  const { at } = o;
  const g = groupOf(app);
  if (!g.front) return [`${at}: no ${app} notification in the shade`];
  const fails = [seen(g.front, `${app}'s newest card`, at)].filter(Boolean);
  if (n === 1) return fails;
  if (!g.stack) return [...fails, `${at}: ${app} (${n}) isn't a stack`];
  if (g.stack.classList.contains("open")) fails.push(`${at}: ${app}'s stack is open unasked`);
  if (g.peeks.length !== 2) return [...fails, `${at}: ${app} shows ${g.peeks.length} strips behind its card, not 2`];
  const s = { ...o, app };
  return [...fails, ...stripOk(g.peeks[0], g.front, 0, s), ...stripOk(g.peeks[1], g.peeks[0], 1, s), ...moreOk(g.stack, app, n, at)];
}

/** NS1-NS3 at [at], [bottom]-aligned or not. */
const layered = (bottom, at) => GROUPS.flatMap(([app, n]) => groupOk(app, n, { bottom, at }));

/** A finger's tap on [el]'s centre (Card's pointer handlers). */
function tap(el) {
  const b = el.getBoundingClientRect();
  const o = { bubbles: true, clientX: b.left + b.width / 2, clientY: b.top + b.height / 2, pointerId: 3, isPrimary: true, pointerType: "touch" };
  el.dispatchEvent(new PointerEvent("pointerdown", { ...o, buttons: 1 }));
  el.dispatchEvent(new PointerEvent("pointerup", { ...o, buttons: 0 }));
}

/** NS4: a tap on Seven's stack opens it alone, its 6 others laid out; its head folds it back. */
export async function stacksExpand(at) {
  const fails = [];
  const seven = groupOf("Seven"), trio = groupOf("Trio");
  tap(seven.front);
  await sleep(450);
  if (!seven.stack.classList.contains("open")) return [`${at}: a tap on Seven's stack didn't open it`];
  if (trio.stack.classList.contains("open")) fails.push(`${at}: a tap on Seven's stack opened Trio's too`);
  const rest = [...seven.stack.querySelectorAll(":scope > .notif-rest .notif")];
  const shown = rest.filter((c) => c.getBoundingClientRect().height > 20 && !c.closest("[inert]"));
  if (shown.length !== 6) fails.push(`${at}: Seven open lays out ${shown.length} of its other 6 cards`);
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
  return layered(align === "bottom", at);
}

/**
 * The shade task's plan steps (board task shade-streamlined-no-drawer-panel-cc-floats-on-t, "Notification screen +
 * control center (S1-S10)"): gate.mjs's shade-steps-{folded,unfolded} cases, in the shade's page (mode=shade).
 * S1 folded collapsed: the cover (folded) opens the control center folded to its one row; the inner screen (unfolded,
 *    desktop mode) opens it expanded (ccexpand.ts expandedByDefault = hosts/wide.ts desktopScreen).
 * S3 quick launchers in both states: the quick-launch row is on screen, on top and tappable with the control center
 *    folded AND expanded (f0f0361d: "the phone opens folded with its quick launchers shown").
 * S4 no CC card / no notification panel bg: the control center and the notifications' own panel paint no fill, edge,
 *    shadow or blur of their own - their tiles and cards float on the shade's one backdrop (05907ded, f0f0361d).
 * S10 desktop never folds: on the inner screen a fold pull on the card (ccexpand.ts stretch/settle, gesture.ts's ccAll)
 *    lets go whole, and a shade shut and opened again opens expanded. The cover is the control: the same pull folds it.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Quick-page items resolve without an installed app (the gate's stub has none).
const ROW = ["qp:android.settings.WIFI_SETTINGS", "qp:android.settings.BLUETOOTH_SETTINGS", "qp:android.settings.DISPLAY_SETTINGS"];

/** [el] paints nothing of its own: no fill, no image, no shadow, no backdrop-filter. */
function bare(el, what, at) {
  if (!el) return [`${at}: S4: no ${what} in the open shade`];
  const cs = getComputedStyle(el);
  const fails = [];
  if (cs.backgroundColor !== "rgba(0, 0, 0, 0)" || cs.backgroundImage !== "none") fails.push(`${at}: S4: ${what} paints a background (${cs.backgroundColor} / ${cs.backgroundImage.slice(0, 60)})`);
  if (cs.boxShadow !== "none") fails.push(`${at}: S4: ${what} has a shadow/edge (${cs.boxShadow.slice(0, 60)})`);
  const bf = cs.backdropFilter || cs.webkitBackdropFilter;
  if (bf && bf !== "none") fails.push(`${at}: S4: ${what} has its own backdrop-filter ${bf}`);
  return fails;
}

const opacity = (el) => (el ? Number(getComputedStyle(el).opacity) * opacity(el.parentElement) : 1);
const inView = (b, x, y) => b.width > 0 && x >= 0 && x <= innerWidth && y >= 0 && y <= innerHeight;

/** Why chip [c] isn't seen (off screen, see-through, covered), or null. */
function unseen(c) {
  const b = c.getBoundingClientRect();
  const [x, y] = [b.left + b.width / 2, b.top + b.height / 2];
  if (!inView(b, x, y)) return `a quick-launch chip is off screen (${Math.round(x)},${Math.round(y)})`;
  if (opacity(c) <= 0.5) return `a quick-launch chip is see-through (${opacity(c).toFixed(2)})`;
  const top = document.elementFromPoint(x, y);
  return top && (c.contains(top) || top.contains(c)) ? null : `a quick-launch chip is covered by ${top?.className || top?.tagName}`;
}

/** The quick-launch row seen: every item's chip inside the viewport, at least half opaque, the top element at its centre. */
function launchersSeen(at, state) {
  const chips = [...document.querySelectorAll(".notif-panel.shown .cc3-launchers .cc3-grid:not(.cc3-spare) .cc3-chip")];
  if (chips.length < ROW.length) return [`${at}: S3: ${state}, ${chips.length} quick-launch chips shown, not ${ROW.length}`];
  return chips.map(unseen).filter(Boolean).map((why) => `${at}: S3: ${state}, ${why}`);
}

/** S1: the control center opened in its mode's state - folded on the cover, expanded on the inner screen. */
function opened(E, at) {
  const want = at === "unfolded";
  const word = (x) => (x ? "expanded" : "folded");
  const seen = [
    ["expandedByDefault()", E.expandedByDefault()],
    ["ccExpanded", E.ccExpanded.value],
    ["the toggle list (whole)", !!document.querySelector(".notif-panel.shown .cc3-list.whole")],
  ];
  return seen.filter(([, v]) => v !== want).map(([what, v]) => `${at}: S1: ${what} opened ${word(v)} at ${innerWidth}px (want ${word(want)})`);
}

/** S3: the row in both states. */
async function bothStates(E, at) {
  const fails = [];
  for (const ex of [false, true]) {
    E.ccExpanded.value = ex;
    await sleep(400);
    await window.__gw.settled();
    fails.push(...launchersSeen(at, ex ? "expanded" : "folded"));
  }
  return fails;
}

const whole = () => !!document.querySelector(".notif-panel.shown .cc3-list.whole");

/** S10's fold pull: past FOLD_AT on the card, let go; unfolded it settles whole, folded (the control) it folds. */
async function foldPull(E, at) {
  E.ccExpanded.value = true;
  await window.__gw.settled();
  E.stretch(-(E.FOLD_AT + 120));
  E.settle(true);
  await sleep(500);
  await window.__gw.settled();
  const [ex, wh] = [E.ccExpanded.value, whole()];
  if (at === "unfolded") return ex && wh ? [] : [`${at}: S10: a fold pull folded the control center on the desktop screen (ccExpanded ${ex}, list whole ${wh})`];
  return ex || wh ? [`${at}: S10 control: the same fold pull didn't fold it on the cover (ccExpanded ${ex}) - the check proves nothing`] : [];
}

/** S10's reopen: the shade shut and opened again opens in its mode's state (desktop expanded, cover folded). */
async function reopened(E, S, at) {
  const want = at === "unfolded";
  S.notif.value = false;
  await sleep(400);
  S.notif.value = true;
  await window.__gw.settled(() => document.querySelector(".notif-panel.shown .cc3-list"), ".notif-panel");
  const ok = E.ccExpanded.value === want && whole() === want;
  return ok ? [] : [`${at}: S10: shut and opened again, the control center opened ${E.ccExpanded.value ? "expanded" : "folded"} (want ${want ? "expanded" : "folded"})`];
}

/** S4: no card behind the controls, no panel behind the notifications. */
function noCards(at) {
  const notifs = at === "folded" ? [".panel-body.together > .notif-own", "the notifications' panel"] : [".panel-body.two > .notif-col", "the notifications' column"];
  return [...bare(document.querySelector(".notif-panel.shown .cc.v3"), "the control center", at), ...bare(document.querySelector(`.notif-panel.shown ${notifs[0]}`), notifs[1], at)];
}

export async function steps(at) {
  const [S, E, B, L] = await Promise.all(["./state.ts", "./ui/ccexpand.ts", "./bridge.ts", "./ui/launchers.tsx"].map((m) => importShim(m)));
  const was = await B.powos.store.get("controls.launchers");
  try {
    S.ccV3.value = "v3";
    await B.powos.store.set("controls.launchers", ROW);
    L.loadLaunchers();
    S.notif.value = true;
    await window.__gw.settled(() => document.querySelector(".notif-panel.shown .cc3-launchers .cc3-chip"), ".notif-panel");
    const first = opened(E, at);
    return [...first, ...(await bothStates(E, at)), ...noCards(at), ...(await foldPull(E, at)), ...(await reopened(E, S, at))];
  } finally {
    E.ccExpanded.value = E.expandedByDefault();
    await B.powos.store.set("controls.launchers", was ?? null);
    L.loadLaunchers();
    S.notif.value = false;
  }
}

/**
 * The shade against docs/DESIGN-LANGUAGE.md (design wave 4; design-audit/gaps.md §3 notifications, §4 control center):
 * gate.mjs's shade-design-{folded,unfolded} cases, in the shade's page (mode=shade).
 * SD1 (§2 THE backdrop): the notification panel names no blur of its own (no backdrop-filter; the host blurs the
 *      window at --shade-blur-native = --backdrop-blur-native) and no tint of its own over the scrim's; its corners on
 *      the radius scale.
 * SD2 (§6 no pop-ins): a notification's big picture is in the card (loaded) while it's folded, hidden; opened, it is
 *      shown with its fade running - it used to be mounted on open, 0 tall until it loaded.
 * SD3 (§6): a category opened in place (the eight-tile layout) - its members themselves fade in, each with an
 *      animation, not just the row growing round them.
 * SD4 (§7): a long press on a control that opens its page fires one haptic tick.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const SCALE = new Set(["0px", "8px", "12px", "20px", "999px", "50%"]);
const PICTURE = `data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><rect width="320" height="180" fill="#4285f4"/></svg>')}`;

export async function panelMaterial(at) {
  const S = await importShim("./state.ts");
  S.panel.value = "notifications";
  S.notif.value = true;
  await sleep(500);
  const p = document.querySelector(".notif-panel");
  if (!p) return [`${at}: SD1: no .notif-panel`];
  const fails = [];
  // The base rule, whatever layout overrides it: a probe panel outside the shade's body.
  const probe = document.createElement("div");
  probe.className = "notif-panel";
  probe.style.visibility = "hidden";
  document.body.append(probe);
  for (const [what, el] of [["the panel", p], ["the panel's own rule", probe]]) {
    const cs = getComputedStyle(el);
    const bf = cs.backdropFilter || cs.webkitBackdropFilter;
    if (bf && bf !== "none") fails.push(`${at}: SD1: ${what} has its own backdrop-filter ${bf} (§2: the host's blur is THE backdrop)`);
    if (cs.backgroundColor !== "rgba(0, 0, 0, 0)" || cs.backgroundImage !== "none") fails.push(`${at}: SD1: ${what} paints a tint of its own (${cs.backgroundColor}) over the scrim's`);
    for (const c of ["borderTopLeftRadius", "borderTopRightRadius", "borderBottomLeftRadius", "borderBottomRightRadius"])
      if (!SCALE.has(cs[c])) fails.push(`${at}: SD1: ${what}'s ${c} ${cs[c]} is off the radius scale`);
  }
  probe.remove();
  const blur = getComputedStyle(document.documentElement).getPropertyValue("--shade-blur-native").trim();
  const want = getComputedStyle(document.documentElement).getPropertyValue("--backdrop-blur-native").trim();
  if (blur !== want) fails.push(`${at}: SD1: --shade-blur-native ${blur} is not THE backdrop's ${want}`);
  return fails;
}

export async function picture(at) {
  const now = Math.floor(Date.now() / 1000);
  window.__mockEvents.emit("notifications.changed", {
    available: true,
    items: [{ key: "pic-0", app: "Photos", pkg: "test.photos", title: "Shared album", text: "3 new photos", time: now - 60, icon: null, clearable: true, profile: null, conversation: false, picture: PICTURE }],
  });
  await sleep(600);
  const card = [...document.querySelectorAll(".notif-panel.shown .notif.tile")].find((c) => c.textContent.includes("Shared album"));
  if (!card) return [`${at}: SD2: the picture's card isn't in the shade`];
  const img = card.querySelector(".notif-picture");
  if (!img) return [`${at}: SD2: the folded card has no (hidden) picture: it would mount, unloaded, on open`];
  const fails = [];
  if (getComputedStyle(img).display !== "none") fails.push(`${at}: SD2: the picture shows on a folded card`);
  for (let i = 0; i < 50 && !img.complete; i++) await sleep(20);
  if (!img.complete || !img.naturalWidth) fails.push(`${at}: SD2: the hidden picture isn't loaded before the card opens`);
  // Open it as a tap on its body does (notifications.tsx openCards).
  card.querySelector(".notif-text").dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, clientX: 60, clientY: 60, pointerId: 3, isPrimary: true }));
  card.querySelector(".notif-text").dispatchEvent(new PointerEvent("pointerup", { bubbles: true, clientX: 60, clientY: 60, pointerId: 3, isPrimary: true }));
  card.querySelector(".notif-text").click();
  await sleep(30);
  if (!card.classList.contains("expanded")) return [...fails, `${at}: SD2: a tap didn't open the card`];
  if (getComputedStyle(img).display === "none") fails.push(`${at}: SD2: the opened card's picture isn't shown`);
  else if (!img.getAnimations().some((a) => a.animationName === "notif-picture-in")) fails.push(`${at}: SD2: the picture appears with no fade (a pop-in)`);
  else if (img.getBoundingClientRect().height < 20) fails.push(`${at}: SD2: the picture is ${img.getBoundingClientRect().height} px tall on open (not loaded)`);
  return fails;
}

export async function members(at) {
  const S = await importShim("./state.ts");
  const was = S.ccV3.value;
  S.ccV3.value = "tiles";
  await sleep(500);
  const fails = [];
  try {
    const more = document.querySelector(".notif-panel .cc-tile .cc-more");
    if (!more) return [`${at}: SD3: no category with members (no .cc-more chevron)`];
    more.click();
    await sleep(40);
    const subs = [...document.querySelectorAll(".cc-unfold.open .cc-subs > .cc-sub")];
    if (!subs.length) fails.push(`${at}: SD3: the opened category shows no members`);
    else if (!subs.every((s) => s.getAnimations().some((a) => a.playState === "running" || a.playState === "pending")))
      fails.push(`${at}: SD3: ${subs.filter((s) => !s.getAnimations().length).length} of ${subs.length} members appear without their own animation (a pop-in inside the growing row)`);
    more.click();
    await sleep(40);
    const row = document.querySelector(".cc-unfold:not(.open) .cc-subs");
    if (row && getComputedStyle(row).transitionProperty.indexOf("opacity") < 0) fails.push(`${at}: SD3: folding, the members don't fade (no opacity transition)`);
  } finally {
    S.ccV3.value = was;
    await sleep(300);
  }
  return fails;
}

export async function longPressHaptic(at) {
  if (!window.__hapticsMock) return [`${at}: SD4: no mock haptics`];
  const S = await importShim("./state.ts");
  S.ccV3.value = "v3";
  await sleep(400);
  const { powos } = await importShim("./bridge.ts");
  // A control with a page of its own: Wi-Fi's opens a quick page, the others the host's (stubbed: no page leaves).
  const btn = [...document.querySelectorAll(".notif-panel .cc3-cell[data-key] > .cc3-t")].find((b) => !["lockscreen", "screenshot"].includes(b.parentElement.dataset.key) && !/tests|fps/i.test(b.parentElement.dataset.key));
  if (!btn) return [`${at}: SD4: no control to hold`];
  const open = powos.qs.open;
  powos.qs.open = () => Promise.resolve();
  const t0 = window.__hapticsMock.tick;
  const b = btn.getBoundingClientRect();
  const ev = (type) => btn.dispatchEvent(new PointerEvent(type, { bubbles: true, clientX: b.left + 4, clientY: b.top + 4, pointerId: 4, isPrimary: true, pointerType: "touch" }));
  try {
    ev("pointerdown");
    await sleep(700);
    ev("pointerup");
  } finally {
    powos.qs.open = open;
  }
  const n = window.__hapticsMock.tick - t0;
  return n === 1 ? [] : [`${at}: SD4: a long press opening ${btn.parentElement.dataset.key}'s page fired ${n} haptic ticks, not 1 (§7)`];
}

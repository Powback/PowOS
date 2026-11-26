/**
 * Snooze (notifications.tsx; board task snooze-a-notification): gate.mjs's shade-notif-snooze-* cases, in the open
 * shade against the mock bridge (notifications.snooze stubbed here):
 * SZ1: a long press on a card opens its Snooze choices - 15 min, 1 h, 2 h, Tomorrow - in place of its actions.
 * SZ2: a choice takes the card out at once (before the host answers); refused by the host, the card comes back.
 * SZ3: taken, it stays out (the host's next list no longer has it) and the bridge got that card's key and the choice's ms.
 * SZ4: a card slid part way rests out with its clock beside it; a tap on the clock opens the choices; "Tomorrow" asks
 *      for the time until 8:00 the next morning.
 * SZ5: a host without snooze (an older APK, no `snooze` in its list): no long-press menu, no clock.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const SETTLE_MS = 650;
const title = (app) => `${app} snooze title`;
const seed = (now) =>
  ["Alpha", "Beta", "Gamma"].map((app, i) => ({
    key: `${app}-sz`, app, pkg: `test.${app.toLowerCase()}`, title: title(app), text: `${app} text`, time: now - 60 * (i + 1),
    icon: null, clearable: true, profile: null, conversation: false, smallIcon: null, color: null,
  }));
const cardOf = (app) => [...document.querySelectorAll(".notif-panel.shown .notif.tile")].find((c) => c.textContent.includes(title(app)));
const ev = (el, type, x, y) => el.dispatchEvent(new PointerEvent(type, { bubbles: true, clientX: x, clientY: y, pointerId: 9, isPrimary: true }));

async function longPress(card) {
  card.scrollIntoView({ block: "nearest" });
  const b = card.getBoundingClientRect();
  ev(card, "pointerdown", b.left + 30, b.top + 12);
  await sleep(650);
  ev(card, "pointerup", b.left + 30, b.top + 12);
  await sleep(50);
}
const choice = (card, label) => [...card.querySelectorAll(".notif-snooze button")].find((b) => b.textContent.trim() === label);

/** The test's host: notifications.snooze answers after 250 ms - refused while [host.fail]; [host.calls] what it got. */
async function stubHost() {
  const B = await importShim("./bridge.ts");
  const host = { calls: [], fail: false, items: seed(Math.floor(Date.now() / 1000)), real: B.powos.notifications.snooze, cap: Element.prototype.setPointerCapture };
  host.emit = (snooze = true) => window.__mockEvents.emit("notifications.changed", { available: true, snooze, items: host.items });
  B.powos.notifications.snooze = async (key, ms) => {
    host.calls.push({ key, ms });
    await sleep(250);
    if (host.fail) throw new Error("refused");
    host.items = host.items.filter((n) => n.key !== key);
    host.emit();
  };
  Element.prototype.setPointerCapture = () => {};
  host.restore = () => ((B.powos.notifications.snooze = host.real), (Element.prototype.setPointerCapture = host.cap));
  return host;
}

/** SZ1 + SZ2: the long-press menu; a refused choice takes Alpha out at once and brings it back. */
async function menuRefused(host, at) {
  await longPress(cardOf("Alpha"));
  const a = cardOf("Alpha");
  const labels = [...(a?.querySelectorAll(".notif-snooze button[role=menuitem]") ?? [])].map((b) => b.textContent.trim());
  if (labels.join("|") !== "15 min|1 h|2 h|Tomorrow") return [`${at}: SZ1 long press shows [${labels.join(", ")}], not the four choices`];
  host.fail = true;
  choice(a, "1 h").click();
  await sleep(30);
  const fails = cardOf("Alpha") ? [`${at}: SZ2 Alpha still shown right after "1 h" (not optimistic)`] : [];
  await sleep(250 + SETTLE_MS);
  host.fail = false;
  return cardOf("Alpha") ? fails : [...fails, `${at}: SZ2 Alpha didn't come back after the host refused`];
}

/** SZ3: a choice the host takes - out at once, and stays out. */
async function menuTaken(host, at) {
  await longPress(cardOf("Alpha"));
  choice(cardOf("Alpha"), "15 min")?.click();
  await sleep(30);
  const fails = cardOf("Alpha") ? [`${at}: SZ3 Alpha still shown right after "15 min"`] : [];
  await sleep(250 + SETTLE_MS);
  if (cardOf("Alpha")) fails.push(`${at}: SZ3 Alpha back after a snooze the host took`);
  const last = host.calls[host.calls.length - 1];
  if (last?.key !== "Alpha-sz" || last.ms !== 15 * 60_000) fails.push(`${at}: SZ3 bridge got ${JSON.stringify(last)}, not Alpha-sz for 15 min`);
  return fails;
}

/** Beta slid 60 px (slow, not a flick) and let go. */
async function slidePartWay(b) {
  b.scrollIntoView({ block: "nearest" });
  const r = b.getBoundingClientRect(), y = r.top + 12;
  ev(b, "pointerdown", r.left + 20, y);
  ev(b, "pointermove", r.left + 40, y);
  await sleep(200);
  ev(b, "pointermove", r.left + 80, y);
  ev(b, "pointerup", r.left + 80, y);
  await sleep(SETTLE_MS);
}

/** SZ4: Beta rests out with its clock; the clock opens the choices; Tomorrow asks until 8:00 tomorrow. */
async function peekTomorrow(host, at) {
  await slidePartWay(cardOf("Beta"));
  const b = cardOf("Beta");
  const clock = b?.querySelector(".notif-snooze-peek");
  if (!clock) return [`${at}: SZ4 Beta slid part way shows no clock`];
  const tx = new DOMMatrix(getComputedStyle(b).transform).m41;
  const fails = Math.abs(tx - 64) > 2 ? [`${at}: SZ4 Beta rests ${Math.round(tx)} px out, not 64`] : [];
  const c = clock.getBoundingClientRect();
  if (c.right > b.getBoundingClientRect().left + 1 || c.width < 40) fails.push(`${at}: SZ4 the clock isn't in the room Beta left`);
  clock.click();
  await sleep(100);
  const tomorrow = choice(cardOf("Beta"), "Tomorrow");
  if (!tomorrow) return [...fails, `${at}: SZ4 a tap on the clock didn't open the choices`];
  const now = new Date();
  const want = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 8).getTime() - now.getTime();
  tomorrow.click();
  await sleep(250 + SETTLE_MS);
  const last = host.calls[host.calls.length - 1];
  if (last?.key !== "Beta-sz" || Math.abs(last.ms - want) > 5000) fails.push(`${at}: SZ4 "Tomorrow" asked ${JSON.stringify(last)}, want ~${want} ms`);
  return fails;
}

/** SZ5: a host without snooze - a long press on Gamma shows nothing. */
async function noSnooze(host, at) {
  host.emit(false);
  await sleep(SETTLE_MS);
  if (!cardOf("Gamma")) return [`${at}: SZ5 no Gamma card`];
  await longPress(cardOf("Gamma"));
  return cardOf("Gamma")?.querySelector(".notif-snooze") ? [`${at}: SZ5 Snooze shown by a host without it`] : [];
}

export async function snooze(at) {
  const host = await stubHost();
  try {
    host.emit();
    (await importShim("./state.ts")).notif.value = true;
    await sleep(SETTLE_MS + 100);
    if (!cardOf("Alpha")) return [`${at}: no Alpha card in the open shade`];
    const fails = await menuRefused(host, at);
    if (fails.length) return fails;
    return [...(await menuTaken(host, at)), ...(await peekTomorrow(host, at)), ...(await noSnooze(host, at))];
  } finally {
    host.restore();
  }
}

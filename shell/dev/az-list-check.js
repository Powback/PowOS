/**
 * AZL1 (ask-1a1a3856299 + ask-1a1a385da60, 11-03: "show the list results when using the alphabet so we can see the full
 * app titles with the results centered on the screen", "AS AN EXPERIMENTAL OPTION TOGGLE IN SETTINGS"): the drawer's A-Z
 * bar, scripted pointer events. Off (the default): a scrub shows no list, as before. On (Settings > style >
 * experimental): the letter's apps as rows, centred over the drawer, each name whole (not cut, not ellipsised); sliding
 * off the bar onto a row and lifting opens that app (powos.apps.launch called); lifting on the bar opens nothing.
 */
const g = () => window.__gw;

function bar() {
  return document.querySelector(".drawer-page .letter-bar");
}

/** A pointer event on the bar (captured: every move goes to it wherever the finger is). */
function fire(type, x, y, buttons = 1) {
  bar().dispatchEvent(new PointerEvent(type, { bubbles: true, pointerId: 7, buttons: type === "pointerup" ? 0 : buttons, clientX: x, clientY: y }));
}

/** The middle of [letter] on the bar. */
function at(letter) {
  const s = [...bar().querySelectorAll("span")].find((e) => e.textContent === letter);
  const r = s.getBoundingClientRect();
  return [r.x + r.width / 2, r.y + r.height / 2];
}

/** The letter with the most host apps (the mock's), and how many apps of all kinds are under each letter. */
function busiestLetter(apps) {
  const count = new Map(), host = new Map();
  const add = (m, h) => m.set(h, (m.get(h) ?? 0) + 1);
  for (const a of apps) {
    const h = a.label.trim().normalize("NFD")[0]?.toUpperCase() ?? "";
    if (h < "A" || h > "Z") continue;
    add(count, h);
    if (!a.key.startsWith("p:")) add(host, h);
  }
  return { letter: [...host].sort((a, b) => b[1] - a[1])[0][0], count };
}

/** Off: a scrub is as before - the bubble, no list. */
async function offScene(D, letter, fails) {
  D.azList.value = "";
  await g().frames(2);
  const [x, y] = at(letter);
  fire("pointerdown", x, y);
  await g().sleep(300);
  if (document.querySelector(".az-list")) fails.push("AZL1: with the experimental option off, a scrub showed the A-Z list");
  if (!document.querySelector(".letter-bubble")) fails.push("AZL1: off, the scrub showed no letter bubble (the bar as before)");
  fire("pointerup", x, y);
  await g().sleep(400);
}

/** Each row's name is the app's whole label, not cut or ellipsised. */
function namesWhole(S, rows, fails) {
  for (const r of rows) {
    const n = r.querySelector(".az-list-name");
    const label = S.byKey.value.get(r.dataset.key)?.label;
    if (n.textContent !== label) fails.push(`AZL1: row "${n.textContent}" isn't the app's whole name "${label}"`);
    if (n.scrollWidth > n.clientWidth + 1 || getComputedStyle(n).textOverflow === "ellipsis") fails.push(`AZL1: "${label}" is cut (scrollWidth ${n.scrollWidth} > ${n.clientWidth})`);
  }
}

/** On: the letter's rows, centred over the drawer page; a lift on the bar opens nothing and the list fades out. */
async function listScene({ S, letter, want, launched, fails, notes }) {
  const [x, y] = at(letter);
  fire("pointerdown", x, y);
  await g().sleep(400);
  const card = document.querySelector(".az-list .az-list-card");
  const rows = [...document.querySelectorAll(".az-list-row")];
  if (!card) fails.push(`AZL1: on, scrubbing to ${letter} showed no list`);
  else {
    if (rows.length !== want) fails.push(`AZL1: ${letter}'s list has ${rows.length} rows, want ${want}`);
    const page = document.querySelector(".drawer-page").getBoundingClientRect();
    const c = card.getBoundingClientRect();
    const dy = Math.abs(c.y + c.height / 2 - (page.y + page.height / 2));
    if (dy > 24) fails.push(`AZL1: the list's middle is ${Math.round(dy)} px off the drawer's middle (want centred)`);
    namesWhole(S, rows, fails);
    notes.push(`${letter}: ${rows.length} rows, ${Math.round(c.width)}x${Math.round(c.height)} at ${Math.round(c.y)}`);
  }
  fire("pointerup", x, y);
  await g().frames(1);
  if (!document.querySelector(".az-list.leaving")) fails.push("AZL1: the list left in one frame (want it to fade out)");
  await g().sleep(500);
  if (document.querySelector(".az-list")) fails.push("AZL1: the list stayed after the lift");
  if (launched.length) fails.push(`AZL1: a lift on the bar opened ${launched.join(", ")}`);
}

/** Slide left off the bar, then to a host app's row (a "p:" app opens in this page, not by the bridge); lift: it opens. */
async function liftScene({ letter, launched, fails, notes }) {
  const [x, y] = at(letter);
  fire("pointerdown", x, y);
  await g().sleep(400);
  const hostRows = [...document.querySelectorAll(".az-list-row")].filter((r) => !r.dataset.key.startsWith("p:"));
  const target = hostRows[Math.min(1, hostRows.length - 1)];
  if (!target) return void fails.push(`AZL1: ${letter} has no host app to lift on`);
  const off = bar().getBoundingClientRect().left - 40;
  const b = target.getBoundingClientRect();
  fire("pointermove", off, y);
  fire("pointermove", off, b.y + b.height / 2);
  await g().frames(2);
  if (!target.classList.contains("on")) fails.push(`AZL1: the row at the finger's height ("${target.dataset.key}") isn't lit`);
  fire("pointerup", off, b.y + b.height / 2);
  await g().sleep(200);
  if (launched[0] !== target.dataset.key) fails.push(`AZL1: lifting on "${target.dataset.key}" launched ${launched[0] ?? "nothing"}`);
  notes.push(`lift on row -> ${launched.join(",") || "nothing"}`);
}

export async function azListScene() {
  const S = await g().mod("./state.ts");
  const D = await g().mod("./ui/drawer.tsx");
  const { powos } = await g().mod("./bridge.ts");
  Element.prototype.setPointerCapture = () => {};
  const launched = [], fails = [], notes = [];
  const was = powos.apps.launch;
  // The user's own choice put back after (on the phone, tools/phone/verify/shell-check.sh: the toggle may be on).
  const listWas = D.azList.value;
  powos.apps.launch = async (k) => void launched.push(k);
  try {
    S.drawer.value = 1;
    await g().sleep(400);
    await g().settled();
    const { letter, count } = busiestLetter(S.apps.value);
    await offScene(D, letter, fails);
    D.azList.value = "on";
    await g().frames(2);
    const t = { S, letter, want: count.get(letter), launched, fails, notes };
    await listScene(t);
    await liftScene(t);
  } finally {
    powos.apps.launch = was;
    D.azList.value = listWas;
    S.drawer.value = 0;
  }
  window.__azList = notes.join("; ");
  return fails;
}

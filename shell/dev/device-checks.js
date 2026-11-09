/**
 * Checks for the PHONE's live page (tools/phone/verify/shell-check.sh inlines this file: no imports - modules through
 * importShim, the gate's helpers through window.__gw). Each returns the gate's answer: [] = PASS, a list of fails, or
 * ["SKIP: <why>"] when what it needs isn't on the phone now. Read only, or put back what it opened.
 */

/** The switcher's state now: the empty message, the background toggle's words, the rows (when opened). */
function switcherNow() {
  const shown = (el) => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden" && Number(getComputedStyle(el).opacity) > 0.5;
  const empty = document.querySelector(".recents-empty");
  const toggle = document.querySelector(".recents-bg-toggle");
  const rows = [...document.querySelectorAll(".recents-bg-app")].map((r) => ({
    key: r.dataset.key,
    name: r.querySelector(".recents-bg-name")?.textContent ?? "",
    icon: !!r.querySelector("img.recents-bg-icon[src]"),
    stop: !!r.querySelector(".recents-bg-stop"),
  }));
  return { empty: shown(empty) ? empty.textContent : "", toggle: shown(toggle) ? toggle.textContent : "", cards: document.querySelectorAll(".recents .card, .recents [data-task]").length, rows };
}

/**
 * The switcher on the phone (board "Switcher: empty state + list background-running apps with a close button", the
 * user 11-03: "I actually do have open apps, they're just running in the background ... like Termux"), opened by the
 * real recents key (switcher-bg.sh): the host's apps.background() names [want] (Termux running with no task); the
 * switcher says "No open apps" when it shows no card; "N running in background" counts the host's list; opened (a
 * click on it), [want]'s row has its icon, its name and a Stop - never pressed here (it would end the user's session).
 */
export async function switcherBackgroundNow(want = "Termux") {
  const { powos } = await window.__gw.mod("./bridge.ts");
  let bg;
  try {
    bg = await powos.apps.background();
  } catch (e) {
    return [`the host has no apps.background: ${e}`];
  }
  const it = bg.find((b) => b.label === want);
  if (!it) return [`SKIP: ${want} isn't running in the background (host lists: ${bg.map((b) => b.label).join(", ") || "none"})`];
  if (!(await window.__gw.until(() => switcherNow().toggle, 5000))) return [`the switcher shows no "running in background" (host lists ${bg.length}): ${JSON.stringify(switcherNow())}`];
  const s = switcherNow();
  const fails = [
    !s.cards && s.empty !== "No open apps" && `no cards but no "No open apps": ${JSON.stringify(s)}`,
    s.toggle !== `${bg.length} running in background` && `the toggle says "${s.toggle}", the host lists ${bg.length}`,
  ].filter(Boolean);
  document.querySelector(".recents-bg-toggle").click();
  await window.__gw.until(() => switcherNow().rows.length > 0, 3000);
  return [...fails, ...bgRowFails(it, want)];
}

/** Opened: [it]'s row there with its name, icon and Stop. */
function bgRowFails(it, want) {
  const rows = switcherNow().rows;
  const row = rows.find((r) => r.key === it.key);
  if (!row) return [`opened: no row for ${want} (${it.key}): ${JSON.stringify(rows)}`];
  return row.name !== want || !row.icon || !row.stop ? [`${want}'s row: ${JSON.stringify(row)} (wants its name, icon and a Stop)`] : [];
}

/** The control center's privacy chips now: each one's app name and its line. */
function privacyChips() {
  return [...document.querySelectorAll(".privacy-row .privacy-chip")].map((c) => ({ app: c.querySelector(".privacy-app")?.textContent ?? "", what: c.querySelector(".privacy-what")?.textContent ?? "" }));
}

/**
 * The control center's privacy row on the phone (board "Control center shows what is using the mic (and camera) right
 * now", the user 11-03: "I should be able to see where my microphone is used in the notification center, like under
 * the control center"), in the shade's page with the panel pulled down (privacy-row.sh). [phase] "idle": the host's
 * privacy.list has nothing active and no chip says "now". "dictating" (PowOS's own dictation started by the script):
 * the host names the mic's holder and a chip names that app with "Microphone · now".
 */
export async function privacyRowNow(phase) {
  const { powos } = await window.__gw.mod("./bridge.ts");
  const list = (await powos.privacy.list())?.items ?? [];
  const active = list.filter((u) => u.active);
  await window.__gw.settled(() => true, ".notif-panel");
  const chips = privacyChips();
  if (phase === "idle") {
    if (active.length) return [`SKIP: in use now, not idle: ${active.map((u) => `${u.app} (${u.kinds})`).join(", ")}`];
    const now = chips.filter((c) => /· now/.test(c.what));
    return now.length ? [`idle: chips still say "now": ${JSON.stringify(now)}`] : [];
  }
  const mic = active.find((u) => u.kinds.includes("mic"));
  if (!mic) return [`dictating: the host's privacy.list names no mic holder: ${JSON.stringify(list)}`];
  if (!(await window.__gw.until(() => privacyChips().some((c) => c.app === mic.app && /Microphone/.test(c.what) && /now/.test(c.what)), 4000)))
    return [`dictating: no chip "${mic.app} · Microphone · now" in the control center: ${JSON.stringify(privacyChips())}`];
  return [];
}

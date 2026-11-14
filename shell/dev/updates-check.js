// Settings' "system updates" on a phone (ui/screens.tsx Updates, upgrade/PowosUpdates.kt; the owner, 11-14: "theres no
// setting like that [update] on the razr launcher"). Pinned, on the mock host (screens-mock.ts: a PowOS phone's card,
// ?updates=rooted a rooted one's):
//  - the launcher's search finds "Check for updates" by "update", and opening it lands on Settings with the card at
//    the top of the page, on screen, its check button focused and highlighted;
//  - the card says what the phone's updater keeps current: the app's version, the home screen's commit;
//  - its tap reads as "checking…" at once (before the host answers), asks the host's settings.check, then shows the
//    run's result;
//  - rooted: the card is there and says the ship service updates the phone, with no check button (no app run there).
const G = () => window.__gw;
const ID = "settings:settings:system updates/check for updates";

function onScreen(el) {
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.top >= 0 && r.bottom <= innerHeight && r.left >= 0 && r.right <= innerWidth;
}

export async function updatesFails(label, rooted) {
  const fails = [];
  const f = (ok, why) => ok || fails.push(`${label}: ${why}`);
  const s = await G().mod("./state.ts");
  const screens = await G().mod("./screens.ts");
  try {
    const card = await openFromSearch(f, s, screens, rooted ? "system updates" : "check for updates");
    if (card) await (rooted ? rootedCard(f, card) : checkTap(f, card));
  } catch (e) {
    fails.push(`${label}: ${e}`);
  } finally {
    s.query.value = "";
    screens.closeScreens();
    s.drawer.value = 0;
  }
  return fails;
}

/** "update" in the launcher -> Check for updates -> Settings, [want] focused and highlighted; the card, or null. */
async function openFromSearch(f, s, screens, want) {
  s.drawer.value = 1;
  s.query.value = "update";
  const row = () => document.querySelector(`[data-search-result="${ID}"]`);
  if (!(await G().until(() => row(), 5000))) {
    const shown = [...document.querySelectorAll("[data-search-result]")].map((e) => e.dataset.searchResult);
    return f(false, `"update" in the launcher finds no Check for updates (results: ${shown.join(", ")})`), null;
  }
  f(/Check for updates/.test(row().textContent ?? ""), `the result reads "${row().textContent}"`);
  row().click();
  const opened = await G().until(() => document.activeElement?.dataset.setting === want, 5000);
  f(opened, `opening it focused ${document.activeElement?.dataset.setting ?? document.activeElement?.tagName}, not "${want}"`);
  f(screens.screens.value.at(-1) === "settings", `it opened ${screens.screens.value.join(" › ")}, not settings`);
  f(document.activeElement?.dataset.searchHighlight === "true", "the opened setting isn't highlighted");
  const card = document.querySelector('.scr [data-setting="system updates"]');
  if (!card) return f(false, "Settings has no system updates card"), null;
  f(card.closest(".scr-body")?.querySelector(".scr-card, .scr-grid") === card, "the card isn't the first thing on Settings");
  f(onScreen(card), "the card is off screen");
  f(/app 0\.1\.0-dev/.test(card.textContent) && /home screen 0123abcde/.test(card.textContent), `the card doesn't say what runs: "${card.textContent}"`);
  return card;
}

/** Rooted: the ship service updates it, no check button. */
function rootedCard(f, card) {
  f(/ship service/.test(card.textContent), `rooted: the card doesn't say the ship service updates it: "${card.textContent}"`);
  f(!card.querySelector('[data-setting="check for updates"]'), "rooted: a check button for a run the app doesn't make");
}

/** The tap: "checking…" at once, the host asked, then the run's result. */
async function checkTap(f, card) {
  const text = () => card.textContent ?? "";
  const button = card.querySelector('[data-setting="check for updates"]');
  if (!button) return f(false, `no check for updates button: "${text()}"`);
  f(/up to date/.test(text()), `before the check: "${text()}"`);
  button.click();
  await G().frames(2);
  f(/checking…/.test(text()), `a tap shows no "checking…" at once: "${text()}"`);
  f((window.__updatesAsked ?? []).includes("check"), "the tap didn't ask the host (settings.check)");
  f(await G().until(() => /Updated: the home screen/.test(text()), 5000), `the run's result never showed: "${text()}"`);
}

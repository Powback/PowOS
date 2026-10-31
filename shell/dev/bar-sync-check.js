/**
 * SI1 (the user, 2026-10-31 01:16: "The text inside the search widget and the launcher should be the same"): home's bar
 * and the launcher overlay's are one input (ui/barsync.ts). Runs from gate.mjs ("bar-sync") over two pages - home
 * (index.html) and the overlay's (index.html?mode=pull) - whose mock bridges are joined as ShellBridge joins the
 * windows: each page's bar.publish goes to the other as "bar.input" (window.__barRelay). Node-side: [home], [pull] are
 * puppeteer pages. Checks:
 *  1. text typed in home shows in the launcher's field;
 *  2. a dictation in home: its partial words show in the launcher's field (and its send), the final text after;
 *  3. send in the launcher clears both;
 *  4. send in the launcher while home dictates: both empty, home's dictation ended, its words never written back.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const HOME = ".home > .bar";
const PULL = ".pull-screen > .bar";

/** Joins the two pages' mock bridges: a publish in one is the other's "bar.input". */
export async function joinPages(home, pull) {
  const to = (page) => (v) => page.evaluate((x) => window.__mockEvents.emit("bar.input", x), v).catch(() => {});
  await home.exposeFunction("__barRelay", to(pull));
  await pull.exposeFunction("__barRelay", to(home));
}

const field = (page, form) => page.evaluate((f) => document.querySelector(`${f} textarea`)?.value ?? null, form);
const query = (page) => page.evaluate(async () => (await importShim("./state.ts")).query.value);

async function waitFor(fails, what, f, ms = 3000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(40)) if (await f()) return true;
  fails.push(`timed out: ${what}`);
  return false;
}

/** A tap on home's bar mic: a tap's dictation (the mock hears "how much battery is left", then ends by itself). */
const tapHomeMic = (home, hold = false) =>
  home.evaluate(async (f, hold) => {
    const { powos } = await importShim("./bridge.ts");
    const mic = document.querySelector(`${f} .mic`);
    Element.prototype.setPointerCapture = () => {};
    // A held recognizer (no end of its own) for step 4: the launcher's send ends it, not its silence.
    if (hold && !powos.speech.__orig) (powos.speech.__orig = powos.speech.start), (powos.speech.start = () => powos.speech.__orig(true));
    const at = { bubbles: true, pointerId: 1, isPrimary: true };
    mic.dispatchEvent(new PointerEvent("pointerdown", at));
    mic.dispatchEvent(new PointerEvent("pointerup", at));
  }, HOME, hold);

const homeMicOn = (home) => home.evaluate((f) => !!document.querySelector(`${f} .mic.on`), HOME);
const submitPull = (pull) => pull.evaluate((f) => document.querySelector(f).requestSubmit(), PULL);

export async function barSyncCheck(home, pull) {
  const fails = [];
  await home.waitForSelector(`${HOME} .mic`);
  await pull.waitForSelector(`${PULL} textarea`);
  await pull.evaluate(async () => ((await importShim("./state.ts")).drawer.value = 1));
  // 1. Typed in home (its bar's query, as its onInput writes it): the launcher's field shows it.
  await home.evaluate(async () => ((await importShim("./state.ts")).query.value = "weather"));
  await waitFor(fails, "home's typed 'weather' in the launcher's field", async () => (await field(pull, PULL)) === "weather");
  // 2. A dictation in home: its partial in the launcher's field while it listens, its send shown; the final text after.
  await tapHomeMic(home);
  await waitFor(fails, "home's dictation partial in the launcher's field", async () => {
    const v = await field(pull, PULL);
    return (await homeMicOn(home)) && /^weather how( much)?$/.test(v ?? "");
  });
  if (!(await pull.evaluate((f) => !!document.querySelector(`${f} .send.shown`), PULL))) fails.push("the launcher's send hidden while home dictates");
  await waitFor(fails, "home's final words in the launcher's field", async () => (await field(pull, PULL)) === "weather how much battery is left" && !(await homeMicOn(home)));
  // 3. Send in the launcher: both empty.
  await submitPull(pull);
  await waitFor(fails, "send in the launcher clears both", async () => (await query(pull)) === "" && (await query(home)) === "" && (await field(home, HOME)) === "");
  // 4. Send in the launcher while home still dictates (a held recognizer): both empty, home's dictation over, and its
  //    words never come back into either field.
  await home.evaluate(async () => ((await importShim("./state.ts")).query.value = "note"));
  await waitFor(fails, "home's 'note' in the launcher's field", async () => (await field(pull, PULL)) === "note");
  await tapHomeMic(home, true);
  await waitFor(fails, "home's held dictation partial in the launcher", async () => /^note how/.test((await field(pull, PULL)) ?? ""));
  await submitPull(pull);
  await waitFor(fails, "send mid-dictation clears both and ends home's dictation", async () => (await query(pull)) === "" && (await query(home)) === "" && !(await homeMicOn(home)));
  await sleep(800);
  const after = [await query(home), await query(pull)];
  if (after.some((v) => v !== "")) fails.push(`dictation words written back after the send: home=${JSON.stringify(after[0])} launcher=${JSON.stringify(after[1])}`);
  return fails;
}

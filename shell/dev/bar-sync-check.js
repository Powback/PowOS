/**
 * SI1 (the user, 2026-10-31 01:16: "The text inside the search widget and the launcher should be the same"): home's bar
 * and the launcher overlay's are one input (ui/barsync.ts). Runs from gate.mjs ("bar-sync") over two pages - home
 * (index.html) and the overlay's (index.html?mode=pull) - joined through ONE host here in node that keeps the bar as
 * ShellBridge does (an older generation refused, every kept write numbered, sent to the other page as "bar.input").
 * Adversarial on purpose: home's writes reach the host HOME_LAG ms late, so a send in the launcher lands before home's
 * last dictation words (the 2026-10-31 race: they came back after the send). Every wait is on state, never a sleep.
 * Node-side: [home], [pull] are puppeteer pages. Checks:
 *  1. text typed in home shows in the launcher's field;
 *  2. a dictation in home: its words show in the launcher's field while it listens (and its send), the final text after;
 *  3. send in the launcher clears both;
 *  4. send in the launcher while home dictates: both empty, home's dictation ended, its words never written back;
 *  5. SB5: with text the pill's leading glyph is an × button (40 px); tapped in the launcher, both fields empty and
 *     the glyph is `>` again;
 *  6. SB5: × tapped in home while it dictates: both empty, the dictation ended, its words never written back.
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const HOME = ".home > .bar";
const PULL = ".pull-screen > .bar";
const HOME_LAG = 60;

/** The one host both pages' mock bridges use (bridge.ts mockBar -> window.__barHost). */
export async function joinPages(home, pull) {
  const host = { v: null, busy: 0 };
  const deliver = (page, v) => page.evaluate((x) => window.__mockEvents.emit("bar.input", x), v).catch(() => {});
  const serve = (self, other, lag) => async (op, next) => {
    host.busy++;
    try {
      if (lag) await sleep(lag);
      if (op === "get") return host.v;
      if (host.v && next.gen < host.v.gen) return host.v;
      host.v = { text: next.text, hearing: !!next.hearing, gen: next.gen, seq: (host.v?.seq ?? 0) + 1 };
      await deliver(other, host.v);
      return host.v;
    } finally {
      host.busy--;
    }
  };
  await home.exposeFunction("__barHost", serve(home, pull, HOME_LAG));
  await pull.exposeFunction("__barHost", serve(pull, home, 0));
  return host;
}

const field = (page, form) => page.evaluate((f) => document.querySelector(`${f} textarea`)?.value ?? null, form);
const query = (page) => page.evaluate(async () => (await importShim("./state.ts")).query.value);

async function waitFor(fails, what, f, ms = 4000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(30)) if (await f()) return true;
  fails.push(`timed out: ${what}`);
  return false;
}

/** A tap on home's bar mic, its recognizer a held one (no end of its own: it stops only when told, never on a timer). */
const tapHomeMic = (home) =>
  home.evaluate(async (f) => {
    const { powos } = await importShim("./bridge.ts");
    Element.prototype.setPointerCapture = () => {};
    if (!powos.speech.__orig) (powos.speech.__orig = powos.speech.start), (powos.speech.start = () => powos.speech.__orig(true));
    const mic = document.querySelector(`${f} .mic`);
    const at = { bubbles: true, pointerId: 1, isPrimary: true };
    mic.dispatchEvent(new PointerEvent("pointerdown", at));
    mic.dispatchEvent(new PointerEvent("pointerup", at));
  }, HOME);

const homeMicOn = (home) => home.evaluate((f) => !!document.querySelector(`${f} .mic.on`), HOME);
/** The mock recognizer has heard all its words ("how much battery is left") and is still open. */
const heardAll = (home) => home.evaluate(() => window.__speechMock.open === 1 && document.querySelector(".home > .bar textarea")?.value.endsWith("battery is left"));
const micClosed = (home) => home.evaluate(() => window.__speechMock.open === 0);
const submitPull = (pull) => pull.evaluate((f) => document.querySelector(f).requestSubmit(), PULL);
/** SB5: the pill's leading slot in [form]: filled (an × to tap), its box, and which glyph shows. */
const lead = (page, form) =>
  page.evaluate((f) => {
    const b = document.querySelector(`${f} .pill .lead`);
    if (!b) return null;
    const r = b.getBoundingClientRect();
    const op = (sel) => Number(getComputedStyle(b.querySelector(sel)).opacity);
    return { filled: b.classList.contains("filled"), w: r.width, h: r.height, x: op(".x"), prompt: op(".prompt") };
  }, form);
/** The launcher's pill as it shows ([name]: "x" with text, "empty"), for a look (/cache: ~/.cache/powos-gate/tx). */
const shot = async (page, name) => (await page.$(`${PULL} .pill`))?.screenshot({ path: `/cache/bar-clear-${name}.png` }).catch(() => {});
const tapClear = (page, form) => page.evaluate((f) => document.querySelector(`${f} .pill .lead`).click(), form);
const setQuery = (page, v) => page.evaluate(async (x) => ((await importShim("./state.ts")).query.value = x), v);

export async function barSyncCheck(home, pull, host) {
  const fails = [];
  await home.waitForSelector(`${HOME} .mic`);
  await pull.waitForSelector(`${PULL} textarea`);
  await pull.evaluate(async () => ((await importShim("./state.ts")).drawer.value = 1));
  // 1. Typed in home (its bar's query, as its onInput writes it): the launcher's field shows it.
  await setQuery(home, "weather");
  await waitFor(fails, "home's typed 'weather' in the launcher's field", async () => (await field(pull, PULL)) === "weather");
  // 2. A dictation in home: its words in the launcher's field while it listens, its send shown; the final text after.
  await tapHomeMic(home);
  await waitFor(fails, "home's dictation words in the launcher's field", async () => (await homeMicOn(home)) && (await field(pull, PULL)) === "weather how much battery is left");
  if (!(await pull.evaluate((f) => !!document.querySelector(`${f} .send.shown`), PULL))) fails.push("the launcher's send hidden while home dictates");
  await home.evaluate(async () => (await importShim("./bridge.ts")).powos.speech.stop());
  await waitFor(fails, "home's dictation over, its words in both fields", async () => !(await homeMicOn(home)) && (await query(home)) === "weather how much battery is left" && (await field(pull, PULL)) === "weather how much battery is left");
  // 3. Send in the launcher: both empty.
  await submitPull(pull);
  await waitFor(fails, "send in the launcher clears both", async () => host.busy === 0 && (await query(pull)) === "" && (await query(home)) === "" && (await field(home, HOME)) === "");
  // 4. Send in the launcher while home still dictates: both empty, home's dictation over, its words never back - home's
  //    last words reach the host after the send (HOME_LAG), and the final words come once the mic is told to stop.
  await setQuery(home, "note");
  await waitFor(fails, "home's 'note' in the launcher's field", async () => (await field(pull, PULL)) === "note");
  await tapHomeMic(home);
  await waitFor(fails, "home's dictation heard all its words", () => heardAll(home));
  await submitPull(pull);
  await waitFor(fails, "send mid-dictation ends home's dictation", async () => !(await homeMicOn(home)) && (await micClosed(home)));
  await waitFor(fails, "send mid-dictation: both empty, nothing in flight", async () => host.busy === 0 && (await query(pull)) === "" && (await query(home)) === "");
  const after = [await query(home), await query(pull), host.v?.text];
  if (after.some((v) => v !== "")) fails.push(`dictation words written back after the send: home=${JSON.stringify(after[0])} launcher=${JSON.stringify(after[1])} host=${JSON.stringify(after[2])}`);
  return [...fails, ...(await clearCheck(home, pull, host))];
}

/** SB5 (the user, 2026-10-31 02:46: "we should have an x to clear on the left side of the inputs"): checks 5 and 6. */
async function clearCheck(home, pull, host) {
  const fails = [];
  // 5. SB5: text in the launcher: its leading glyph an × button; tapped, both fields empty, the glyph `>` again.
  await setQuery(pull, "maps");
  await waitFor(fails, "'maps' in home's field", async () => (await field(home, HOME)) === "maps");
  await waitFor(fails, "the launcher's leading glyph is an × with text", async () => {
    const l = await lead(pull, PULL);
    return l?.filled && l.x > 0.99 && l.prompt < 0.01;
  });
  await shot(pull, "x");
  const box = await lead(pull, PULL);
  if (box && (box.w < 40 || box.h < 40)) fails.push(`the clear button is ${box.w}x${box.h}, under 40 px`);
  await tapClear(pull, PULL);
  await waitFor(fails, "× in the launcher clears both", async () => host.busy === 0 && (await field(pull, PULL)) === "" && (await query(home)) === "" && (await field(home, HOME)) === "");
  await waitFor(fails, "the launcher's glyph back to `>` once empty", async () => {
    const l = await lead(pull, PULL);
    return l && !l.filled && l.prompt > 0.99 && l.x < 0.01;
  });
  await shot(pull, "empty");
  // 6. SB5: × in home while it dictates: the dictation ends, both empty, its words never back.
  await setQuery(home, "call");
  await waitFor(fails, "home's 'call' in the launcher's field", async () => (await field(pull, PULL)) === "call");
  await tapHomeMic(home);
  await waitFor(fails, "home's dictation heard all its words (for ×)", () => heardAll(home));
  await tapClear(home, HOME);
  await waitFor(fails, "× mid-dictation ends home's dictation", async () => !(await homeMicOn(home)) && (await micClosed(home)));
  await waitFor(fails, "× mid-dictation: both empty, nothing in flight", async () => host.busy === 0 && (await query(pull)) === "" && (await query(home)) === "" && (await field(home, HOME)) === "");
  const cleared = [await query(home), await query(pull), host.v?.text];
  if (cleared.some((v) => v !== "")) fails.push(`dictation words written back after ×: home=${JSON.stringify(cleared[0])} launcher=${JSON.stringify(cleared[1])} host=${JSON.stringify(cleared[2])}`);
  if ((await lead(home, HOME))?.filled) fails.push("home's glyph still an × once cleared");
  return fails;
}

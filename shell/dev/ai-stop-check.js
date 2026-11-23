/**
 * The stop button (board ai-chat-send-button-becomes-a-stop-button-while; the user, 11-23: the send control becomes
 * STOP while the assistant answers, "pretty natively like the way the send button works"). Runs in the page against
 * the mock bridge (its "long" ask answers for 30 s and takes ai.stop), in every pill that asks PowOS AI:
 *   aiStopStart(form): the pure state machine (assistant.ts stopShown), then a long ask sent -> the send turns into
 *     stop within 100 ms (optimistic: before the turn's first word), labelled for screen readers; typing turns it back
 *     into send (a message would queue), emptying the field brings stop back.
 *   aiStopEnd(form): stop tapped -> send again within 100 ms, the turn ends (busy false), the partial answer stays,
 *     "stopped" follows (not an error), no step left running, and the button is gone (nothing to send).
 * [form]: ".bar" (home's / the launcher's / PowOS AI's one bar) or ".assist-ask" (the side button's overlay).
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(f, ms) {
  const t0 = Date.now();
  while (!f() && Date.now() - t0 < ms) await sleep(10);
  return f();
}
function typeInto(field, text) {
  field.focus();
  field.value = text;
  field.dispatchEvent(new InputEvent("input", { bubbles: true, data: text, inputType: "insertText" }));
}

/** The page's state machine, case by case (no DOM): when the pill's button is stop. */
export async function stopStateCases() {
  const { stopShown } = await importShim("./ui/assistant.ts");
  const now = 100000;
  const fails = [];
  const cases = [
    ["idle", { busy: false, stoppable: true }, 0, 0, false],
    ["answering", { busy: true, stoppable: true }, 0, 0, true],
    ["an older host (no ai.stop)", { busy: true }, 0, 0, false],
    ["just sent, busy not here yet", { busy: false, stoppable: true }, now - 50, 0, true],
    ["sent long ago, never busy", { busy: false, stoppable: true }, now - 5000, 0, false],
    ["tapped, the host stopping", { busy: true, stoppable: true, stopping: true }, 0, now - 50, false],
    ["tapped, the host not told yet", { busy: true, stoppable: true }, 0, now - 50, false],
    ["tapped 11 s ago, still running, not stopping: back", { busy: true, stoppable: true }, 0, now - 11000, true],
    ["tapped, stopping a long time", { busy: true, stoppable: true, stopping: true }, 0, now - 11000, false],
    ["tapped, ended", { busy: false, stoppable: true }, 0, now - 50, false],
  ];
  for (const [name, c, sent, stop, want] of cases) {
    const got = stopShown(c, now, sent, stop);
    if (got !== want) fails.push(`stopShown ${name}: ${got}, want ${want}`);
  }
  return fails;
}

/** [msg] onto [fails] unless [ok]. */
const want = (fails, ok, msg) => void (ok || fails.push(msg));
const longStarted = (S) => S.chat.value.items.some((i) => i.kind === "assistant" && i.text.includes("start of a long answer"));

/** The pill idle: the summoning's dictation (assist) and any turn over. */
async function settled(el, S) {
  const mic = el.querySelector(".mic");
  await until(() => !mic.classList.contains("on"), 5000);
  await until(() => !S.chat.value.busy, 5000);
  await sleep(300);
}

/** The stop button as it should be: labelled, a plain button (never the form's submit), enabled, an icon, 40 px. */
function stopLooksRight(form, b) {
  const fails = [];
  want(fails, b.getAttribute("aria-label") === "stop answering", `${form}: stop's label is "${b.getAttribute("aria-label")}"`);
  want(fails, b.type === "button", `${form}: stop is a ${b.type} button (it would submit the form)`);
  want(fails, !b.disabled && !!b.querySelector("svg"), `${form}: stop is disabled or has no icon`);
  const w = b.getBoundingClientRect().width;
  want(fails, w >= 36, `${form}: stop is ${w}px wide`);
  return fails;
}

export async function aiStopStart(form) {
  const fails = await stopStateCases();
  const S = await importShim("./state.ts");
  const el = document.querySelector(`form${form}`);
  if (!el) return [...fails, `${form}: no such form`];
  await settled(el, S);
  const field = el.querySelector("textarea");
  const btn = () => el.querySelector(".send");
  const isStop = () => !!btn()?.classList.contains("stop");
  typeInto(field, "write me a long essay about the fold");
  await sleep(50);
  const t0 = performance.now();
  btn().click();
  if (!(await until(isStop, 100))) return [...fails, `${form}: no stop button within 100 ms of the send (${(performance.now() - t0).toFixed(0)} ms)`];
  want(fails, await until(() => longStarted(S), 3000), `${form}: the long answer never started`);
  fails.push(...stopLooksRight(form, btn()));
  // Typed mid-answer: send (it would queue); emptied: stop again.
  typeInto(field, "and one more thing");
  await sleep(50);
  want(fails, !isStop() && btn()?.classList.contains("shown"), `${form}: typed mid-answer, the button isn't send`);
  typeInto(field, "");
  await sleep(50);
  want(fails, isStop(), `${form}: emptied mid-answer, stop didn't come back`);
  field.blur();
  return fails;
}

/** After the stop: the partial answer kept, a quiet "stopped" last, nothing sent, no step left running. */
function stoppedRight(form, items, asked) {
  const fails = [];
  const last = items.at(-1);
  want(fails, items.filter((i) => i.kind === "user").length === asked, `${form}: the stop tap sent a message`);
  want(fails, items.some((i) => i.kind === "assistant" && i.text.includes("start of a long answer")), `${form}: the partial answer is gone`);
  want(fails, last?.kind === "note" && last.text === "stopped" && !last.error, `${form}: last item ${JSON.stringify(last)}, not a quiet "stopped"`);
  want(fails, !items.some((i) => i.kind === "tool" && i.ok == null), `${form}: a step is left running`);
  return fails;
}

export async function aiStopEnd(form) {
  const S = await importShim("./state.ts");
  const el = document.querySelector(`form${form}`);
  const btn = () => el.querySelector(".send");
  const fails = [];
  const asked = S.chat.value.items.filter((i) => i.kind === "user").length;
  const t0 = performance.now();
  btn().click();
  const back = await until(() => !btn()?.classList.contains("stop"), 100);
  want(fails, back, `${form}: stop still showing ${(performance.now() - t0).toFixed(0)} ms after the tap`);
  if (!(await until(() => !S.chat.value.busy, 5000))) return [...fails, `${form}: the turn didn't end after stop`];
  await sleep(150);
  fails.push(...stoppedRight(form, S.chat.value.items, asked));
  const shown = btn()?.classList.contains("stop") || btn()?.classList.contains("shown");
  want(fails, !shown, `${form}: the button shows with nothing to send or stop`);
  return fails;
}

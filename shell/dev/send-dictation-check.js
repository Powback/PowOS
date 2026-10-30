/**
 * SB3 (the user, 2026-10-30: "I can't press send like it doesn't disable the transcription and then send"): send
 * tapped while a pill dictates. Runs in the page (gate.mjs "send-dictation-*"), against the mock bridge: a tap on the
 * mic starts a dictation (the mock's start made a hold's, so it never ends by itself), a partial lands, send is tapped
 * -> the mock's stop is called once, the spinner shows while its final words are on their way (stop answers late, as
 * a real recognizer's final result does), then the chat gets the final text once and the mic is off.
 * [form]: the pill's form (".bar", ".ai-compose", ".assist-ask"). In two steps, so the gate renders the spinner between
 * them: sendDictationStart (up to the tap on send) and sendDictationEnd (the send's result).
 */
export async function sendDictationStart(form) {
  const { powos } = await importShim("./bridge.ts");
  const S = await importShim("./state.ts");
  const fails = [];
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const wait = async (what, f, ms = 3000) => {
    for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(30)) if (f()) return true;
    fails.push(`${form}: timed out waiting for ${what}`);
    return false;
  };
  const el = document.querySelector(`form${form}`);
  if (!el) return [`${form}: no such form`];
  const mic = el.querySelector(".mic");
  const send = () => el.querySelector(".send");
  const FINAL = "how much battery is left";
  // The assist's summoning dictates (and sends) by itself as it opens: that one ends first.
  await wait("the summoning's dictation to end", () => !mic.classList.contains("on"), 5000);
  await sleep(400);
  const asked = () => (S.chat.value.items ?? []).filter((i) => i.kind === "user").map((i) => i.text.split("\n\n")[0]);
  const before = asked().length;
  const sp = powos.speech;
  const orig = { start: sp.start, stop: sp.stop, capture: Element.prototype.setPointerCapture };
  let stops = 0;
  // A hold's recognizer (no end of its own) and a late final result: the send must wait for it, not take the partial.
  sp.start = () => orig.start(true);
  // 1.2 s: inside finish's 3 s, long enough for the gate to render the spinner.
  sp.stop = () => (stops++, sleep(1200).then(() => orig.stop()));
  // A synthetic pointer has no capture to set (a real finger does).
  Element.prototype.setPointerCapture = () => {};
  const restore = () => {
    Object.assign(sp, { start: orig.start, stop: orig.stop });
    Element.prototype.setPointerCapture = orig.capture;
  };
  window.__sd = { fails, wait, sleep, asked, before, send, mic, FINAL, restore, stops: () => stops };
  try {
    const at = { bubbles: true, pointerId: 1, isPrimary: true };
    mic.dispatchEvent(new PointerEvent("pointerdown", at));
    mic.dispatchEvent(new PointerEvent("pointerup", at));
    if (!(await wait("the mic to listen", () => mic.classList.contains("on")))) return (restore(), fails);
    if (!send()?.classList.contains("shown")) fails.push(`${form}: send hidden while dictating (before any words)`);
    const field = el.querySelector("textarea");
    if (!(await wait("a partial", () => field.value.trim() && field.value.trim() !== FINAL && field.value.includes("how")))) return (restore(), fails);
    const partial = field.value.trim();
    send().click();
    await wait("the spinner", () => send()?.classList.contains("waiting"), 300);
    // A second tap while waiting: still one send.
    send()?.click();
    window.__sd.partial = partial;
  } catch (e) {
    restore();
    throw e;
  }
  return fails;
}

export async function sendDictationEnd(form) {
  const { fails, wait, sleep, asked, before, send, mic, FINAL, restore, stops: count, partial } = window.__sd;
  try {
    await wait("the send", () => asked().length > before);
    await sleep(200);
    const got = asked().slice(before);
    const stops = count();
    if (stops !== 1) fails.push(`${form}: the recognizer's stop called ${stops} times, not once`);
    if (got.length !== 1) fails.push(`${form}: sent ${got.length} times (${JSON.stringify(got)}), not once`);
    else if (got[0] !== FINAL) fails.push(`${form}: sent "${got[0]}", not the final "${FINAL}" (partial was "${partial}")`);
    if (mic.classList.contains("on")) fails.push(`${form}: the mic is still on after send`);
    if (send()?.classList.contains("waiting")) fails.push(`${form}: the spinner stayed`);
  } finally {
    restore();
  }
  return fails;
}

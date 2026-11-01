/**
 * AO3 (the user, 2026-10-31 00:10: "I'm starting two microphone conversations or something"): one dictation in the
 * app at a time. Runs in the page (gate.mjs "mic-one-*") against the mock bridge, whose speech keeps the native rule
 * (one session, a start ends the one before it) and counts it (window.__speechMock):
 *  1. start -> start (two targets, then the same one twice): exactly one session open, the first superseded.
 *  2. another window's dictation has the mic (speech.state elsewhere, as home's under the launcher overlay): the mic
 *     here shows on, and a tap on it ends that one (speech.stop) - never a second start (2026-10-31 00:11:12).
 *  3. this page's dictation superseded by another window (speech.cancelled): nothing left pending, the mic off.
 *  4. a stale "listening" with nothing pending doesn't refuse a new dictation (the side button's summoning).
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const target = (name) => ({ name, got: [], typed: () => "", heard(full, send) { this.got.push([full, send]); } });

export async function micOneCheck(form) {
  const D = await importShim("./ui/dictation.ts");
  const { powos } = await importShim("./bridge.ts");
  const m = window.__speechMock;
  if (!m) return ["no __speechMock (the mock bridge's speech)"];
  // The summoning's own dictation (assist) and any other: gone first.
  D.interrupt();
  await sleep(50);
  const reset = () => Object.assign(m, { starts: 0, stops: 0, cancels: 0, superseded: 0, maxOpen: m.open });
  const fails = [];
  const ctx = { D, powos, m, reset, fails, form };
  for (const step of [startStart, elsewhereTap, superseded, staleListening, startsReliably, busyRetry, hiddenGrace]) await step(ctx);
  return fails;
}

/** 1. start -> start: one open, the first superseded; the same target again starts nothing. */
async function startStart({ D, m, reset, fails }) {
  reset();
  const a = target("a");
  const b = target("b");
  await D.listen(true, a);
  await D.listen(true, b);
  if (m.starts !== 2) fails.push(`start->start: ${m.starts} starts, want 2`);
  if (m.open !== 1 || m.maxOpen !== 1) fails.push(`start->start: ${m.open} open (max ${m.maxOpen}), want exactly 1`);
  if (m.superseded !== 1) fails.push(`start->start: ${m.superseded} superseded, want 1`);
  if (D.listeningFor(a) || !D.listeningFor(b)) fails.push("start->start: the second target doesn't own the dictation");
  const before = m.starts;
  D.dictate(b);
  if (m.starts !== before) fails.push("dictate on the target already listening started another session");
  D.interrupt();
  await sleep(50);
  if (m.open !== 0) fails.push(`after interrupt: ${m.open} open, want 0`);
}

/** A tap (down, up) on [el], with no pointer capture to set (a synthetic pointer has none). */
function tap(el) {
  const capture = Element.prototype.setPointerCapture;
  Element.prototype.setPointerCapture = () => {};
  try {
    for (const type of ["pointerdown", "pointerup"]) el.dispatchEvent(new PointerEvent(type, { bubbles: true, pointerId: 7, clientX: 1, clientY: 1 }));
  } finally {
    Element.prototype.setPointerCapture = capture;
  }
}

/** 2. Another window has the mic: the mic here shows it, and a tap ends it - starting nothing. */
async function elsewhereTap({ m, reset, fails, form }) {
  const el = document.querySelector(`form${form} .mic`);
  if (!el) return void fails.push(`${form}: no mic`);
  reset();
  const state = (elsewhere) => window.__mockEvents.emit("speech.state", { listening: false, text: "", error: null, elsewhere });
  state(true);
  await sleep(50);
  if (!el.classList.contains("on")) fails.push("elsewhere: the mic doesn't show the other window's dictation");
  tap(el);
  await sleep(50);
  if (m.starts !== 0) fails.push(`elsewhere: a tap started ${m.starts} session(s) - a second dictation`);
  if (m.stops !== 1) fails.push(`elsewhere: a tap called stop ${m.stops} times, want 1`);
  state(false);
}

/** 3. Superseded from another window (speech.cancelled): nothing pending, the mic off, nothing sent. */
async function superseded({ D, powos, fails }) {
  const c = target("c");
  await D.listen(true, c);
  window.__mockEvents.emit("speech.cancelled", { why: "superseded" });
  await sleep(20);
  if (D.listeningFor(c)) fails.push("superseded: still pending here");
  if (D.speech.value.listening) fails.push("superseded: still shows listening");
  if (c.got.some(([, send]) => send)) fails.push("superseded: its words were sent");
  powos.speech.cancel();
}

/** 4. A stale "listening" with nothing pending doesn't refuse a new dictation. */
async function staleListening({ D, m, reset, fails }) {
  reset();
  D.speech.value = { listening: true, text: "", error: null };
  const d = target("d");
  D.dictate(d);
  await sleep(20);
  if (m.starts !== 1 || !D.listeningFor(d)) fails.push("a stale listening refused a new dictation");
  if (m.maxOpen > 1) fails.push(`stale listening: ${m.maxOpen} open at once`);
  D.interrupt();
}

/**
 * VS1 (the user 2026-11-01 18:26: "it activates and then instantly deactivates"): 20 starts in a row from every entry
 * (the side button's summoning dictate(send), the bar's mic listen, the dock's hold listen(true), the pet's dictate),
 * each followed at once by a second start from the same entry: every one still listening after the double start, one
 * session, nothing superseded by its own second start.
 */
async function startsReliably({ D, m, reset, fails }) {
  const entries = {
    assist: (t) => (D.dictate(t, true), D.makeHold(t), D.dictate(t, true)),
    bar: async (t) => (await D.listen(false, t), D.makeHold(t), await D.listen(false, t)),
    dock: async (t) => (await D.listen(true, t), await D.listen(true, t)),
    pet: (t) => (D.makeHold(t), D.dictate(t), D.makeHold(t), D.dictate(t)),
  };
  for (const [name, start] of Object.entries(entries)) {
    for (let i = 0; i < 20; i++) if (!(await startOnce({ D, m, reset, fails }, name, start, i))) break;
  }
}

/** One start (and its double) from an entry: false once it failed (the rest of that entry's run is skipped). */
async function startOnce({ D, m, reset, fails }, name, start, i) {
  reset();
  const t = target(`${name}${i}`);
  await start(t);
  D.makeHold(t);
  await sleep(i === 0 ? 400 : 30);
  const ok = D.listeningFor(t) && D.speech.value.listening && m.open === 1;
  if (!ok) fails.push(`${name} start ${i + 1}: not listening after a double start (open ${m.open})`);
  if (m.superseded) fails.push(`${name} start ${i + 1}: its own second start superseded it`);
  D.release(t);
  await sleep(10);
  return ok;
}

/** A busy recognizer: the start retries once (and listens); busy twice, the field gets a message, never a silent off. */
async function busyRetry({ D, m, reset, fails }) {
  reset();
  const t = target("busy1");
  m.failNext = 1;
  D.dictate(t);
  await sleep(200);
  if (m.starts !== 2) fails.push(`busy once: ${m.starts} starts, want 2 (one retry)`);
  if (!D.listeningFor(t) || !D.speech.value.listening) fails.push("busy once: not listening after the retry");
  D.interrupt();
  await sleep(30);
  reset();
  const u = target("busy2");
  m.failNext = 2;
  D.dictate(u);
  await sleep(200);
  if (m.starts !== 2) fails.push(`busy twice: ${m.starts} starts, want 2 (exactly one retry)`);
  if (D.listeningFor(u)) fails.push("busy twice: still pending");
  if (!D.speech.value.error) fails.push("busy twice: no message shown");
  m.failNext = 0;
}

/** The page reads hidden for a moment (the side button's panel re-attaching): the dictation stays. */
async function hiddenGrace({ D, m, reset, fails }) {
  reset();
  const t = target("hidden");
  D.dictate(t);
  D.makeHold(t);
  const set = (h) => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => h });
    document.dispatchEvent(new Event("visibilitychange"));
  };
  try {
    set(true);
    await sleep(100);
    set(false);
    await sleep(1000);
    if (!D.listeningFor(t)) fails.push("a moment hidden ended the dictation");
    set(true);
    await sleep(1000);
    if (D.listeningFor(t)) fails.push("hidden for good: the dictation goes on");
  } finally {
    delete document.hidden;
  }
  D.interrupt();
}

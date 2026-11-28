// A focus's window for held notifications (shell/ui/time.ts inWindow, focuswindow.ts heldBy / ended):
// node --test shell/test/focus.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { inWindow } from "../ui/time.ts";
import { ended, heldBy, type FocusWindow } from "../ui/focuswindow.ts";
import type { PhoneNotification } from "../types.ts";

const since = 1_795_837_359_960; // Date.now() ms, as focusOn stores it
const s = Math.floor(since / 1000); // a notification's time: Unix seconds (postTime / 1000)

// 11-28 verify FAIL: seconds compared with ms - nothing posted during a focus was ever held.
test("posted while the focus runs: in", () => assert.equal(inWindow(s + 2, since), true));
test("posted in the focus's first second: in", () => assert.equal(inWindow(s, since), true));
test("posted before the focus: out", () => assert.equal(inWindow(s - 5, since), false));
test("posted after the window ended: out", () => assert.equal(inWindow(s + 5, since, since + 1000), false));
test("posted before the window ended: in", () => assert.equal(inWindow(s + 1, since, since + 1000), true));

// 11-28 verify FAIL after the seconds fix: held while on, the digest card gone the moment the focus ended - the ended
// window keeps what it held by key, so a notification re-stamped past [until] (Do not disturb going off) stays held.

const note = (key: string, time: number, pkg = "com.android.shell") => ({ key, time, pkg, app: "System UI", clearable: true }) as PhoneNotification;
const on: FocusWindow = { id: "dnd", label: "Do not disturb", since, allow: [] };

test("ended: keeps the ones held while on, by key", () => {
  const w = ended(on, [], [note("a", s + 2), note("old", s - 60)], since + 8000);
  assert.deepEqual(w.held, ["a"]);
  assert.equal(w.until, since + 8000);
});
test("ended: one re-stamped after the end is still held", () => {
  const w = ended(on, [], [note("a", s + 2)], since + 8000);
  assert.equal(heldBy(note("a", s + 30), w), true);
});
test("ended: one posted after the end is not held", () => {
  const w = ended(on, [], [note("a", s + 2)], since + 8000);
  assert.equal(heldBy(note("b", s + 9), w), false);
});
test("ended: an allowed app's one is not kept", () => {
  const w = ended(on, ["com.Slack"], [note("a", s + 2, "com.Slack")], since + 8000);
  assert.deepEqual(w.held, []);
});
test("an older stored window (no keys): the time window decides", () => {
  assert.equal(heldBy(note("a", s + 2), { ...on, until: since + 8000 }), true);
});

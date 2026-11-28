// A focus's window for held notifications (shell/ui/time.ts inWindow, used by focus.ts heldBy):
// node --test shell/test/focus.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { inWindow } from "../ui/time.ts";

const since = 1_795_837_359_960; // Date.now() ms, as focusOn stores it
const s = Math.floor(since / 1000); // a notification's time: Unix seconds (postTime / 1000)

// 11-28 verify FAIL: seconds compared with ms - nothing posted during a focus was ever held.
test("posted while the focus runs: in", () => assert.equal(inWindow(s + 2, since), true));
test("posted in the focus's first second: in", () => assert.equal(inWindow(s, since), true));
test("posted before the focus: out", () => assert.equal(inWindow(s - 5, since), false));
test("posted after the window ended: out", () => assert.equal(inWindow(s + 5, since, since + 1000), false));
test("posted before the window ended: in", () => assert.equal(inWindow(s + 1, since, since + 1000), true));

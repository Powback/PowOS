// KB1: shell/ui/kbfit.ts - the window being typed into ends at the keyboard's top (test-webwindows-kbfit.sh).
import { test } from "node:test";
import assert from "node:assert/strict";
import { fitAboveKeyboard, hasKeyboardButton, keyboardTop } from "../ui/kbfit.ts";

const side = { x: 410, y: 40, w: 410, h: 820 }; // a right-pinned tile on the unfolded 821x883 home
const at = (kbTop: number, originY = 0) => ({ kbTop, originY, topLimit: 24, minH: 160 });

test("no keyboard: the frame is its own", () => {
  assert.equal(fitAboveKeyboard(side, 1, at(Infinity)), side);
  assert.equal(keyboardTop(0, 883), Infinity);
  assert.equal(keyboardTop(undefined, 883), Infinity);
});

test("keyboard over a side-pinned tile: its bottom ends at the keyboard's top, top and width kept", () => {
  const kb = keyboardTop(330, 883); // 553
  const f = fitAboveKeyboard(side, 1, at(kb));
  assert.deepEqual(f, { x: 410, y: 40, w: 410, h: 513 });
  assert.ok(f.y + f.h <= kb);
});

test("a maximised window under a page origin offset fits too", () => {
  const f = fitAboveKeyboard({ x: 0, y: 0, w: 821, h: 830 }, 1, at(553, 30));
  assert.equal(30 + f.y + f.h, 553);
});

test("a frame above the keyboard already is untouched (same object)", () => {
  const f = { x: 10, y: 40, w: 300, h: 400 };
  assert.equal(fitAboveKeyboard(f, 1, at(553)), f);
});

test("a floating window low on screen moves up to keep its minimum, never above the status bar", () => {
  assert.deepEqual(fitAboveKeyboard({ x: 10, y: 500, w: 300, h: 300 }, 1, at(553)), { x: 10, y: 393, w: 300, h: 160 });
  const tall = fitAboveKeyboard({ x: 10, y: 500, w: 300, h: 300 }, 1, at(100));
  assert.equal(tall.y, 24);
  assert.equal(tall.h, 76);
});

test("a zoomed window's height is in its unscaled px", () => {
  const f = fitAboveKeyboard({ x: 0, y: 100, w: 400, h: 1000 }, 0.5, at(553));
  assert.equal(f.h, 906); // 453 screen px / 0.5
  assert.equal(f.y, 100);
});

test("keyboard button: a Linux window's bar has it with a host that takes it; Android and web windows never", () => {
  assert.equal(hasKeyboardButton("l:steam_app_1238820", true), true); // the EA app under Proton (11-26)
  assert.equal(hasKeyboardButton("l:org.kde.kwrite", true), true);
  assert.equal(hasKeyboardButton("l:xterm", false), false); // an older APK: no "webwindows.keyboard"
  assert.equal(hasKeyboardButton("a:com.android.chrome", true), false);
  assert.equal(hasKeyboardButton("w:notes", true), false);
});

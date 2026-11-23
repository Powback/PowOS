// The side dock's alignment (shell/ui/dockalign.ts): node --test shell/test/dockalign.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { dockAtEnd, dockClasses, searchButtonIndex, searchGapSlot, validDockAlign } from "../ui/dockalign.ts";

test("alignment defaults to the bottom (thumb reach); only top/bottom are kept", () => {
  assert.equal(validDockAlign(""), "bottom");
  assert.equal(validDockAlign("middle"), "bottom");
  assert.equal(validDockAlign("top"), "top");
  assert.equal(validDockAlign("bottom"), "bottom");
  assert.equal(validDockAlign("junk", "top"), "top");
});

test("only a side dock aligns; the horizontal bottom dock never does", () => {
  for (const side of ["left", "right"]) {
    assert.equal(dockAtEnd(side, "bottom"), true);
    assert.equal(dockAtEnd(side, ""), true); // unset = the default, bottom
    assert.equal(dockAtEnd(side, "top"), false);
  }
  assert.equal(dockAtEnd("bottom", "bottom"), false);
  assert.equal(dockAtEnd("bottom", "top"), false);
});

test("home's classes: dock-end only for a bottom-aligned side dock", () => {
  assert.equal(dockClasses("left", "bottom"), "dock-left dock-end");
  assert.equal(dockClasses("right", "bottom"), "dock-right dock-end");
  assert.equal(dockClasses("right", "top"), "dock-right");
  assert.equal(dockClasses("bottom", "bottom"), "dock-bottom");
});

test("the search button separates pinned from recents on the recents' side", () => {
  // Bottom dock: the middle, unchanged by the alignment.
  assert.equal(searchButtonIndex("bottom", "bottom", 6), 3);
  assert.equal(searchButtonIndex("bottom", "top", 5), 2);
  // Side, top-aligned: after the pinned apps (recents below); bottom-aligned: before them (recents above).
  assert.equal(searchButtonIndex("left", "top", 4), 4);
  assert.equal(searchButtonIndex("right", "bottom", 4), 0);
  assert.equal(searchGapSlot("bottom", "bottom", 5), 3);
  assert.equal(searchGapSlot("left", "top", 4), 4);
  assert.equal(searchGapSlot("left", "bottom", 4), 0);
});

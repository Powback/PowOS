// The lock face's charging line (shell/ui/charge.ts): node --test shell/test/charge.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { chargeKind, chargeLine, untilFull } from "../ui/charge.ts";
import type { Battery } from "../types.ts";

const b = (o: Partial<Battery>): Battery => ({ level: 50, charging: true, plugged: "ac", full: false, held: false, speed: "normal", fullInMs: null, ...o });

test("time until full: minutes, hours, rounded up, never 0", () => {
  assert.equal(untilFull(45 * 60000), "45 min");
  assert.equal(untilFull(60 * 60000), "1 h");
  assert.equal(untilFull(80 * 60000), "1 h 20 min");
  assert.equal(untilFull(59 * 60000 + 1), "1 h");
  assert.equal(untilFull(10), "1 min");
});

test("the stock wording per class, wired and wireless", () => {
  assert.equal(chargeKind(b({ speed: "superfast" })), "Super fast charging");
  assert.equal(chargeKind(b({ speed: "fast" })), "Fast charging");
  assert.equal(chargeKind(b({ speed: "normal" })), "Charging");
  assert.equal(chargeKind(b({ speed: "slow" })), "Charging slowly");
  assert.equal(chargeKind(b({ plugged: "wireless", speed: "normal" })), "Charging wirelessly");
  assert.equal(chargeKind(b({ plugged: "wireless", speed: "fast" })), "Fast wireless charging");
});

test("the time shows only when Android gives one", () => {
  assert.equal(chargeLine(b({ speed: "superfast", fullInMs: 3600000 })), "Super fast charging · 1 h until full");
  assert.equal(chargeLine(b({ speed: "fast", fullInMs: null })), "Fast charging");
  assert.equal(chargeLine(b({ fullInMs: -1 })), "Charging");
});

test("on battery: nothing; full: Charged; held: paused; an older host (level + charging only): Charging", () => {
  assert.equal(chargeLine(b({ charging: false, plugged: null, speed: null })), null);
  assert.equal(chargeLine(b({ full: true, fullInMs: 1000 })), "Charged");
  assert.equal(chargeLine(b({ charging: false, held: true, speed: null })), "Charging paused");
  assert.equal(chargeLine({ level: 40, charging: true }), "Charging");
  assert.equal(chargeLine({ level: 40, charging: false }), null);
});

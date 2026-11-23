// The launcher's content per state (shell/ui/launcherview.ts): node --test shell/test/launcherview.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { launcherView, nextLetter, RECENT_MAX, SUGGESTED_MAX, sortApps, type LetterEvent } from "../ui/launcherview.ts";

const app = (label: string) => ({ key: `a:${label.toLowerCase()}`, label });
const all = ["Brave", "Calendar", "Camera", "Chrome", "Maps", "Messages", "Music", "Signal", "Spotify", "Steam", "Zoom", "Ölwerk", "7-Zip"].map(app);
const sorted = sortApps(all, new Intl.Collator(undefined, { sensitivity: "base", numeric: true }).compare);
const byKey = new Map(all.map((a) => [a.key, a]));
const base = { searching: false, letter: null as string | null, sorted, byKey, recent: ["a:chrome", "a:spotify", "a:gone"], frequent: ["a:chrome", "a:maps", "a:spotify", "a:zoom"] };
const labels = (xs: { label: string }[]) => xs.map((a) => a.label);
const run = (events: LetterEvent[], from: string | null = null) => events.reduce((l, e) => nextLetter(sorted.first, l, e), from);

test("opened: Recent newest first, then Suggested without what Recent shows", () => {
  const v = launcherView(base);
  assert.equal(v.kind, "sections");
  if (v.kind !== "sections") return;
  assert.deepEqual(labels(v.recent), ["Chrome", "Spotify"]); // an uninstalled key is skipped
  assert.deepEqual(labels(v.suggested), ["Maps", "Zoom"]);
});

test("sections stay compact", () => {
  const keys = all.map((a) => a.key);
  const v = launcherView({ ...base, recent: keys, frequent: [...keys].reverse() });
  assert.equal(v.kind, "sections");
  if (v.kind !== "sections") return;
  assert.equal(v.recent.length, RECENT_MAX);
  assert.ok(v.suggested.length <= SUGGESTED_MAX);
  assert.ok(v.suggested.every((a) => !v.recent.includes(a)));
});

test("no usage data: Suggested hidden; nothing at all: every app A to Z, never an empty page", () => {
  const v = launcherView({ ...base, frequent: [] });
  assert.equal(v.kind === "sections" && v.suggested.length, 0);
  const none = launcherView({ ...base, recent: [], frequent: [] });
  assert.equal(none.kind, "all");
  assert.equal(none.kind === "all" && none.apps.length, all.length);
});

test("scrubbing shows every app of the letter, live per letter", () => {
  let l = run([{ type: "open" }, { type: "scrub", letter: "S" }]);
  let v = launcherView({ ...base, letter: l });
  assert.equal(v.kind, "letter");
  assert.deepEqual(v.kind === "letter" && labels(v.apps), ["Signal", "Spotify", "Steam"]);
  l = run([{ type: "scrub", letter: "M" }], l);
  v = launcherView({ ...base, letter: l });
  assert.deepEqual(v.kind === "letter" && labels(v.apps), ["Maps", "Messages", "Music"]);
  // "Ö" under O, a digit under "#".
  const o = launcherView({ ...base, letter: run([{ type: "scrub", letter: "O" }]) });
  assert.deepEqual(o.kind === "letter" && labels(o.apps), ["Ölwerk"]);
  assert.equal(run([{ type: "scrub", letter: "#" }]), "#");
});

test("release keeps the letter; the chip and a reopen go back to the sections", () => {
  const held = run([{ type: "open" }, { type: "scrub", letter: "C" }, { type: "release" }]);
  assert.equal(held, "C");
  assert.equal(launcherView({ ...base, letter: held }).kind, "letter");
  assert.equal(run([{ type: "clear" }], held), null);
  assert.equal(run([{ type: "open" }], held), null);
  assert.equal(launcherView({ ...base, letter: run([{ type: "open" }], held) }).kind, "sections");
});

test("a letter with no apps shows the next letter's (the last letter's past the end)", () => {
  assert.equal(run([{ type: "scrub", letter: "D" }]), "M");
  assert.equal(run([{ type: "scrub", letter: "X" }]), "Z");
  // No apps at all: the letter stays where it was (null: sections / all).
  assert.equal(nextLetter(new Map(), null, { type: "scrub", letter: "A" }), null);
});

test("search overrides the letter and the sections", () => {
  assert.equal(launcherView({ ...base, searching: true }).kind, "search");
  assert.equal(launcherView({ ...base, searching: true, letter: "S" }).kind, "search");
});

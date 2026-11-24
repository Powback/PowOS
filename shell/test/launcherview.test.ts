// The launcher's content per state (shell/ui/launcherview.ts): node --test shell/test/launcherview.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { ALL, appsOfLetter, isPowApp, launcherApps, launcherView, nextLetter, POW, POW_FOLDER, powGroups, RECENT_MAX, SUGGESTED_MAX, sortApps, type LetterEvent } from "../ui/launcherview.ts";

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

test("All (top or bottom of the bar) shows every app under its letter's heading, kept on release, chip back", () => {
  // The bar has All at both ends; either sends the same event.
  const held = run([{ type: "open" }, { type: "scrub", letter: ALL }, { type: "release" }]);
  assert.equal(held, ALL);
  const v = launcherView({ ...base, letter: held });
  assert.equal(v.kind, "all");
  if (v.kind !== "all") return;
  assert.equal(v.picked, true);
  assert.deepEqual(labels(v.apps), labels(sorted.list));
  assert.deepEqual(v.groups.map((g) => g.letter), ["#", "B", "C", "M", "O", "S", "Z"]);
  assert.deepEqual(labels(v.groups.find((g) => g.letter === "C")!.apps), ["Calendar", "Camera", "Chrome"]);
  assert.equal(v.groups.flatMap((g) => g.apps).length, all.length);
  assert.equal(run([{ type: "clear" }], held), null);
  // The fallback A-Z (no recent, no suggested) has the headings too, but no chip.
  const none = launcherView({ ...base, recent: [], frequent: [] });
  assert.equal(none.kind === "all" && none.picked, false);
});

test("sliding All -> letter -> All switches live; a reopen resets; search still overrides All", () => {
  // From the top All down into the letters, then on to the bottom All.
  let l = run([{ type: "open" }, { type: "scrub", letter: ALL }, { type: "scrub", letter: "B" }]);
  assert.equal(l, "B");
  assert.equal(launcherView({ ...base, letter: l }).kind, "letter");
  l = run([{ type: "scrub", letter: "Z" }, { type: "scrub", letter: ALL }, { type: "release" }], l);
  assert.equal(l, ALL);
  assert.equal(run([{ type: "open" }], l), null);
  assert.equal(launcherView({ ...base, letter: run([{ type: "open" }], l) }).kind, "sections");
  assert.equal(launcherView({ ...base, searching: true, letter: ALL }).kind, "search");
  // All with no apps at all: still All, an empty list rather than a stale letter.
  assert.equal(nextLetter(new Map(), "C", { type: "scrub", letter: ALL }), ALL);
});

// The Pow folder (the user 11-23): every .pow web app in one folder, never loose in the launcher's lists.
const web = (host: string, label: string, webCategory?: string | null) => ({ key: `w:${host}`, label, webCategory });
const powApps = [web("pihole.pow", "Pi-hole", "infrastructure"), web("ararat.pow", "Ararat", "games"), web("cdn.pow", "CDN"), web("traefik.pow", "Traefik", "infrastructure"), web("powscan.pow", "PowScan", "productivity"), web("arcade.pow", "Arcade", "games")];
const folderEntry = { key: POW_FOLDER, label: POW };
const cmp = new Intl.Collator(undefined, { sensitivity: "base", numeric: true }).compare;

test("launcher apps: the .pow apps leave the list and one Pow folder takes their place", () => {
  const list = launcherApps([...all, ...powApps], folderEntry);
  assert.equal(list.filter(isPowApp).length, 0);
  assert.equal(list.filter((a) => a.key === POW_FOLDER).length, 1);
  const s = sortApps(list, cmp);
  assert.ok(appsOfLetter(s, "P").some((a) => a.key === POW_FOLDER), "the folder sits under P");
});

test("launcher apps: no .pow apps, no folder (even if one is offered)", () => {
  assert.deepEqual(launcherApps(all, folderEntry), all);
  assert.deepEqual(launcherApps(all, null), all);
});

test("Pow folder: user-facing categories first, then none, infrastructure last; A to Z inside", () => {
  const g = powGroups([...all, ...powApps], cmp);
  assert.deepEqual(g.map((x) => x.letter), ["Games", "Productivity", "Other", "Infrastructure"]);
  assert.deepEqual(labels(g[0].apps), ["Ararat", "Arcade"]);
  assert.deepEqual(labels(g[3].apps), ["Pi-hole", "Traefik"]);
  assert.deepEqual(powGroups(all, cmp), []);
});

test("Pow view: opened shows its groups; emptied goes back to the sections; open/clear leave it", () => {
  const pow = powGroups(powApps, cmp);
  const v = launcherView({ ...base, letter: POW, pow });
  assert.equal(v.kind, "folder");
  assert.equal(launcherView({ ...base, letter: POW, pow: [] }).kind, "sections");
  assert.equal(nextLetter(sorted.first, POW, { type: "release" }), POW);
  assert.equal(nextLetter(sorted.first, POW, { type: "clear" }), null);
  assert.equal(nextLetter(sorted.first, POW, { type: "open" }), null);
});

/**
 * Remote input's keyboard (ui/remote.tsx): text and keys as USB HID keyboard reports - what a real keyboard would
 * send for them, on the layout the computer has set (a report names a key's place, not a character: on a Norwegian
 * computer the key right of 0 is "+", on a US one "-").
 *
 * A report is [modifiers, ...usages held] (HID usage page 7); powos.remote.keys sends a list of them in order.
 */
import { signal } from "@preact/signals";
import { powos } from "./bridge.ts";

/** Modifier bits (the report's first byte). */
export const CTRL = 0x01;
export const SHIFT = 0x02;
export const ALT = 0x04;
export const SUPER = 0x08;
/** Right Alt: AltGr on the layouts that have one. */
export const ALTGR = 0x40;

/** Usages of the keys that aren't characters. */
export const KEY = {
  enter: 0x28,
  esc: 0x29,
  backspace: 0x2a,
  tab: 0x2b,
  space: 0x2c,
  capsLock: 0x39,
  f1: 0x3a,
  printScreen: 0x46,
  insert: 0x49,
  home: 0x4a,
  pageUp: 0x4b,
  del: 0x4c,
  end: 0x4d,
  pageDown: 0x4e,
  right: 0x4f,
  left: 0x50,
  down: 0x51,
  up: 0x52,
  menu: 0x65,
} as const;

/** How a character is typed: its key, the modifiers held, and whether it's a dead key (a space after makes it). */
type Stroke = [usage: number, mods: number, dead?: boolean];
type Layout = Record<string, Stroke>;

/** The US layout - the base the others change. */
function us(): Layout {
  const l: Layout = {};
  for (let i = 0; i < 26; i++) {
    const c = String.fromCharCode(97 + i);
    l[c] = [0x04 + i, 0];
    l[c.toUpperCase()] = [0x04 + i, SHIFT];
  }
  "1234567890".split("").forEach((c, i) => (l[c] = [0x1e + i, 0]));
  "!@#$%^&*()".split("").forEach((c, i) => (l[c] = [0x1e + i, SHIFT]));
  const keys: [number, string, string][] = [
    [0x2d, "-", "_"],
    [0x2e, "=", "+"],
    [0x2f, "[", "{"],
    [0x30, "]", "}"],
    [0x31, "\\", "|"],
    [0x33, ";", ":"],
    [0x34, "'", '"'],
    [0x35, "`", "~"],
    [0x36, ",", "<"],
    [0x37, ".", ">"],
    [0x38, "/", "?"],
  ];
  for (const [u, a, b] of keys) {
    l[a] = [u, 0];
    l[b] = [u, SHIFT];
  }
  l[" "] = [KEY.space, 0];
  l["\n"] = [KEY.enter, 0];
  l["\t"] = [KEY.tab, 0];
  return l;
}

/** A layout as US with [keys] moved: [usage, plain, shifted, altgr] each ("" for none, a leading "~" a dead key). */
function variant(keys: [number, string, string, string?][], extra: Record<string, Stroke> = {}): Layout {
  const l = us();
  // What US had on these keys isn't there any more (unless the layout puts it elsewhere, below).
  for (const [u] of keys) for (const [c, s] of Object.entries(l)) if (s[0] === u) delete l[c];
  for (const [u, plain, shifted, altgr] of keys) {
    const put = (c: string | undefined, mods: number) => {
      if (!c) return;
      const dead = c.length > 1 && c.startsWith("~");
      l[dead ? c.slice(1) : c] = [u, mods, dead];
    };
    put(plain, 0);
    put(shifted, SHIFT);
    put(altgr, ALTGR);
  }
  return { ...l, ...extra };
}

/** The Nordic number row and punctuation (Norwegian and Swedish share most of it). */
const nordicNumbers: [number, string, string, string?][] = [
  [0x1e, "1", "!"],
  [0x1f, "2", '"', "@"],
  [0x20, "3", "#", "£"],
  [0x21, "4", "¤", "$"],
  [0x22, "5", "%", "€"],
  [0x23, "6", "&"],
  [0x24, "7", "/", "{"],
  [0x25, "8", "(", "["],
  [0x26, "9", ")", "]"],
  [0x27, "0", "=", "}"],
  [0x2f, "å", "Å"],
  [0x30, "~¨", "~^", "~~"],
  [0x31, "'", "*"],
  [0x36, ",", ";"],
  [0x37, ".", ":"],
  [0x38, "-", "_"],
];

export const LAYOUTS: Record<string, { name: string; keys: Layout }> = {
  us: { name: "English (US)", keys: us() },
  uk: {
    name: "English (UK)",
    keys: variant([
      [0x1f, "2", '"'],
      [0x20, "3", "£"],
      [0x34, "'", "@"],
      [0x31, "#", "~"],
      [0x35, "`", "¬"],
      [0x64, "\\", "|"],
    ]),
  },
  no: {
    name: "Norsk",
    keys: variant([
      ...nordicNumbers,
      [0x2d, "+", "?"],
      [0x2e, "\\", "~`", "~´"],
      [0x33, "ø", "Ø"],
      [0x34, "æ", "Æ"],
      [0x35, "|", "§"],
      [0x64, "<", ">"],
    ]),
  },
  se: {
    name: "Svenska",
    keys: variant([
      ...nordicNumbers,
      [0x2d, "+", "?", "\\"],
      [0x2e, "~´", "~`"],
      [0x33, "ö", "Ö"],
      [0x34, "ä", "Ä"],
      [0x35, "§", "½"],
      [0x64, "<", ">", "|"],
    ]),
  },
  de: {
    name: "Deutsch",
    keys: variant([
      [0x1c, "z", "Z"],
      [0x1d, "y", "Y"],
      [0x14, "q", "Q", "@"],
      [0x08, "e", "E", "€"],
      [0x1e, "1", "!"],
      [0x1f, "2", '"', "²"],
      [0x20, "3", "§", "³"],
      [0x21, "4", "$"],
      [0x22, "5", "%"],
      [0x23, "6", "&"],
      [0x24, "7", "/", "{"],
      [0x25, "8", "(", "["],
      [0x26, "9", ")", "]"],
      [0x27, "0", "=", "}"],
      [0x2d, "ß", "?", "\\"],
      [0x2e, "~´", "~`"],
      [0x2f, "ü", "Ü"],
      [0x30, "+", "*", "~"],
      [0x31, "#", "'"],
      [0x33, "ö", "Ö"],
      [0x34, "ä", "Ä"],
      [0x35, "~^", "°"],
      [0x36, ",", ";"],
      [0x37, ".", ":"],
      [0x38, "-", "_"],
      [0x64, "<", ">", "|"],
    ]),
  },
};

/** The computer's layout, kept with the shell's data (store "remote"). */
export const layout = signal<string>("us");
/** Modifiers latched from the extra keys: on the next key only, or held ("locked") until tapped off. */
export const latched = signal<{ mods: number; locked: number }>({ mods: 0, locked: 0 });

powos.store
  .get<{ layout?: string }>("remote")
  .then((s) => s?.layout && LAYOUTS[s.layout] && (layout.value = s.layout))
  .catch(() => {});

export function setLayout(name: string) {
  layout.value = name;
  powos.store.set("remote", { layout: name });
}

/** The latched modifiers for this key, a one-shot latch spent. */
function takeMods(): number {
  const l = latched.value;
  if (l.mods & ~l.locked) latched.value = { mods: l.locked, locked: l.locked };
  return l.mods;
}

/** A tap on a modifier key: latches it for the next key; a second tap while latched locks it; a third frees it. */
export function tapModifier(mod: number) {
  const l = latched.value;
  if (l.locked & mod) latched.value = { mods: l.mods & ~mod, locked: l.locked & ~mod };
  else if (l.mods & mod) latched.value = { mods: l.mods, locked: l.locked | mod };
  else latched.value = { mods: l.mods | mod, locked: l.locked };
}

/** Whether non-Shift modifiers are latched: typed text is then a shortcut (Ctrl+C), not text. */
export const shortcutLatched = () => (latched.value.mods & ~SHIFT) !== 0;

/** A key pressed and let go (with [mods] and whatever is latched). */
export function press(usage: number, mods = 0): number[][] {
  return [[mods | takeMods(), usage], [0]];
}

/** The reports that type [text] on the current layout; characters it has no key for are left out (counted). */
export function typeText(text: string): { reports: number[][]; missing: number } {
  const keys = LAYOUTS[layout.value]?.keys ?? LAYOUTS.us.keys;
  const reports: number[][] = [];
  let missing = 0;
  for (const ch of text.replace(/\r\n?/g, "\n")) {
    const s = keys[ch];
    if (!s) {
      missing++;
      continue;
    }
    reports.push([s[1] | takeMods(), s[0]], [0]);
    // A dead key (^ ` ´ ~ ¨ on most European layouts) makes its character with the space after it.
    if (s[2]) reports.push([0, KEY.space], [0]);
  }
  return { reports, missing };
}

export function send(reports: number[][]) {
  if (reports.length) powos.remote.keys(reports).catch(() => {});
}

/** [n] presses of one key, as reports. */
export const repeat = (usage: number, n: number): number[][] => Array.from({ length: Math.max(0, n) }, () => [[0, usage], [0]]).flat();

/**
 * What changed in the text field, as keys for the computer - its text mirrors the field's: the caret moved to the
 * change (arrows), what was taken out deleted (Backspace), what came in typed. The soft keyboard's composing (a word
 * growing, autocorrect swapping it) is this too: only the letters that differ go. [caret]: where the computer's
 * caret is in [before] (where the field's was); returns the reports and where its caret is in [after].
 */
export function diff(before: string, after: string, caret: number): { reports: number[][]; caret: number; missing: number } {
  let p = 0;
  const max = Math.min(before.length, after.length);
  while (p < max && before[p] === after[p]) p++;
  let s = 0;
  while (s < max - p && before[before.length - 1 - s] === after[after.length - 1 - s]) s++;
  const removedEnd = before.length - s;
  const added = after.slice(p, after.length - s);
  const reports: number[][] = [];
  // To the end of what was removed (or the insertion point), from wherever the caret was.
  if (caret < removedEnd) reports.push(...repeat(KEY.right, removedEnd - caret));
  else reports.push(...repeat(KEY.left, caret - removedEnd));
  reports.push(...repeat(KEY.backspace, removedEnd - p));
  const typed = typeText(added);
  reports.push(...typed.reports);
  return { reports, caret: p + added.length, missing: typed.missing };
}

/** The Remote input screen open (the control center's tile opens it; Back closes it, state.ts). */
export const remoteOpen = signal(false);
export const openRemote = () => (remoteOpen.value = true);
export function closeRemote() {
  if (!remoteOpen.value) return;
  remoteOpen.value = false;
  powos.keyboard.hide();
}

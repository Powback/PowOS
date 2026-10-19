/**
 * The drawer: every app A to Z under letter headings, with an A-Z bar to tap or slide along (as PowOS's start
 * menu). Typing in the bar narrows it to matches, best first. Always mounted: it slides with the finger that opens
 * or closes it (gesture.ts), and settles with a transition.
 */
import { useRef, useState } from "preact/hooks";
import { computed } from "@preact/signals";
import { AppCell } from "./apps.tsx";
import { drawerDrag, drawerShown } from "./gesture.ts";
import { apps, query } from "../state.ts";
import type { App } from "../types.ts";

const ALPHABET = ["#", ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ"];
const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });

/** "Ö" is under O; names that don't start with a letter under "#". */
function heading(label: string) {
  const first = label.trim().normalize("NFD")[0]?.toUpperCase() ?? "";
  return first >= "A" && first <= "Z" ? first : "#";
}

const sections = computed(() => {
  const groups = new Map<string, App[]>();
  for (const app of [...apps.value].sort((a, b) => collator.compare(a.label, b.label))) {
    const h = heading(app.label);
    if (!groups.has(h)) groups.set(h, []);
    groups.get(h)!.push(app);
  }
  return ALPHABET.filter((l) => groups.has(l)).map((l) => [l, groups.get(l)!] as const);
});

/** Matches for what's typed: names starting with it first, then words starting with it, then anywhere in them. */
export const matches = computed(() => {
  const q = query.value.trim().toLowerCase();
  if (!q) return [];
  const rank = (label: string) => {
    const l = label.toLowerCase();
    if (l.startsWith(q)) return 0;
    if (l.split(/\s+/).some((w) => w.startsWith(q))) return 1;
    return l.includes(q) ? 2 : -1;
  };
  return apps.value
    .map((app) => [rank(app.label), app] as const)
    .filter(([r]) => r >= 0)
    .sort((a, b) => a[0] - b[0] || collator.compare(a[1].label, b[1].label))
    .map(([, app]) => app);
});

/** Tap a letter or slide along the bar: the list jumps there at once, every letter the finger crosses. */
function LetterBar({ onPick }: { onPick: (letter: string) => void }) {
  const [current, setCurrent] = useState<string | null>(null);
  const bar = useRef<HTMLDivElement>(null);
  const pick = (y: number) => {
    const r = bar.current!.getBoundingClientRect();
    const i = Math.max(0, Math.min(ALPHABET.length - 1, Math.floor(((y - r.top) / r.height) * ALPHABET.length)));
    if (ALPHABET[i] === current) return;
    setCurrent(ALPHABET[i]);
    navigator.vibrate?.(5);
    onPick(ALPHABET[i]);
  };
  return (
    <div
      class="letter-bar"
      ref={bar}
      onPointerDown={(e) => {
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
        e.stopPropagation();
        pick(e.clientY);
      }}
      onPointerMove={(e) => e.buttons && pick(e.clientY)}
      onPointerUp={() => setCurrent(null)}
      onPointerCancel={() => setCurrent(null)}
    >
      {ALPHABET.map((l) => (
        <span class={l === current ? "on" : ""}>{l}</span>
      ))}
      {current && <div class="letter-bubble">{current}</div>}
    </div>
  );
}

export function Drawer() {
  const list = useRef<HTMLDivElement>(null);
  const jump = (letter: string) => {
    // Its own heading, else the next letter's, else the last ("#": the first). At once: a smooth scroll restarted for
    // every letter a sliding finger crosses lagged behind it.
    const i = ALPHABET.indexOf(letter);
    const target = sections.value.find(([l]) => ALPHABET.indexOf(l) >= i) ?? sections.value.at(-1);
    const el = target && list.current?.querySelector<HTMLElement>(`[data-letter="${target[0]}"]`);
    if (el) list.current!.scrollTop = el.offsetTop - list.current!.offsetTop;
  };
  const searching = query.value.trim() !== "";
  const p = drawerShown();
  const dragging = drawerDrag.value != null;
  return (
    <div
      class={`drawer ${p > 0 ? "shown" : ""} ${dragging ? "dragging" : ""}`}
      // From the bottom edge, all the way: the finger carries it up. Opaque, so home doesn't show through it.
      style={{ transform: `translateY(${(1 - p) * 100}%)`, opacity: p > 0 ? 1 : 0 }}
      aria-hidden={p === 0}
    >
      <div class="drawer-list" ref={list}>
        {searching ? (
          <div class="grid">
            {matches.value.map((app) => (
              <AppCell key={app.key} app={app} draggable />
            ))}
          </div>
        ) : (
          sections.value.map(([letter, group]) => (
            <section key={letter}>
              <h2 class="heading muted" data-letter={letter}>
                {letter}
              </h2>
              <div class="grid">
                {group.map((app) => (
                  <AppCell key={app.key} app={app} draggable />
                ))}
              </div>
            </section>
          ))
        )}
      </div>
      {!searching && <LetterBar onPick={jump} />}
    </div>
  );
}

/**
 * The drawer: every app A to Z under letter headings, with an A-Z bar to tap or slide along (as PowOS's start
 * menu), and the dock - pinned apps, always there - above the bar. Typing in the bar narrows it to matches, best
 * first.
 */
import { useRef, useState } from "preact/hooks";
import { computed } from "@preact/signals";
import { html } from "./html.js";
import { AppCell } from "./apps.js";
import { apps, byKey, dock, query } from "../state.js";

const ALPHABET = ["#", ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ"];
const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });

/** "Ö" is under O; names that don't start with a letter under "#". */
function heading(label) {
  const first = label.trim().normalize("NFD")[0]?.toUpperCase() ?? "";
  return first >= "A" && first <= "Z" ? first : "#";
}

const sections = computed(() => {
  const groups = new Map();
  for (const app of [...apps.value].sort((a, b) => collator.compare(a.label, b.label))) {
    const h = heading(app.label);
    if (!groups.has(h)) groups.set(h, []);
    groups.get(h).push(app);
  }
  return ALPHABET.filter((l) => groups.has(l)).map((l) => [l, groups.get(l)]);
});

/** Matches for what's typed: names starting with it first, then words starting with it, then anywhere in them. */
const matches = computed(() => {
  const q = query.value.trim().toLowerCase();
  if (!q) return [];
  const rank = (label) => {
    const l = label.toLowerCase();
    if (l.startsWith(q)) return 0;
    if (l.split(/\s+/).some((w) => w.startsWith(q))) return 1;
    return l.includes(q) ? 2 : -1;
  };
  return apps.value
    .map((app) => [rank(app.label), app])
    .filter(([r]) => r >= 0)
    .sort((a, b) => a[0] - b[0] || collator.compare(a[1].label, b[1].label))
    .map(([, app]) => app);
});

function LetterBar({ onPick }) {
  const [current, setCurrent] = useState(null);
  const bar = useRef(null);
  const pick = (y) => {
    const r = bar.current.getBoundingClientRect();
    const letter = ALPHABET[Math.max(0, Math.min(ALPHABET.length - 1, Math.floor(((y - r.top) / r.height) * ALPHABET.length)))];
    if (letter === current) return;
    setCurrent(letter);
    navigator.vibrate?.(5);
    onPick(letter);
  };
  return html`
    <div
      class="letter-bar"
      ref=${bar}
      onPointerDown=${(e) => { e.currentTarget.setPointerCapture(e.pointerId); e.stopPropagation(); pick(e.clientY); }}
      onPointerMove=${(e) => e.buttons && pick(e.clientY)}
      onPointerUp=${() => setCurrent(null)}
      onPointerCancel=${() => setCurrent(null)}
    >
      ${ALPHABET.map((l) => html`<span class=${l === current ? "on" : ""}>${l}</span>`)}
    </div>
  `;
}

function Dock() {
  const pinned = dock.value.map((k) => byKey.value.get(k)).filter(Boolean);
  if (!pinned.length) return null;
  return html`<div class="dock tile">${pinned.map((app) => html`<${AppCell} key=${app.key} app=${app} labels=${false} />`)}</div>`;
}

export function Drawer() {
  const list = useRef(null);
  const jump = (letter) => {
    // Its own heading, else the next letter's, else the last ("#": the first).
    const i = ALPHABET.indexOf(letter);
    const target = sections.value.find(([l]) => ALPHABET.indexOf(l) >= i) ?? sections.value.at(-1);
    if (!target) return;
    list.current.querySelector(`[data-letter="${target[0]}"]`)?.scrollIntoView({ behavior: "smooth", block: "start" });
  };
  const searching = query.value.trim() !== "";
  return html`
    <div class="drawer">
      <div class="drawer-list" ref=${list}>
        ${searching
          ? html`<div class="grid">${matches.value.map((app) => html`<${AppCell} key=${app.key} app=${app} />`)}</div>`
          : sections.value.map(
              ([letter, group]) => html`
                <section key=${letter}>
                  <h2 class="heading muted" data-letter=${letter}>${letter}</h2>
                  <div class="grid">${group.map((app) => html`<${AppCell} key=${app.key} app=${app} />`)}</div>
                </section>
              `,
            )}
      </div>
      ${!searching && html`<${LetterBar} onPick=${jump} />`}
      ${!searching && html`<${Dock} />`}
    </div>
  `;
}

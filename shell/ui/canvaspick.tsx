/**
 * Split view's second app: a switcher card dropped on a screen edge (ui/carddock.ts, switcher.tsx) docks into that
 * half at once - its picture grows there from where the card was let go - and the other half asks which app goes
 * beside it. The user, 11-26: "The app should then dock and you should be able to select the other app that you want
 * to activate ... right now it's just randomly selecting the last app you had activated as the split screen couple".
 *
 * The picker: the recent apps first (the switcher's own cards, newest first), then every Android app A to Z, with a
 * search (names starting with what's typed first, as the drawer's). An app that can't be a side is dimmed with why (OxygenOS's blocklist and the live task
 * flags: the host's tasks.canvasSides; a Linux window). Only a tap on an app starts the pair - Open Canvas with both
 * chosen apps through the host's tasks.canvasDock (system/CanvasDock.kt, OxygenOS's app-pair shortcut); nothing is ever
 * picked for the user. Back, or a tap on the docked half, cancels: the dragged app full screen, as it was.
 */
import { signal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { App, RecentTask } from "../types.ts";
import { canSide, halfRect, otherSide, type DockSide } from "./carddock.ts";
import { spring } from "./spring.ts";
import { tick } from "./haptics.ts";
import { ShotPlaceholder } from "./switcher.tsx";

/** A dock waiting for its second app: the dragged task, its half, where its picture was let go; [chosen]: being opened. */
export interface CanvasPick {
  id: number;
  side: DockSide;
  from: { left: number; top: number; width: number; height: number };
  chosen?: { label: string; icon: string | null } | null;
}

export const canvasPick = signal<CanvasPick | null>(null);

/** A choice in the picker: a recent task (its id: the app keeps its state) or an app by key (started fresh). */
interface Choice {
  key: string;
  label: string;
  icon: string | null;
  task: number | null;
  /** Why it can't be a side (dimmed); null: it can. */
  why: string | null;
}

/** Why a recent card can't go beside the docked app (null: it can; undefined: not offered at all - home, a split). */
function recentWhy(t: RecentTask, sides: Set<number> | null): string | null | undefined {
  if (!t.key || t.id < 0 || t.split) return undefined;
  if (canSide(t, sides)) return null;
  if (t.key.startsWith("l:")) return "Linux windows can't be in split view";
  return "Can't be used in split view";
}

const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });

/** How well [label] matches [q] (lower case): 0 starts with it, 1 a word does, 2 anywhere, -1 not at all (the drawer's). */
function rank(label: string, q: string): number {
  const l = label.toLowerCase();
  if (!q || l.startsWith(q)) return 0;
  if (l.split(/\s+/).some((w) => w.startsWith(q))) return 1;
  return l.includes(q) ? 2 : -1;
}

/** What the picker lists: the switcher's cards, every app, the dragged task, the host's split-capable ids, the search. */
export interface ChoiceInput {
  tasks: RecentTask[];
  all: App[];
  dragged: number;
  sides: Set<number> | null;
  typed: string;
}

/** The recent cards offered beside [dragged] (newest first), and the app keys they cover. */
function recentChoices({ tasks, dragged, sides }: ChoiceInput, q: string): { recent: Choice[]; seen: Set<string> } {
  const seen = new Set<string>();
  const recent: Choice[] = [];
  for (const t of tasks) {
    if (t.id === dragged) {
      if (t.key) seen.add(t.key);
      continue;
    }
    const why = recentWhy(t, sides);
    if (why === undefined || seen.has(t.key!)) continue;
    seen.add(t.key!);
    if (rank(t.label, q) >= 0) recent.push({ key: t.key!, label: t.label, icon: t.icon, task: t.id, why });
  }
  return { recent, seen };
}

/** The picker's list: recent apps first, then the other Android apps A to Z (searching: best match first). */
export function choices(input: ChoiceInput): { recent: Choice[]; rest: Choice[] } {
  const q = input.typed.trim().toLowerCase();
  const { recent, seen } = recentChoices(input, q);
  const rest = input.all
    .filter((a) => a.kind === "android" && !seen.has(a.key) && !a.key.startsWith("a:com.powos.app"))
    .map((a) => [rank(a.label, q), a] as const)
    .filter(([r]) => r >= 0)
    .sort((a, b) => a[0] - b[0] || collator.compare(a[1].label, b[1].label))
    .map(([, a]): Choice => ({ key: a.key, label: a.label, icon: a.icon, task: null, why: null }));
  return { recent, rest };
}

/** The rect [side]'s half takes on the screen (CSS px). */
const half = (side: DockSide, w: number, h: number) => halfRect(side, w || innerWidth, h || innerHeight);
const px = (r: { x: number; y: number; w: number; h: number }) => ({ left: `${r.x}px`, top: `${r.y}px`, width: `${r.w}px`, height: `${r.h}px` });

/**
 * The docked app's half and the picker in the other. [tasks]: the switcher's cards, [sides]: the host's split-capable
 * ones; [onCancel]: the dragged app back full screen; [onNote]: a line for the user (a dimmed app's reason, a refusal).
 */
export function CanvasPicker({ tasks, sides, w, h, onCancel, onNote }: Props) {
  const p = canvasPick.value;
  if (!p) return null;
  const t = tasks.find((x) => x.id === p.id);
  return <Picker key={p.id} p={p} t={t} tasks={tasks} sides={sides} w={w} h={h} onCancel={onCancel} onNote={onNote} />;
}

interface Props {
  tasks: RecentTask[];
  sides: Set<number> | null;
  /** The screen (CSS px, the switcher's bounds: the keyboard left out). */
  w: number;
  h: number;
  onCancel: (id: number) => void;
  onNote: (text: string) => void;
}

function Picker({ p, t, tasks, sides, w, h, onCancel, onNote }: Props & { p: CanvasPick; t?: RecentTask }) {
  const pick = (c: Choice) => {
    if (p.chosen) return;
    if (c.why) return onNote(`${c.label}: ${c.why}`);
    tick();
    dock(p, c, onNote);
  };
  return (
    <div class={`canvas-pick ${p.side}`} data-side={p.side}>
      <DockedHalf p={p} t={t} w={w} h={h} onCancel={() => p.chosen || onCancel(p.id)} />
      <div class="canvas-pick-panel tile" style={px(half(otherSide(p.side), w, h))}>
        {p.chosen ? <Opening chosen={p.chosen} /> : <PickList tasks={tasks} dragged={p.id} sides={sides} onPick={pick} />}
      </div>
    </div>
  );
}

/** The dragged app in its half: its picture grows there from where the card was let go (FLIP, the spring). A tap cancels. */
function DockedHalf({ p, t, w, h, onCancel }: { p: CanvasPick; t?: RecentTask; w: number; h: number; onCancel: () => void }) {
  const docked = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const el = docked.current;
    if (!el) return;
    const to = el.getBoundingClientRect();
    const f = p.from;
    const scale = `scale(${f.width / Math.max(1, to.width)}, ${f.height / Math.max(1, to.height)})`;
    el.animate([{ transform: `translate(${f.left - to.left}px, ${f.top - to.top}px) ${scale}` }, { transform: "none" }], { duration: spring.ms, easing: spring.easing });
  }, []);
  const label = t?.label ?? "This app";
  const icon = t?.icon ?? null;
  return (
    <div ref={docked} class="canvas-pick-docked" style={px(half(p.side, w, h))} onClick={onCancel} aria-label={`${label} docked - tap to cancel`}>
      {t?.snapshot ? <img class="canvas-pick-shot" src={t.snapshot} alt="" draggable={false} /> : <ShotPlaceholder icon={icon} class="canvas-pick-shot" />}
      <div class="canvas-pick-head">
        {icon && <img class="canvas-pick-icon" src={icon} alt="" />}
        <span>{label}</span>
      </div>
    </div>
  );
}

/** The chosen app opening in its half (optimistic, till the canvas is up and the switcher goes). */
function Opening({ chosen }: { chosen: NonNullable<CanvasPick["chosen"]> }) {
  return (
    <div class="canvas-pick-opening">
      {chosen.icon && <img class="canvas-pick-opening-icon" src={chosen.icon} alt="" />}
      <span>Opening {chosen.label}…</span>
    </div>
  );
}

/**
 * The installed apps, asked from the host when the picker opens (not state.ts's list: state.ts imports the switcher, so
 * reading it here would be an import cycle). Empty till it answers: the recent apps are there at once.
 */
function useInstalled(): App[] {
  const [all, setAll] = useState<App[]>([]);
  useEffect(() => {
    let live = true;
    powos.apps.list().then(
      (l) => live && setAll(Array.isArray(l) ? l : []),
      (e) => console.warn(`[canvas] the picker's app list failed: ${e?.message ?? e}`),
    );
    return () => void (live = false);
  }, []);
  return all;
}

/** The picker: a search, the recent apps, then all apps. */
function PickList({ tasks, dragged, sides, onPick }: { tasks: RecentTask[]; dragged: number; sides: Set<number> | null; onPick: (c: Choice) => void }) {
  const [typed, setTyped] = useState("");
  const all = useInstalled();
  const { recent, rest } = choices({ tasks, all, dragged, sides, typed });
  return (
    <>
      <div class="canvas-pick-title">Pick the app for the other side</div>
      <input class="canvas-pick-search" type="search" placeholder="Search apps" value={typed} onInput={(e) => setTyped((e.currentTarget as HTMLInputElement).value)} />
      <div class="canvas-pick-list">
        {recent.length > 0 && <Section title="Recent" list={recent} recent onPick={onPick} />}
        <Section title={typed.trim() ? "Apps" : "All apps"} list={rest} onPick={onPick} />
        {!recent.length && !rest.length && <div class="canvas-pick-none muted">No app matches "{typed}"</div>}
      </div>
    </>
  );
}

function Section({ title, list, recent, onPick }: { title: string; list: Choice[]; recent?: boolean; onPick: (c: Choice) => void }) {
  return (
    <>
      <div class="canvas-pick-section">{title}</div>
      <div class={`canvas-pick-grid ${recent ? "recent" : ""}`}>
        {list.map((c) => (
          <ChoiceCell key={c.task != null ? `t${c.task}` : c.key} c={c} onPick={onPick} />
        ))}
      </div>
    </>
  );
}

function ChoiceCell({ c, onPick }: { c: Choice; onPick: (c: Choice) => void }) {
  return (
    <button type="button" class={`canvas-pick-app ${c.why ? "dim" : ""}`} data-key={c.key} data-task={c.task ?? undefined} title={c.why ?? undefined} onClick={() => onPick(c)}>
      {c.icon ? <img class="canvas-pick-app-icon" src={c.icon} alt="" draggable={false} /> : <span class="canvas-pick-app-icon blank" />}
      <span class="canvas-pick-app-label">{c.label}</span>
      {c.why && <span class="canvas-pick-app-why">{c.why}</span>}
    </button>
  );
}

/**
 * The pair started: the chosen app shown opening in its half at once (optimistic), then the host's Open Canvas start
 * with both apps. Refused: the picker back, with the reason. The switcher itself goes when the canvas comes up (the
 * host's recents.hide, as for any launch).
 */
function dock(p: CanvasPick, c: Choice, onNote: (text: string) => void) {
  const start = powos.tasks.canvasDock;
  canvasPick.value = { ...p, chosen: { label: c.label, icon: c.icon } };
  const other = c.task ?? c.key;
  const back = (reason: string) => {
    console.warn(`[canvas] dock of task ${p.id} (${p.side}) beside ${other} refused: ${reason}`);
    if (canvasPick.value?.id === p.id) canvasPick.value = { ...p, chosen: null };
    onNote(reason);
  };
  if (!start) return back("Not supported by this build yet");
  console.info(`[canvas] dock task ${p.id} ${p.side}, beside ${other} (picked)`);
  start(p.id, p.side, other).then(
    (r) => (r?.ok ? console.info(`[canvas] dock of task ${p.id} started`) : back(r?.reason || "Split view didn't open")),
    (e) => back(`Split view didn't open (${e?.message ?? e})`),
  );
}

/**
 * Progress, full screen: the road to PowOS as the user's everyday phone. What needs the user first, then the
 * daily-driver checklist by area (tap an area: its items, each with the board tasks it hangs on), then the board by what
 * each task means for the user, then what got done today. All live (lib/progress: both subscriptions), plain words.
 * Opened from the widget's blocker it scrolls to that task and opens it.
 */
import { useEffect, useState } from "preact/hooks";
import type { Props } from "../lib/app";
import {
  AREAS, LANES, OTHER, STATE_COLOR, STATE_NAME, age, areaOf, byAge, clock, doneToday, hackLine, isP0, laneOf, taskIds,
  takeFocus, useProgress, type Hack, type Item, type Lane, type WorkRow,
} from "../lib/progress";

const soft = "color-mix(in srgb, currentColor 7%, transparent)";

function TaskLine({ w, focus }: { w: WorkRow; focus: string | null }) {
  const lane = LANES.find((l) => l.key === laneOf(w))?.name.toLowerCase() ?? w.status;
  const detail = laneOf(w) === "try" ? w.tryLine : laneOf(w) === "you" ? w.note : w.step || w.note;
  return (
    <div id={`task-${w.id}`} style={{ ...S.task, ...(focus === w.id ? S.focused : null) }}>
      <div style={S.taskHead}>
        {isP0(w) && <span style={S.p0}>P0</span>}
        <span style={{ flex: 1, minWidth: 0 }}>{w.title}</span>
        <span style={S.dim}>{lane}</span>
      </div>
      {detail && <div style={S.detail}>{detail}</div>}
    </div>
  );
}

function ItemRow({ i, byId, focus }: { i: Item; byId: Map<string, WorkRow>; focus: string | null }) {
  const tasks = taskIds(i);
  return (
    <div style={S.item}>
      <div style={S.itemHead}>
        <span style={{ ...S.dot, background: STATE_COLOR[i.state] ?? STATE_COLOR.untested }} />
        <span style={{ flex: 1 }}>{i.capability}</span>
        <span style={S.dim}>{STATE_NAME[i.state] ?? i.state}</span>
      </div>
      {i.note && <div style={S.detail}>{i.note}</div>}
      {tasks.map((t) => {
        const w = byId.get(t);
        return w ? <TaskLine key={t} w={w} focus={focus} /> : <div key={t} style={S.detail}>task {t} isn't on the board</div>;
      })}
    </div>
  );
}

function Section({ title, count, open, toggle, children }: { title: string; count?: string; open: boolean; toggle: () => void; children: preact.ComponentChildren }) {
  return (
    <section style={S.section}>
      <button type="button" style={S.sectionHead} onClick={toggle}>
        <span style={{ flex: 1, textAlign: "left" }}>{title}</span>
        {count && <span style={S.dim}>{count}</span>}
        <span style={{ ...S.dim, transform: open ? "rotate(90deg)" : "none", display: "inline-block" }}>›</span>
      </button>
      {open && <div style={S.sectionBody}>{children}</div>}
    </section>
  );
}

function HackRow({ h, byId }: { h: Hack; byId: Map<string, WorkRow> }) {
  const w = h.task ? byId.get(h.task) : undefined;
  return (
    <div style={S.task}>
      <div style={S.taskHead}>
        <span style={{ flex: 1, minWidth: 0 }}>{hackLine(h)}</span>
        <span style={S.dim}>{age(h.since)}</span>
      </div>
      <div style={S.detail}>{h.area} · {h.file}:{h.line}</div>
      <div style={S.detail}>Why: {h.why}</div>
      {h.fix && <div style={S.detail}>Real fix: {h.fix}</div>}
      <div style={S.detail}>{w ? `Board: ${w.title} (${LANES.find((l) => l.key === laneOf(w))?.name.toLowerCase()})` : "No board task for the real fix yet"}</div>
    </div>
  );
}

const byArea = (ws: WorkRow[]) => [...AREAS, OTHER].map((a) => [a, ws.filter((w) => areaOf(w) === a)] as const).filter(([, l]) => l.length);

type P = ReturnType<typeof useProgress>;
type Open = Record<string, boolean>;
type Toggle = (k: string) => void;

function lanesOf(work: WorkRow[]) {
  const lanes = new Map<Lane, WorkRow[]>(LANES.map((l) => [l.key, []]));
  for (const w of work) lanes.get(laneOf(w))!.push(w);
  for (const l of lanes.values()) l.sort((a, b) => Number(isP0(b)) - Number(isP0(a)));
  return lanes;
}

/** Which sections are open, and the focus a widget handed over: a tapped blocker or the hacks. */
function useOpen(p: P, focus: string | null, byId: Map<string, WorkRow>) {
  const [open, setOpen] = useState<Open>({ you: true });
  const toggle = (k: string) => setOpen((o) => ({ ...o, [k]: !o[k] }));
  // A tapped blocker: open where its task is (its checklist area, else its lane) and scroll to it once it's drawn.
  const focusRow = focus ? byId.get(focus) : undefined;
  useEffect(() => {
    if (!focusRow) return;
    const area = p.items.find((i) => taskIds(i).includes(focusRow.id))?.area;
    setOpen((o) => ({ ...o, [area ? `area:${area}` : laneOf(focusRow)]: true }));
    requestAnimationFrame(() => document.getElementById(`task-${focusRow.id}`)?.scrollIntoView({ block: "center" }));
  }, [!!focusRow]);
  // The Hacks widget: open on the hacks.
  useEffect(() => {
    if (focus !== "hacks") return;
    setOpen((o) => ({ ...o, hacks: true }));
    requestAnimationFrame(() => document.getElementById("hacks")?.scrollIntoView({ block: "start" }));
  }, []);
  return [open, toggle] as const;
}

const plural = (n: number, one: string, many: string) => (n === 1 ? one : many);

function SummaryHeader({ p, close }: { p: P; close?: () => void }) {
  const works = p.items.filter((i) => i.state === "works").length;
  return (
    <>
      <header style={S.head}>
        <button style={S.back} onClick={close} aria-label="back">‹</button>
        <h1 style={S.title}>Road to daily driver</h1>
        <span style={S.big}>{p.pct === null ? "–" : `${p.pct}%`}</span>
      </header>
      <div style={S.summary}>
        {p.items.length ? `${works} of ${p.items.length} things work` : "The checklist isn't filled in yet"}
        {" · "}
        {p.on} being worked on · {p.you} {plural(p.you, "needs", "need")} you
        {" · "}
        {p.hacks.length} {plural(p.hacks.length, "hack", "hacks")} open
        {p.boardStatus !== "connected" && " · the board isn't reachable"}
      </div>
    </>
  );
}

function NeedsYou({ ws, open, toggle, focus }: { ws: WorkRow[]; open: Open; toggle: Toggle; focus: string | null }) {
  if (!ws.length) return null;
  return (
    <Section title="Needs you" count={String(ws.length)} open={!!open.you} toggle={() => toggle("you")}>
      {ws.map((w) => <TaskLine key={w.id} w={w} focus={focus} />)}
    </Section>
  );
}

function Checklist({ areas, byId, open, toggle, focus }: { areas: P["areas"]; byId: Map<string, WorkRow>; open: Open; toggle: Toggle; focus: string | null }) {
  return (
    <>
      {areas.length > 0 && <h2 style={S.h2}>Daily-driver checklist</h2>}
      {areas.map((a) => (
        <Section key={a.area} title={a.area} count={`${a.pct}%`} open={!!open[`area:${a.area}`]} toggle={() => toggle(`area:${a.area}`)}>
          {a.items.map((i) => <ItemRow key={i.id} i={i} byId={byId} focus={focus} />)}
        </Section>
      ))}
    </>
  );
}

function Board({ lanes, open, toggle, focus }: { lanes: Map<Lane, WorkRow[]>; open: Open; toggle: Toggle; focus: string | null }) {
  return (
    <>
      <h2 style={S.h2}>The board</h2>
      {LANES.filter((l) => l.key !== "you" && l.key !== "done").map((l) => {
        const ws = lanes.get(l.key)!;
        if (!ws.length) return null;
        return (
          <Section key={l.key} title={l.name} count={String(ws.length)} open={!!open[l.key]} toggle={() => toggle(l.key)}>
            {byArea(ws).map(([area, list]) => (
              <div key={area} style={S.group}>
                <div style={S.groupName}>{area}</div>
                {list.map((w) => <TaskLine key={w.id} w={w} focus={focus} />)}
              </div>
            ))}
          </Section>
        );
      })}
    </>
  );
}

function Hacks({ hacks, byId, open, toggle }: { hacks: Hack[]; byId: Map<string, WorkRow>; open: Open; toggle: Toggle }) {
  return (
    <>
      <h2 style={S.h2} id="hacks">Known hacks</h2>
      <Section title={`${hacks.length} open, oldest first`} open={!!open.hacks} toggle={() => toggle("hacks")}>
        {byAge(hacks).map((h) => <HackRow key={h.key} h={h} byId={byId} />)}
      </Section>
    </>
  );
}

function DoneToday({ work }: { work: WorkRow[] }) {
  const today = doneToday(work);
  return (
    <>
      <h2 style={S.h2}>Done today</h2>
      {today.length ? (
        <div style={S.timeline}>
          {today.map((w) => (
            <div key={w.id} style={S.tick}>
              <span style={S.time}>{clock(w.done)}</span>
              <span style={{ flex: 1 }}>{w.title}</span>
            </div>
          ))}
        </div>
      ) : (
        <div style={S.dim}>Nothing finished yet today</div>
      )}
    </>
  );
}

export default function Main({ host, close }: Props) {
  const p = useProgress(host);
  const [focus] = useState(() => takeFocus());
  const byId = new Map(p.work.map((w) => [w.id, w]));
  const [open, toggle] = useOpen(p, focus, byId);
  const lanes = lanesOf(p.work);
  return (
    <div style={S.page}>
      <SummaryHeader p={p} close={close} />
      <NeedsYou ws={lanes.get("you") ?? []} open={open} toggle={toggle} focus={focus} />
      <Checklist areas={p.areas} byId={byId} open={open} toggle={toggle} focus={focus} />
      <Board lanes={lanes} open={open} toggle={toggle} focus={focus} />
      <Hacks hacks={p.hacks} byId={byId} open={open} toggle={toggle} />
      <DoneToday work={p.work} />
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  page: { display: "flex", flexDirection: "column", gap: "10px", height: "100%", padding: "8px 16px 32px", boxSizing: "border-box", overflowY: "auto" },
  head: { display: "flex", alignItems: "center", gap: "8px" },
  back: { font: "inherit", fontSize: "28px", lineHeight: 1, background: "none", border: 0, color: "var(--color-accent, #8af)", padding: "0 8px 0 0" },
  title: { flex: 1, margin: 0, fontSize: "1.3em", fontWeight: 600 },
  big: { fontSize: "2em", fontWeight: 700, fontVariantNumeric: "tabular-nums" },
  summary: { opacity: 0.75, fontSize: "0.95em" },
  h2: { margin: "10px 0 0", fontSize: "0.85em", fontWeight: 600, opacity: 0.6, textTransform: "uppercase", letterSpacing: "0.04em" },
  section: { borderRadius: "14px", background: soft, overflow: "hidden" },
  sectionHead: { display: "flex", alignItems: "center", gap: "10px", width: "100%", font: "inherit", fontWeight: 600, background: "none", border: 0, color: "inherit", padding: "12px 14px" },
  sectionBody: { display: "flex", flexDirection: "column", gap: "8px", padding: "0 14px 12px" },
  group: { display: "flex", flexDirection: "column", gap: "6px" },
  groupName: { fontSize: "0.8em", opacity: 0.6 },
  item: { display: "flex", flexDirection: "column", gap: "6px", padding: "8px 0" },
  itemHead: { display: "flex", alignItems: "center", gap: "10px" },
  dot: { width: "10px", height: "10px", borderRadius: "50%", flex: "none" },
  task: { display: "flex", flexDirection: "column", gap: "3px", padding: "8px 10px", borderRadius: "10px", background: soft },
  focused: { outline: "2px solid var(--color-accent, #8af)" },
  taskHead: { display: "flex", alignItems: "baseline", gap: "8px" },
  p0: { fontSize: "0.75em", fontWeight: 700, color: "var(--color-red, #e0605a)" },
  detail: { fontSize: "0.85em", opacity: 0.7 },
  dim: { opacity: 0.6, fontSize: "0.9em" },
  timeline: { display: "flex", flexDirection: "column", gap: "6px" },
  tick: { display: "flex", gap: "12px", alignItems: "baseline" },
  time: { fontVariantNumeric: "tabular-nums", opacity: 0.6, fontSize: "0.85em", width: "3.2em", flex: "none" },
};

/**
 * The folded AI page as a status page, not a chat (the user, 2026-10-31 14:52: "In phone mode I already have the
 * launcher for the chat ... You wanna see the other shit"; 15:0x "more dynamic and futuristic"; 20:2x "the folded
 * version of the AI page" isn't any good). Fixed slots top to bottom, live content inside, the order never moves:
 * a slim header (the daily driver's small ring and one status line), Needs you (questions and things to do, answered in
 * place - needsyou.tsx's rows), Ready to try (the latest tries, works / still broken in place), Working now (the fleet's
 * live agents: task, step now, a thin bar that fills smoothly, the step cross-fading when it changes), Recently done
 * (closed, each at the time it was done; the user, 11-01 16:39: "I can't click these to expand" - a tap opens one in
 * place: the whole title, when, its closing note, its try line, how it was verified, and "Still broken" to reopen it). A section with nothing in it isn't drawn. At the foot the shared field to ask the manager (powai.tsx's
 * send path), its reply as one bubble over the field - never a transcript - and "Open chat": the launcher's AI panel.
 * Unfolded the same component is the page's left column (powai.tsx, [beside]): the chat is its right column, so its foot
 * keeps only the mic chip - no field, reply bubble or "Open chat" of its own.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { computed, signal } from "@preact/signals";
import { useAgents, type BoardCheck } from "../agents.ts";
import { fleet, isPowOS, projectOf, type Worker } from "../fleet.ts";
import { aiScreen, chat, openPanel, page } from "../state.ts";
import { board, boardSeen, checks, list, noteOf, WorkFeed, type WorkRow } from "./aiboard.tsx";
import { areaStats, driverPct } from "./aiprogress.tsx";
import { NeedStack } from "./aistack.tsx";
import { listen, listeningFor, release, speech, type MicTarget } from "./dictation.ts";
import { BrokenReply, clearBroken, type Broken } from "./brokenreply.tsx";
import { decidingOf, needIds, needsYou } from "./needsyou.tsx";
import { aiAgent } from "./aipanes.tsx";
import { clockAt } from "./time.ts";
import { recordVerdict } from "./trycard.tsx";

/** Done in this window shows under Recently done. */
const RECENT_MS = 3 * 24 * 3_600_000;
/** How long the reply bubble stays after the reply is complete (longer for more words, as the pet's). */
const replyMs = (text: string) => Math.min(14_000, 5_000 + text.length * 40);

/** "3 working · 1 needs you", or "All quiet". */
function statusLine(working: number, asks: number, busy: boolean) {
  const parts = [busy ? "manager working" : "", working ? `${working} working` : "", asks ? `${asks} need${asks === 1 ? "s" : ""} you` : ""];
  return parts.filter(Boolean).join(" · ") || (boardSeen.value ? "All quiet" : "…");
}

/** The ring's spring to a new value (ms; shell.css .ais-ring.moving). */
const RING_MS = 950;

/** The daily driver's ring (the hero, ~56 dp): the percentage inside. */
function HeroRing({ pct, label }: { pct: number; label: string }) {
  const r = 24;
  const c = 2 * Math.PI * r;
  // The fill springs only when the value changes (never on mount or at rest; off screen the page's CSS stops it).
  const last = useRef(pct);
  const [moving, setMoving] = useState(false);
  useEffect(() => {
    if (last.current === pct) return;
    last.current = pct;
    setMoving(true);
    const t = window.setTimeout(() => setMoving(false), RING_MS);
    return () => clearTimeout(t);
  }, [pct]);
  return (
    <span class={`ais-ring ${moving ? "moving" : ""}`} role="img" aria-label={`${label} ${pct}%`}>
      <svg viewBox="0 0 56 56" aria-hidden="true">
        <circle class="aip-ring-track" cx="28" cy="28" r={r} />
        <circle class="aip-ring-fill ais-ring-fill" cx="28" cy="28" r={r} stroke-dasharray={`${(c * pct) / 100} ${c}`} transform="rotate(-90 28 28)" />
      </svg>
      <span class="ais-ring-pct">{pct}</span>
    </span>
  );
}

/** The step text: the new one fades in while the old one fades out over it (opacity / transform only). */
function StepText({ text }: { text: string }) {
  const last = useRef(text);
  const [gone, setGone] = useState<string | null>(null);
  useEffect(() => {
    if (last.current === text) return;
    setGone(last.current);
    last.current = text;
    const t = window.setTimeout(() => setGone(null), 360);
    return () => clearTimeout(t);
  }, [text]);
  return (
    <span class="ais-step">
      {gone != null && gone !== text && (
        <span key={`o:${gone}`} class="ais-step-t out" aria-hidden="true">
          {gone}
        </span>
      )}
      <span key={`i:${text}`} class="ais-step-t in">
        {text}
      </span>
    </span>
  );
}

/** A thin bar under a working agent: its plan's share done, the fill sliding to each new value; no plan: a sweep. */
function LiveBar({ done, total }: { done: number; total: number }) {
  const k = total ? Math.min(1, done / total) : 0;
  return (
    <span class={`ais-bar ${total ? "" : "sweep"}`} role="progressbar" aria-valuemin={0} aria-valuemax={total} aria-valuenow={done} data-done={done} data-total={total}>
      <span class="ais-bar-fill" style={total ? { transform: `scaleX(${k})` } : undefined} />
    </span>
  );
}

/** One live agent: its task's title, what it's doing now, the bar; a tap opens Agents & terminals. */
function WorkRowLive({ x }: { x: Worker }) {
  const now = x.now || (isPowOS(x.a) ? "Working" : projectOf(x.a));
  return (
    <li class="ais-work">
      <button type="button" class="ais-work-row" onClick={() => (aiScreen.value = "agents")}>
        <span class="ais-work-line">
          <span class="aip-dot working" aria-hidden="true" />
          <span class="ais-work-title">{x.title}</span>
          {x.total > 0 && (
            <span class="ais-count">
              {x.done}/{x.total}
            </span>
          )}
        </span>
        <StepText text={now} />
        <LiveBar done={x.done} total={x.total} />
      </button>
    </li>
  );
}

/**
 * Unfolded, Working now lists PowOS's own agents only; the ⋯ menu's "Other projects (N)" adds the rest, each with its
 * project (the old context column's toggle, closed at first; the user's review 10-31 14:17: other projects' sessions
 * listed as if they were PowOS work). Folded lists both, PowOS's first.
 */
export const otherProjects = signal(false);

/** Working now: PowOS's own agents first, then other projects' (unfolded [beside]: only with otherProjects on), up to six. */
function WorkingNow({ working, beside }: { working: Worker[]; beside: boolean }) {
  const own = working.filter((x) => isPowOS(x.a));
  const other = working.filter((x) => !isPowOS(x.a));
  const shown = !beside ? [...own, ...other] : otherProjects.value ? [...own, ...other.map((x) => ({ ...x, now: x.now ? `${projectOf(x.a)} · ${x.now}` : projectOf(x.a) }))] : own;
  if (!shown.length) return null;
  return (
    <section class="ais-sec" data-sec="working" aria-label="Working now">
      <h3 class="ais-h">
        Working now<span class="ais-n">{shown.length}</span>
      </h3>
      <ul class="ais-list">
        {shown.slice(0, 6).map((x) => (
          <WorkRowLive key={x.a.id} x={x} />
        ))}
      </ul>
    </section>
  );
}

/** The ⋯ menu's "Other projects (N)" (unfolded): shows or hides other projects' agents under Working now; none: no item. */
export function OtherProjectsItem({ close }: { close: () => void }) {
  useAgents();
  const n = fleet().working.filter((x) => !isPowOS(x.a)).length;
  if (!n) return null;
  const on = otherProjects.value;
  return (
    <button type="button" role="menuitemcheckbox" aria-checked={on} class="ai-menu-item ai-menu-other" onClick={() => ((otherProjects.value = !on), close())}>
      Other projects ({n})
    </button>
  );
}

/** One stuck agent: why it's stuck, then its task; a tap opens it live in the right column's Agents view. */
function StuckRow({ x }: { x: Worker }) {
  return (
    <li class="ais-work">
      <button type="button" class="ais-work-row ais-stuck" onClick={() => ((aiAgent.value = x.a.id), (aiScreen.value = "fleet"))}>
        <span class="ais-work-line">
          <span class="aip-dot stuck" aria-hidden="true" />
          <span class="ais-work-title">{x.reason}</span>
        </span>
        <span class="ais-step">
          <span class="ais-step-t">{x.title}</span>
        </span>
      </button>
    </li>
  );
}

/** Needs attention (unfolded, under the needs-you stack): the fleet's stuck agents, up to six; none: not drawn. */
function NeedsAttention({ stuck }: { stuck: Worker[] }) {
  if (!stuck.length) return null;
  return (
    <section class="ais-sec" data-sec="attention" aria-label="Needs attention">
      <h3 class="ais-h">
        Needs attention<span class="ais-n">{stuck.length}</span>
      </h3>
      <ul class="ais-list">
        {stuck.slice(0, 6).map((x) => (
          <StuckRow key={x.a.id} x={x} />
        ))}
      </ul>
    </section>
  );
}

/** The board's tasks done in the last few days, newest first. */
export function recentlyDone(rows: WorkRow[] = board.value, now = Date.now()) {
  const at = (w: WorkRow) => Number(w.done || w.updated || 0);
  return rows.filter((w) => w.status === "done" && now - at(w) < RECENT_MS).sort((a, b) => at(b) - at(a));
}

/** Recently done shows this many rows, then a "more" row. */
const DONE_ROWS = 5;

/** [s], then ": [line]" when there is one. */
const withLine = (s: string, line: string) => (line ? `${s}: ${line}` : s);

/** How a done task was verified, in plain words: its last deciding check (the user's own, a phone check, none possible). */
export function verifiedOf(w: WorkRow, cs: BoardCheck[] = checks.value): string {
  const last = decidingOf(w, cs).at(-1);
  if (!last) return list(w.commits).length ? "fix landed, no phone check recorded" : "no check recorded";
  if (last.name === "you") return last.state === "PASS" ? "you said it works" : "you said it's still broken";
  if (last.state === "PASS") return "checked on the phone";
  if (last.state === "none") return withLine("no device check possible", last.line);
  return withLine("its last check failed", last.line);
}

/** "Still broken" sent from a done row: id -> the words (shown at once), or the one plain line when it couldn't be saved. */
const reopened = signal<Record<string, { text: string; failed?: boolean }>>({});

/** "Still broken" on a done task: reopened with the user's words through trycard.tsx's verdict path (a user FAIL). */
async function reopen(w: WorkRow, b: Broken) {
  reopened.value = { ...reopened.value, [w.id]: { text: b.text } };
  const ok = await recordVerdict({ id: w.id, title: w.title }, false, b);
  if (ok) clearBroken(`done:${w.id}`);
  else reopened.value = { ...reopened.value, [w.id]: { text: b.text, failed: true } };
}

/** "Still broken" and its reply line, or what the user said once it was sent. */
function ReopenActs({ w }: { w: WorkRow }) {
  const [replying, setReplying] = useState(false);
  const r = reopened.value[w.id];
  if (r && !r.failed) return <div class="ais-done-said">reopened - you said: "{r.text}"</div>;
  return (
    <>
      {r?.failed && <div class="ais-done-said error">couldn't save that - try again in a moment</div>}
      {replying ? (
        <BrokenReply id={`done:${w.id}`} onSend={(b) => (setReplying(false), void reopen(w, b))} onCancel={() => setReplying(false)} />
      ) : (
        <div class="try-acts">
          <button type="button" class="ai-act ais-done-broken" onClick={() => setReplying(true)}>
            Still broken
          </button>
        </div>
      )}
    </>
  );
}

/** A done row opened (its title unclipped above it): when it was done, its closing note, its try line, how it was verified. */
function DoneDetail({ w, when }: { w: WorkRow; when: string }) {
  const note = noteOf(w);
  const tryLine = w.tryLine?.trim();
  return (
    <div class="ais-done-detail">
      <div class="ais-done-fact" data-fact="when">Done {when}</div>
      {note && <div class="ais-done-fact" data-fact="note">{note}</div>}
      {tryLine && <div class="ais-done-fact" data-fact="try">Try: {tryLine}</div>}
      <div class="ais-done-fact" data-fact="verified">Verified: {verifiedOf(w)}</div>
      <ReopenActs w={w} />
    </div>
  );
}

/** One done task: its title and when it was done (the board's `done`, ms); a tap opens it in place (DoneDetail). */
function DoneRow({ w, open, onToggle }: { w: WorkRow; open: boolean; onToggle: () => void }) {
  const when = clockAt(Number(w.done || w.updated));
  return (
    <li class={`ais-done-item ${open ? "open" : ""}`} data-task={w.id}>
      <button type="button" class="ais-done-row" aria-expanded={open} onClick={onToggle}>
        <span class="ais-done-title">{w.title}</span>
        <span class="ais-when">{when}</span>
      </button>
      {open && <DoneDetail w={w} when={when} />}
    </li>
  );
}

/** Recently done: its heading a toggle, open at first; sized to its rows (DONE_ROWS, then "N more"). */
function RecentlyDone({ rows }: { rows: WorkRow[] }) {
  const [open, setOpen] = useState(true);
  const [all, setAll] = useState(false);
  const [openId, setOpenId] = useState<string | null>(null);
  if (!rows.length) return null;
  const shown = all ? rows.slice(0, 20) : rows.slice(0, DONE_ROWS);
  return (
    <section class="ais-sec" data-sec="done" aria-label="Recently done">
      <h3 class="ais-h">
        <button type="button" class="ais-toggle" aria-expanded={open} onClick={() => setOpen(!open)}>
          Recently done<span class="ais-n">{rows.length}</span>
          <span class="ais-chev" aria-hidden="true" />
        </button>
      </h3>
      {open && (
        <ul class="ais-list ais-done">
          {shown.map((w) => (
            <DoneRow key={w.id} w={w} open={openId === w.id} onToggle={() => setOpenId(openId === w.id ? null : w.id)} />
          ))}
          {rows.length > shown.length && (
            <li>
              <button type="button" class="ais-more" onClick={() => setAll(true)}>
                {rows.length - shown.length} more
              </button>
            </li>
          )}
        </ul>
      )}
    </section>
  );
}

/** What was last asked from this page (powai.tsx's send notes it here): its reply shows as one bubble, not a transcript. */
const asked = signal<{ text: string; at: number } | null>(null);
export const noteAsked = (text: string) => (asked.value = { text, at: Date.now() });

/** The manager's reply to it so far ("" while it thinks; null: nothing asked, or not its turn yet). */
const reply = computed(() => {
  const a = asked.value;
  if (!a) return null;
  const items = chat.value.items ?? [];
  const at = items.findLastIndex((i) => i.kind === "user" && i.text.startsWith(a.text));
  if (at < 0) return null;
  const r = items.slice(at + 1).findLast((i) => i.kind === "assistant");
  return r && r.kind === "assistant" ? r.text : "";
});

/** The reply bubble over the field: "…" while the manager works, its first lines when done, gone after a while. */
function ReplyBubble() {
  const r = reply.value;
  const busy = chat.value.busy;
  useEffect(() => {
    if (r == null || busy || !r) return;
    const t = window.setTimeout(() => (asked.value = null), replyMs(r));
    return () => clearTimeout(t);
  }, [r, busy]);
  if (!asked.value) return null;
  const text = r ? r.replace(/```[\s\S]*?(```|$)/g, "").replace(/\s+/g, " ").trim() : "";
  return (
    <button type="button" class="ais-reply" onClick={openChat} aria-live="polite">
      {text || (busy || r != null ? "thinking…" : "sent")}
    </button>
  );
}

/** The existing chat: the launcher's AI panel, over home. */
function openChat() {
  asked.value = null;
  page.value = 0;
  openPanel("ai");
}

/** A hold this long on the page's free space (not a card, a row or a button) talks to the manager. */
const HOLD_MS = 450;
const HOLD_SLOP = 10;
const TAKES_PRESS = "button, a, textarea, input, [data-owns-gesture], .ais-card-top, .ai-reply";

/** Hold anywhere to talk (as the field's mic held): the press starts listening, the release sends what was heard. */
function useHoldToTalk(mic: MicTarget) {
  const press = useRef<{ x: number; y: number; timer: number; held: boolean } | null>(null);
  const cancel = () => {
    const p = press.current;
    press.current = null;
    if (!p) return;
    clearTimeout(p.timer);
    if (p.held) release(mic);
  };
  return {
    onPointerDown: (e: PointerEvent) => {
      if ((e.target as Element).closest(TAKES_PRESS)) return;
      const p = { x: e.clientX, y: e.clientY, timer: 0, held: false };
      p.timer = window.setTimeout(() => ((p.held = true), void listen(true, mic)), HOLD_MS);
      press.current = p;
    },
    onPointerMove: (e: PointerEvent) => {
      const p = press.current;
      if (p && !p.held && Math.hypot(e.clientX - p.x, e.clientY - p.y) > HOLD_SLOP) cancel();
    },
    onPointerUp: cancel,
    onPointerCancel: cancel,
  };
}

/** The foot's chip: "Hold anywhere to talk", "Listening…" while the page's mic is on. */
function MicChip({ mic }: { mic: MicTarget }) {
  const on = listeningFor(mic) && speech.value.listening;
  return (
    <span class={`ais-mic ${on ? "on" : ""}`} aria-live="polite">
      <span class="ais-mic-dot" aria-hidden="true" />
      {on ? speech.value.text || "Listening…" : "Hold anywhere to talk"}
    </span>
  );
}

/** The foot folded: the reply bubble or the mic chip, "Open chat", the field. */
function Foot({ mic, compose }: { mic: MicTarget; compose: preact.ComponentChildren }) {
  return (
    <div class="ais-foot">
      <div class="ais-foot-row">
        <ReplyBubble />
        <MicChip mic={mic} />
        <button type="button" class="ais-open-chat" onClick={openChat}>
          Open chat
        </button>
      </div>
      {compose}
    </div>
  );
}

/** The hero's title, short enough never to be cut: "Daily driver 50%", or "66% this month" (the month's share done). */
const heroTitle = (r: { pct: number; label: string }) => (/this month/i.test(r.label) ? `${r.pct}% this month` : `${r.label} ${r.pct}%`);

/** The hero: the daily driver's ring and two lines - its name and share, then what's going on. */
function Hero({ needs, working, more }: { needs: number; working: number; more: preact.ComponentChildren }) {
  const ring = driverPct(areaStats(board.value, Date.now(), needIds(needsYou())));
  return (
    <header class="ais-top">
      {ring && <HeroRing pct={ring.pct} label={ring.label} />}
      <span class="ais-status">
        <span class="ais-title">{ring ? heroTitle(ring) : "PowOS AI"}</span>
        <span class="ais-line">{statusLine(working, needs, chat.value.busy)}</span>
      </span>
      {more}
    </header>
  );
}

/**
 * The status page: hero, sections, foot. [more]: the header's ⋯ (powai.tsx owns its menu); [compose]: its field;
 * [mic]: the field's mic target (a hold anywhere on the page talks into it); [beside]: the chat is beside it (unfolded).
 * Off screen ([shown] false) it is at rest.
 */
export function AiStatus(props: { shown: boolean; more: preact.ComponentChildren; compose?: preact.ComponentChildren; mic: MicTarget; beside?: boolean }) {
  const { shown, more, mic } = props;
  useAgents();
  const hold = useHoldToTalk(mic);
  const needs = needsYou();
  const f = fleet();
  const done = recentlyDone();
  const quiet = !needs.length && !f.working.length && !done.length;
  return (
    <>
      {shown && <WorkFeed />}
      <Hero needs={needs.length} working={f.working.length} more={more} />
      <div class="ai-scroll ais" {...hold}>
        <NeedStack needs={needs} />
        {props.beside && <NeedsAttention stuck={f.attention} />}
        <WorkingNow working={f.working} beside={!!props.beside} />
        <RecentlyDone rows={done} />
        {quiet && <div class="ais-empty">Nothing waits on you and no agent is working right now.</div>}
      </div>
      {props.beside ? (
        <div class="ais-foot">
          <MicChip mic={mic} />
        </div>
      ) : (
        <Foot mic={mic} compose={props.compose} />
      )}
    </>
  );
}

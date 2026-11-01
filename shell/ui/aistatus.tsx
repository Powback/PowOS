/**
 * The folded AI page as a status page, not a chat (the user, 2026-10-31 14:52: "In phone mode I already have the
 * launcher for the chat ... You wanna see the other shit"; 15:0x "more dynamic and futuristic"; 20:2x "the folded
 * version of the AI page" isn't any good). Fixed slots top to bottom, live content inside, the order never moves:
 * a slim header (the daily driver's small ring and one status line), Needs you (questions and things to do, answered in
 * place - needsyou.tsx's rows), Ready to try (the latest tries, works / still broken in place), Working now (the fleet's
 * live agents: task, step now, a thin bar that fills smoothly, the step cross-fading when it changes), Up next (the board's
 * queued tasks in line - accepted, waiting for an agent slot; the user, 11-01 17:1x: "I should be able to see the queue on
 * the AI page" - a one-line count when the page is busy; a tap opens one in place like Recently done's), Recently done
 * (closed, each at the time it was done; the user, 11-01 16:39: "I can't click these to expand" - a tap opens one in
 * place: the whole title, when, its closing note, its try line, how it was verified, and "Still broken" to reopen it). A section with nothing in it isn't drawn. At the foot the shared field to ask the manager (powai.tsx's
 * send path), its reply as one bubble over the field - never a transcript - and "Open chat": the launcher's AI panel.
 * Unfolded the same component is the page's left column (powai.tsx, [beside]): the chat is its right column, so its foot
 * has no field, reply bubble or "Open chat" of its own. No hold to talk anywhere (the user, 11-01 17:53: voice is the
 * shared bar's mic).
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { computed, signal } from "@preact/signals";
import { useAgents, type BoardCheck } from "../agents.ts";
import { fleet, isPowOS, projectOf, type Worker } from "../fleet.ts";
import { aiScreen, chat, openPanel, page } from "../state.ts";
import { board, boardSeen, checks, list, noteOf, WorkFeed, type WorkRow } from "./aiboard.tsx";
import { upNext, UpNext } from "./upnext.tsx";
import { areaStats, driverPct } from "./aiprogress.tsx";
import { NeedStack } from "./aistack.tsx";
import type { MicTarget } from "./dictation.ts";
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

/**
 * One live agent: its task's title, what it's doing now, the bar; a tap opens that agent live - its conversation - full
 * page (folded) or in the right column ([beside], unfolded; the user, 11-01 16:45: "navigate to the chats").
 */
function WorkRowLive({ x, beside }: { x: Worker; beside: boolean }) {
  const now = x.now || (isPowOS(x.a) ? "Working" : projectOf(x.a));
  return (
    <li class="ais-work">
      <button type="button" class="ais-work-row" onClick={() => ((aiAgent.value = x.a.id), (aiScreen.value = "fleet"))}>
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
          <WorkRowLive key={x.a.id} x={x} beside={beside} />
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

/** The page is busy (Up next folds to its count): something needs the user, or three or more agents are working. */
const BUSY_WORKING = 3;
const busyPage = (needs: number, working: number) => needs > 0 || working >= BUSY_WORKING;

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

/** The existing chat: the launcher's AI panel, over home (folded: the ⋯ menu's "Open chat"). */
export function openChat() {
  asked.value = null;
  page.value = 0;
  openPanel("ai");
}

/** The foot without a chat below the status: the reply bubble, "Open chat", the field (no hold to talk: the user, 11-01 17:53). */
function Foot({ compose }: { compose: preact.ComponentChildren }) {
  return (
    <div class="ais-foot">
      <div class="ais-foot-row">
        <ReplyBubble />
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

/** The hero: the daily driver's ring and two lines - its name and share, then what's going on. [onTap]: folded, the strip's tap. */
function Hero({ needs, working, more, onTap }: { needs: number; working: number; more: preact.ComponentChildren; onTap?: () => void }) {
  const ring = driverPct(areaStats(board.value, Date.now(), needIds(needsYou())));
  const tap = onTap && ((e: MouseEvent) => !(e.target as Element).closest(".ai-more") && onTap());
  return (
    <header class={`ais-top ${onTap ? "ais-strip" : ""}`} onClick={tap}>
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
 * [mic]: the field's mic target (kept for the shared bar's seam, nothing here listens); [beside]: the chat is beside it (unfolded).
 * Off screen ([shown] false) it is at rest.
 */
export function AiStatus(props: { shown: boolean; more: preact.ComponentChildren; compose?: preact.ComponentChildren; mic: MicTarget; beside?: boolean; chat?: preact.ComponentChildren }) {
  useAgents();
  if (props.chat) return <Stacked {...props} chat={props.chat} />;
  return <StatusPage {...props} />;
}

/** The status page alone (unfolded's left column; folded without a chat below it): hero, sections, foot. */
function StatusPage(props: { shown: boolean; more: preact.ComponentChildren; compose?: preact.ComponentChildren; mic: MicTarget; beside?: boolean }) {
  const { shown, more } = props;
  const needs = needsYou();
  const f = fleet();
  const done = recentlyDone();
  const next = upNext();
  const quiet = !needs.length && !f.working.length && !done.length && !next.length;
  return (
    <>
      {shown && <WorkFeed />}
      <Hero needs={needs.length} working={f.working.length} more={more} />
      <div class="ai-scroll ais">
        <NeedStack needs={needs} />
        {props.beside && <NeedsAttention stuck={f.attention} />}
        <WorkingNow working={f.working} beside={!!props.beside} />
        <UpNext rows={next} busy={busyPage(needs.length, f.working.length)} />
        <RecentlyDone rows={done} />
        {quiet && <div class="ais-empty">Nothing waits on you and no agent is working right now.</div>}
      </div>
      {!props.beside && <Foot compose={props.compose} />}
    </>
  );
}

/** Folded (the manager's design, 11-01): Working now / Up next / Recently done folded into one row, open at a tap. */
export const foldOpen = signal(false);
/** Folded: the status shrunk to the strip (the chat scrolled up), until a pull down at the chat's top or a tap on the strip. */
export const foldShrunk = signal(false);

/** The chat scrolled this far from the newest shrinks the status to the strip; a pull this far at its top brings it back. */
const SHRINK_PX = 60;
const PULL_PX = 48;
/** While the status springs back (and the chat's scroll position settles under it), no scroll shrinks it again. */
const SETTLE_MS = 700;
let calmUntil = 0;
const unshrink = () => ((calmUntil = Date.now() + SETTLE_MS), (foldShrunk.value = false));

/** The chat's scroller in [wrap]; at its top (the oldest end of the column-reverse list). */
const chatIn = (wrap: HTMLElement | null) => wrap?.querySelector<HTMLElement>(".ai-chat") ?? null;
const atTop = (el: HTMLElement) => el.scrollHeight - el.clientHeight - Math.abs(el.scrollTop) < 2;

/** The chat [at] px from its newest shrinks the status: past SHRINK_PX, not already, not while it springs back. */
const shrinks = (at: number) => at > SHRINK_PX && !foldShrunk.value && Date.now() > calmUntil;

/** The collapsing header: scrolling the chat up shrinks the status; a pull down (touch or wheel) at its top re-expands. */
function useCollapse(wrap: preact.RefObject<HTMLDivElement>) {
  useEffect(() => {
    const w = wrap.current;
    if (!w) return;
    let from: number | null = null;
    // Only a scroll further from the newest shrinks it (a layout change's own scroll event, e.g. the status coming back, doesn't).
    // A scroll that comes with a change of the chat's height is the layout's (the status folding), never the user's.
    let last = 0;
    let tall = 0;
    const onScroll = () => {
      const el = chatIn(w);
      if (!el) return;
      const at = Math.abs(el.scrollTop);
      const same = !tall || el.clientHeight === tall;
      tall = el.clientHeight;
      if (same && at > last + 1 && shrinks(at)) foldShrunk.value = true;
      last = at;
    };
    const onStart = (e: TouchEvent) => {
      const el = chatIn(w);
      from = el && atTop(el) ? e.touches[0].clientY : null;
    };
    const onMove = (e: TouchEvent) => {
      if (from != null && e.touches[0].clientY - from > PULL_PX) (unshrink(), (from = null));
    };
    const onWheel = (e: WheelEvent) => {
      const el = chatIn(w);
      if (el && e.deltaY < 0 && atTop(el)) unshrink();
    };
    w.addEventListener("scroll", onScroll, { capture: true, passive: true });
    w.addEventListener("touchstart", onStart, { passive: true });
    w.addEventListener("touchmove", onMove, { passive: true });
    w.addEventListener("wheel", onWheel, { passive: true });
    return () => {
      w.removeEventListener("scroll", onScroll, { capture: true });
      w.removeEventListener("touchstart", onStart);
      w.removeEventListener("touchmove", onMove);
      w.removeEventListener("wheel", onWheel);
    };
  }, []);
}

/** Done today (local day), of Recently done's rows. */
const doneToday = (rows: WorkRow[]) => rows.filter((w) => new Date(Number(w.done || w.updated)).toDateString() === new Date().toDateString()).length;

/** The one summary row: "3 working · 12 done today ▾", a tiny dot per working agent; a tap opens the sections in place. */
function FoldSummary({ working, done, next }: { working: number; done: WorkRow[]; next: number }) {
  const open = foldOpen.value;
  const words = [`${working} working`, `${doneToday(done)} done today`, next ? `${next} up next` : ""].filter(Boolean).join(" · ");
  return (
    <button type="button" class="ais-sum" aria-expanded={open} onClick={() => (foldOpen.value = !open)}>
      <span class="ais-sum-dots" aria-hidden="true">
        {Array.from({ length: Math.min(working, 8) }, (_, i) => (
          <span key={i} class="ais-sum-dot" />
        ))}
      </span>
      <span class="ais-sum-text">{words}</span>
      <span class="ais-chev" aria-hidden="true" />
    </button>
  );
}

/** The strip's tap: shrunk, the status back; else the summary opened or closed. */
const stripTap = () => (foldShrunk.value ? unshrink() : (foldOpen.value = !foldOpen.value));

/**
 * The folded page (the manager's design, 11-01; the user, 17:05: "collapse working now and recently done and then show
 * the chat underneath"): the unfolded columns stacked under a collapsing header - the strip (ring + one line), Needs you
 * when there is any, one summary row over Working now / Up next / Recently done, then the live chat filling the rest
 * and [compose] (the tabs and the field) at the foot.
 */
function Stacked(props: { shown: boolean; more: preact.ComponentChildren; compose?: preact.ComponentChildren; mic: MicTarget; chat: preact.ComponentChildren }) {
  const { shown, more } = props;
  const wrap = useRef<HTMLDivElement>(null);
  useCollapse(wrap);
  const needs = needsYou();
  const f = fleet();
  const done = recentlyDone();
  const next = upNext();
  const open = foldOpen.value;
  const any = f.working.length + done.length + next.length > 0;
  return (
    <>
      {shown && <WorkFeed />}
      <Hero needs={needs.length} working={f.working.length} more={more} onTap={stripTap} />
      <div class={`ais-fold ${foldShrunk.value ? "shrunk" : ""}`} inert={foldShrunk.value}>
        <div class="ai-scroll ais">
          <NeedStack needs={needs} />
          {any && <FoldSummary working={f.working.length} done={done} next={next.length} />}
          <div class={`ais-sum-body ${open ? "open" : ""}`} inert={!open}>
            <div class="ais-sum-in">
              <WorkingNow working={f.working} beside={false} />
              <UpNext rows={next} busy={busyPage(needs.length, f.working.length)} />
              <RecentlyDone rows={done} />
            </div>
          </div>
        </div>
      </div>
      <div ref={wrap} class="ais-chat-wrap">
        {props.chat}
      </div>
      {props.compose}
    </>
  );
}

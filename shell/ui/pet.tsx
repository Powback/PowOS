/**
 * The pet: the face of PowOS's agents, a small creature floating over home and the PowOS AI page (a corner by default;
 * dragged anywhere, it stays there). It isn't another AI app - it shows what the agents and the phone are doing, from
 * live data only:
 *   working   an agent is working (the agents' spool, agents.ts - what `powos agents` and the Agents view read)
 *   looking   something waits on you: an agent needs you, an approval ask, a task "waiting" on the work board
 *             (powos-agents `work`), or unread mail from an agent
 *   worried   a shell error on this page, or a deploy note saying something failed / was rolled back
 *   sleepy    night (23-7), or nobody touched home for a while
 *   hungry    battery under 20% and not charging
 *   happy     a task just got done: a small jump
 * An agent can set a mood for a while (`powos pet mood`, `powos pet say --mood`): the local.pet app's module (apps/pet).
 *
 * One assistant (ui/assistant.ts): the pet is the face and notifier of the ONE conversation (the manager's) and its
 * ONE chat surface, home's search pill in chat mode. Tap it: it listens right there - its bubble shows what it hears,
 * then the reply, a few lines; nothing else opens (a tap on that bubble opens the chat surface). While the chat surface
 * is open the pet sits on it, by the pill. Otherwise the pet only speaks in short bubbles (3-6 s, one at a time,
 * lines arriving together batched; a tap opens them, "more" opens PowOS AI's page): what's said through it (`powos pet
 * say`), deploy notes and agents' mail as they arrive (their notifications stay), and the manager's answers nobody
 * was looking at. Long press: PowOS AI's page (the conversation's history and the work board).
 *
 * Cost: it animates only when its state changes (a short CSS animation on the compositor, then still); no timers while
 * the page is hidden; its sockets go with the page (apps/stdb.ts).
 */
import { computed, effect, signal } from "@preact/signals";
import { useEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { carry, chat, chatting, closeDrawer, editing, menu, openPanel, page, pullPanels, stored } from "../state.ts";
import { drawerOpen, notifOpen } from "./gesture.ts";
import { dictate, hearing, speech, type MicTarget } from "./dictation.ts";
import { askQueued, openAssistant } from "./assistant.ts";
import { agent, agentIds, asks, tasks, useAgents } from "../agents.ts";
import { useDb, useRows } from "../apps/stdb.ts";
import { installedApps } from "../apps/pages.ts";
import { DbConnection as PetDb } from "../vendor/local-pet.js";
import { DbConnection as AgentsDb } from "../vendor/powos-agents.js";
import type { AgentMail } from "../types.ts";

// HACK: the stylesheet is linked from here, not index.html, so the pet ships as files of its own while other agents
// edit index.html. Real fix: a <link> in index.html next to the others once this settles (data-hot: hot-swapped alike).
if (!document.querySelector('link[href="./ui/pet.css"]')) {
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = "./ui/pet.css";
  link.dataset.hot = "";
  document.head.append(link);
}

const APP = "local.pet";

type State = "idle" | "happy" | "working" | "looking" | "worried" | "sleepy" | "hungry" | "listening";

const SIZE = 52;
const MARGIN = 10;
/** Untouched this long (home shown): sleepy. */
const IDLE_MS = 3 * 60_000;
/** A shell error keeps it worried this long; a failed deploy, this long. */
const ERROR_MS = 5 * 60_000;
const DEPLOY_MS = 15 * 60_000;
const LONG_MS = 550;
const MOVE_PX = 8;

// ---- where it is ----------------------------------------------------------------------------------------------------

/** Where it sits: fractions of the free space across and down (the right edge, two thirds down, at first). */
const where = stored("pet.pos", JSON.stringify({ x: 1, y: 0.68 }));
const pos = () => {
  try {
    const p = JSON.parse(where.value);
    return { x: Math.min(1, Math.max(0, +p.x || 0)), y: Math.min(1, Math.max(0, +p.y || 0)) };
  } catch {
    return { x: 1, y: 0.68 };
  }
};
const toPx = (p: { x: number; y: number }) => ({
  left: MARGIN + p.x * Math.max(0, innerWidth - SIZE - 2 * MARGIN),
  top: MARGIN + p.y * Math.max(0, innerHeight - SIZE - 2 * MARGIN),
});

// ---- what it knows --------------------------------------------------------------------------------------------------

/** Now, as a signal: bumped by the few timers below (only while shown) so the time-based states move. */
const clock = signal(Date.now());
const tick = () => (clock.value = Date.now());
const touched = signal(Date.now());
const battery = signal<{ level: number | null; charging: boolean }>({ level: null, charging: true });
const worriedUntil = signal(0);
const mailNow = signal<AgentMail[]>([]);
/** The work board's rows waiting on the user (powos-agents `work`). */
const waiting = signal(0);
/** An agent's mood (the module's pet row), until when (ms). */
const moodSet = signal<{ mood: string; until: number }>({ mood: "", until: 0 });
/** A task just got done: the jump (cleared when it ends). */
const jump = signal(0);
const name = signal("Pow");

const night = (t: number) => {
  const h = new Date(t).getHours();
  return h >= 23 || h < 7;
};

const busy = computed(() =>
  agentIds.value.some((id) => {
    const a = agent(id)?.value;
    return a?.state === "working" && !a.id.includes("/");
  }),
);
const needsYou = computed(() => {
  const t = clock.value;
  return (
    waiting.value > 0 ||
    asks.value.some((a) => a.answer == null && a.expires > t) ||
    agentIds.value.some((id) => agent(id)?.value.state === "needs_you") ||
    mailNow.value.some((m) => m.from !== "deploy")
  );
});

const state = computed<State>(() => {
  const t = clock.value;
  if ((listening.value && chatOpen.value) || petListening.value) return "listening";
  if (talk.value?.asked && !talk.value.done) return "working";
  if (chatOpen.value && chat.value.busy) return "working";
  const m = moodSet.value;
  if (m.mood && m.until > t) return m.mood as State;
  if (jump.value) return "happy";
  if (worriedUntil.value > t) return "worried";
  if (needsYou.value) return "looking";
  const b = battery.value;
  if (b.level != null && b.level < 20 && !b.charging) return "hungry";
  if (busy.value) return "working";
  if (night(t) || t - touched.value > IDLE_MS) return "sleepy";
  return "idle";
});

// Errors on this page (index.html reports them to the app too): worried for a while. Not the browser's
// ResizeObserver note (nothing failed - as index.html leaves it out).
addEventListener("error", (ev) => {
  if (!(ev as ErrorEvent).error && /^ResizeObserver loop/.test((ev as ErrorEvent).message || "")) return;
  worriedUntil.value = Date.now() + ERROR_MS;
});
addEventListener("unhandledrejection", () => (worriedUntil.value = Date.now() + ERROR_MS));

// ---- the bubble -----------------------------------------------------------------------------------------------------

interface Line {
  text: string;
  from: string;
}
const bubble = signal<{ lines: Line[]; open: boolean } | null>(null);
let hideTimer = 0;

/** How long a bubble stays: 3 s, longer for more words, at most 6 s. */
const holdMs = (text: string) => Math.min(6000, Math.max(3000, 1800 + text.length * 45));

function armHide() {
  clearTimeout(hideTimer);
  const b = bubble.peek();
  if (!b || b.open || document.hidden) return;
  hideTimer = window.setTimeout(() => (bubble.value = null), holdMs(b.lines.at(-1)!.text));
}

/** A line to say: into the bubble showing (batched with what's there), or a new one. */
function say(line: Line) {
  const text = line.text.replace(/\s+/g, " ").trim();
  if (!text) return;
  const b = bubble.peek();
  bubble.value = { lines: [...(b?.lines ?? []), { ...line, text }].slice(-8), open: b?.open ?? false };
  armHide();
}

document.addEventListener("visibilitychange", () => {
  if (document.hidden) clearTimeout(hideTimer);
  else armHide();
});

// ---- the chat surface ------------------------------------------------------------------------------------------------

/**
 * The one chat surface (ui/assistant.ts): home's search pill in chat mode. While it's open the pet sits on it as its
 * face (busy while a turn runs, all ears while the recognizer is) and says nothing itself - the chat shows the words.
 */
const chatOpen = computed(() => drawerOpen.value && chatting.value);
const listening = computed(() => speech.value.listening);

// ---- talking, right there --------------------------------------------------------------------------------------------

/**
 * A tap on the pet: it listens where it is - its bubble shows what it hears, then the manager's reply (a few lines).
 * Nothing else opens; a tap on that bubble opens the full chat surface. The question goes the one way every ask goes
 * (assistant.ts askQueued: one conversation, waiting for a turn under way).
 */
const talk = signal<{ asked: string | null; done: boolean } | null>(null);
const petListening = signal(false);
let talkTimer = 0;
const petMic: MicTarget = {
  typed: () => "",
  started: () => (petListening.value = true),
  heard: (full) => {
    petListening.value = false;
    const text = full.trim();
    if (!text) {
      talk.value = null;
      return;
    }
    talk.value = { asked: text, done: false };
    askQueued(text);
  },
};
// The recognizer stopped without a result (an error, cancelled, unavailable): the talk bubble goes.
effect(() => {
  if (!speech.value.listening && petListening.value && speech.value.error) {
    petListening.value = false;
    talk.value = null;
  }
});

/** The reply to what was asked through the pet so far ("" until it starts; null: not asked yet - waiting its turn). */
const reply = computed(() => {
  const t = talk.value;
  if (!t?.asked) return null;
  const items = chat.value.items;
  const at = items.findLastIndex((i) => i.kind === "user" && (i as { text: string }).text.startsWith(t.asked!));
  if (at < 0) return null;
  const a = items.slice(at + 1).findLast((i) => i.kind === "assistant") as { text: string } | undefined;
  return a?.text ?? "";
});
// The reply finished: shown a while (longer for more words), then the bubble goes - unless it was tapped open.
effect(() => {
  const t = talk.value;
  const r = reply.value;
  const busy = chat.value.busy;
  if (!t || t.done || r == null || busy || !r) return;
  talk.value = { ...t, done: true };
  clearTimeout(talkTimer);
  talkTimer = window.setTimeout(() => (talk.value = null), Math.min(12000, 4000 + r.length * 40));
});

/** PowOS AI: its pull-up panel while that experiment is on (state.ts pullPanels), else its page left of home. */
function openAi() {
  if (pullPanels.peek() === "on") openPanel("ai");
  else page.value = -1;
}

function startTalk() {
  clearTimeout(talkTimer);
  bubble.value = null;
  talk.value = { asked: null, done: false };
  dictate(petMic);
  // The recognizer didn't start (no mic, unavailable): not left listening.
  window.setTimeout(() => {
    if (talk.value?.asked == null && !speech.value.listening) {
      petListening.value = false;
      if (talk.value && !talk.value.asked) talk.value = null;
    }
  }, 2500);
}

/** Its talk bubble: what it hears, then the reply - a tap opens the full chat surface. */
function TalkBubble({ style, cls }: { style: Record<string, string>; cls: string }) {
  const t = talk.value!;
  const heard = petListening.value ? (hearing(petMic) ?? "") : null;
  const r = reply.value;
  return (
    <div
      class={`pet-bubble tile pet-talk ${cls}`}
      style={style}
      onPointerDown={(e) => e.stopPropagation()}
      onClick={() => {
        clearTimeout(talkTimer);
        talk.value = null;
        if (petListening.value) powos.speech.stop();
        openAssistant();
      }}
    >
      {heard != null ? (
        <div class="pet-line">{heard || <span class="muted">listening…</span>}</div>
      ) : (
        <>
          {t.asked && <div class="pet-line pet-asked muted">{t.asked}</div>}
          <div class="pet-line pet-short pet-reply">
            {r == null ? <span class="muted">{chat.value.busy ? "it's busy - asking when it's done" : "…"}</span> : r || <span class="muted">thinking…</span>}
          </div>
        </>
      )}
    </div>
  );
}

/** The chat's latest turn: its answer so far. */
function latestAnswer() {
  const items = chat.value.items;
  const at = items.findLastIndex((i) => i.kind === "user");
  const answer = items.slice(at + 1).findLast((i) => i.kind === "assistant") as { text: string } | undefined;
  return answer?.text ?? "";
}

let wasBusy = chat.peek().busy;
effect(() => {
  const c = chat.value;
  // A turn ended (the manager answering mail, or a question asked and the chat closed since) with nobody looking at
  // the conversation - not the chat surface, not PowOS AI's page: a short bubble.
  if (wasBusy && !c.busy && !chatOpen.peek() && page.peek() !== -1 && !talk.peek()) {
    const a = latestAnswer();
    if (a) say({ text: a.slice(0, 160), from: "manager" });
  }
  wasBusy = c.busy;
});

// ---- mail: deploy notes and what agents tell the user ------------------------------------------------------------------

const FAILED = /\b(fail(ed|s|ure)?|rolled back|roll(ed)?back|broke(n)?|error)\b/i;
let mailSeen: Set<string> | null = null;
function gotMail(list: AgentMail[]) {
  mailNow.value = list;
  const key = (m: AgentMail) => m.id ?? `${m.from}-${m.time}`;
  if (!mailSeen) {
    mailSeen = new Set(list.map(key));
    return;
  }
  const fresh = list.filter((m) => !mailSeen!.has(key(m))).reverse();
  for (const m of list) mailSeen.add(key(m));
  for (const m of fresh) {
    if (m.from === "deploy" && FAILED.test(m.text)) worriedUntil.value = Date.now() + DEPLOY_MS;
    say({ text: m.text, from: m.from });
  }
}
powos.on("ai.mail", gotMail);
powos.ai.mail().then(gotMail, () => {});

// ---- the module, the work board and the clocks: subscribed while home is shown ------------------------------------

interface PetRow {
  name: string;
  mood: string;
  moodUntil: bigint | number;
}
interface SaidRow {
  id: bigint | number;
  text: string;
  from: string;
  mood: string;
  at: bigint | number;
}
interface WorkRow {
  id: string;
  status: string;
}

/**
 * When the newest line the bubble showed was said (ms; kept: what's said while home is away shows when it's back).
 * The first time ever: now - nothing from before the pet existed here.
 */
const saidSeen = stored("pet.saidAt", String(Date.now()));

function PetFeed() {
  const db = useDb("local-pet", PetDb);
  const pets = useRows<PetRow>(db, "pet", "SELECT * FROM pet");
  const said = useRows<SaidRow>(db, "said", "SELECT * FROM said");
  const adb = useDb("powos-agents", AgentsDb);
  const work = useRows<WorkRow>(adb, "work", "SELECT * FROM work");
  useAgents();
  petConn = db.status === "connected" ? db.conn : null;
  useEffect(() => {
    const p = pets[0];
    if (!p) return;
    name.value = p.name;
    moodSet.value = { mood: p.mood, until: Number(p.moodUntil) };
  }, [pets]);
  useEffect(() => {
    if (!said.length) return;
    const last = Number(saidSeen.value) || Date.now();
    const fresh = said.filter((s) => Number(s.at) > last).sort((a, b) => Number(a.id) - Number(b.id));
    for (const s of fresh) say({ text: s.text, from: s.from });
    if (fresh.length) saidSeen.value = String(Math.max(...fresh.map((s) => Number(s.at))));
  }, [said]);
  // The board: what waits on the user, and a task going done - a jump (once per task).
  const statuses = useRef<Map<string, string> | null>(null);
  useEffect(() => {
    if (adb.status !== "connected" || !work.length) return;
    waiting.value = work.filter((w) => w.status === "waiting").length;
    const was = statuses.current;
    statuses.current = new Map(work.map((w) => [w.id, w.status]));
    if (was && work.some((w) => w.status === "done" && was.has(w.id) && was.get(w.id) !== "done")) cheer();
  }, [work, adb.status]);
  // The agents' own task lists (the spool): one going done is a jump too.
  const spoolDone = useRef<Set<string> | null>(null);
  useEffect(
    () =>
      effect(() => {
        const done = new Set<string>();
        for (const l of tasks.value.values()) for (const t of l) if (t.status === "done") done.add(t.id);
        const was = spoolDone.current;
        spoolDone.current = done;
        if (was && [...done].some((id) => !was.has(id))) cheer();
      }),
    [],
  );
  return null;
}

/** The module's connection while home shows (PetFeed's): the jump's xp goes to it. */
let petConn: any = null;
let jumpTimer = 0;
function cheer() {
  jump.value = Date.now();
  clearTimeout(jumpTimer);
  jumpTimer = window.setTimeout(() => (jump.value = 0), 1400);
  try {
    petConn?.reducers?.cheer?.({ xp: 2 })?.catch?.(() => {});
  } catch {}
}

/** The clocks a state needs, while home shows: the next mood/worry end, idle, night, battery. Nothing while hidden. */
function useClocks(shown: boolean) {
  useEffect(() => {
    if (!shown) return;
    const readBattery = () => powos.system.battery().then((b) => (battery.value = b), () => {});
    readBattery();
    tick();
    const battTimer = window.setInterval(readBattery, 5 * 60_000);
    const touch = () => {
      touched.value = Date.now();
      if (state.peek() === "sleepy") tick();
    };
    addEventListener("pointerdown", touch, { capture: true, passive: true });
    return () => {
      clearInterval(battTimer);
      removeEventListener("pointerdown", touch, { capture: true });
    };
  }, [shown]);
  // One timer: to the next moment the state could change by time alone.
  const t = clock.value;
  const next = Math.min(
    ...[moodSet.value.until, worriedUntil.value, touched.value + IDLE_MS, nextNightEdge(t)].filter((x) => x > t),
  );
  useEffect(() => {
    if (!shown || !Number.isFinite(next)) return;
    const timer = window.setTimeout(tick, Math.min(next - Date.now() + 50, 2 ** 31 - 1));
    return () => clearTimeout(timer);
  }, [shown, next]);
}

function nextNightEdge(t: number) {
  const d = new Date(t);
  const edge = new Date(d);
  edge.setMinutes(0, 0, 0);
  edge.setHours(night(t) ? 7 : 23);
  if (edge.getTime() <= t) edge.setDate(edge.getDate() + 1);
  return edge.getTime();
}

// ---- the creature ---------------------------------------------------------------------------------------------------

function Sprite() {
  return (
    <svg class="pet-svg" viewBox="0 0 52 52" width={SIZE} height={SIZE} aria-hidden="true">
      <path class="pet-shape" d="M26 6c11 0 20 8.5 20 21.5C46 39 38 46 26 46S6 39 6 27.5C6 14.5 15 6 26 6z" />
      <g class="pet-face">
        <g class="pet-eyes">
          <ellipse class="pet-eye open" cx="19" cy="25" rx="3" ry="3.6" />
          <ellipse class="pet-eye open" cx="33" cy="25" rx="3" ry="3.6" />
          <path class="pet-eye closed" d="M15.5 26q3.5 2.5 7 0M29.5 26q3.5 2.5 7 0" />
          <path class="pet-eye glad" d="M15.5 26.5q3.5-4 7 0M29.5 26.5q3.5-4 7 0" />
        </g>
        <path class="pet-brows" d="M15 19.5l6 1.8M37 19.5l-6 1.8" />
        <path class="pet-mouth smile" d="M22 33q4 3 8 0" />
        <path class="pet-mouth flat" d="M22.5 34h7" />
        <path class="pet-mouth wavy" d="M21 34q2-2 4 0t4 0t2 0" />
        <ellipse class="pet-mouth open" cx="26" cy="34" rx="2.6" ry="2.2" />
      </g>
      <text class="pet-z" x="40" y="12">z</text>
    </svg>
  );
}

function Bubble({ at }: { at: { left: number; top: number } }) {
  const b = bubble.value;
  if (!b && !talk.value) return null;
  const right = at.left + SIZE / 2 > innerWidth / 2;
  const below = at.top < 140;
  const style: Record<string, string> = {
    [right ? "right" : "left"]: `${Math.max(MARGIN, right ? innerWidth - at.left - SIZE : at.left)}px`,
    [below ? "top" : "bottom"]: below ? `${at.top + SIZE + 6}px` : `${innerHeight - at.top + 6}px`,
  };
  if (talk.value) return <TalkBubble style={style} cls={`${right ? "right" : "left"} ${below ? "below" : "above"}`} />;
  if (!b) return null;
  const lines = b.lines;
  const last = lines.at(-1);
  return (
    <div
      class={`pet-bubble tile ${b.open ? "open" : ""} ${right ? "right" : "left"} ${below ? "below" : "above"}`}
      style={style}
      onPointerDown={(e) => e.stopPropagation()}
      onClick={() => {
        if (b.open) {
          bubble.value = null;
          return;
        }
        bubble.value = { ...b, open: true };
        clearTimeout(hideTimer);
      }}
    >
      {b.open ? (
        <>
          {lines.map((l, i) => (
            <div key={i} class="pet-line">
              <span class="pet-from muted">{l.from} </span>
              {l.text}
            </div>
          ))}
          {/* More: the whole conversation and the work board - PowOS AI's page. */}
          <button
            type="button"
            class="pet-more-link"
            onClick={(e) => {
              e.stopPropagation();
              bubble.value = null;
              openAi();
            }}
          >
            more ›
          </button>
        </>
      ) : (
        last && (
          <div class="pet-line pet-short">
            {lines.length > 1 && <span class="pet-more muted">+{lines.length - 1} </span>}
            {last.text}
          </div>
        )
      )}
    </div>
  );
}

/**
 * Mounted once on home (home.tsx): fixed over home and the PowOS AI page, outside their swipes - while the local.pet
 * app is installed (`powos app remove local.pet` takes it away, and its sockets and listeners with it).
 */
export function Pet() {
  return installedApps.value.some((a) => a.id === APP) ? <PetLayer /> : null;
}

function PetLayer() {
  const shown = useShown();
  useClocks(shown);
  const el = useRef<HTMLButtonElement>(null);
  const press = useRef<{ x: number; y: number; dx: number; dy: number; moved: boolean; timer: number; long: boolean } | null>(null);
  // A new "hello" each time home comes back: the state's animation plays once more.
  const [hello, setHello] = useState(0);
  useEffect(() => {
    if (shown) setHello((n) => n + 1);
  }, [shown]);
  // On the chat surface it's the chat's face (pet.css .face: by the pill); over the app list, menus, edit mode: away.
  const face = chatOpen.value;
  const hidden = (drawerOpen.value && !face) || editing.value || notifOpen.value || !!carry.value || !!menu.value;
  const at = toPx(pos());
  const s = state.value;
  return (
    <>
      {shown && <PetFeed />}
      {!hidden && !face && <Bubble at={at} />}
      <button
        type="button"
        ref={el}
        class={`pet ${hidden ? "away" : ""} ${face ? "face" : ""}`}
        data-state={s}
        aria-label={`${name.value}: ${s} - tap to talk, hold for PowOS AI's page`}
        style={{ left: `${at.left}px`, top: `${at.top}px` }}
        onPointerDown={(e) => {
          e.stopPropagation();
          (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
          const p = { x: e.clientX, y: e.clientY, dx: 0, dy: 0, moved: false, timer: 0, long: false };
          p.timer = window.setTimeout(() => {
            p.long = true;
            navigator.vibrate?.(12);
            if (chatOpen.peek()) closeDrawer();
            openAi();
          }, LONG_MS);
          press.current = p;
        }}
        onPointerMove={(e) => {
          const p = press.current;
          if (!p || p.long) return;
          p.dx = e.clientX - p.x;
          p.dy = e.clientY - p.y;
          // As the chat's face it stays by the pill: not dragged.
          if (!p.moved && !face && Math.hypot(p.dx, p.dy) > MOVE_PX) {
            p.moved = true;
            clearTimeout(p.timer);
            el.current?.classList.add("dragging");
          }
          if (p.moved && el.current) el.current.style.transform = `translate(${p.dx}px, ${p.dy}px)`;
        }}
        onPointerUp={() => {
          const p = press.current;
          press.current = null;
          if (!p) return;
          clearTimeout(p.timer);
          if (p.moved) {
            const free = (n: number) => Math.max(1, n - SIZE - 2 * MARGIN);
            const x = (at.left + p.dx - MARGIN) / free(innerWidth);
            const y = (at.top + p.dy - MARGIN) / free(innerHeight);
            where.value = JSON.stringify({ x: Math.min(1, Math.max(0, x)), y: Math.min(1, Math.max(0, y)) });
            if (el.current) {
              el.current.style.transform = "";
              el.current.classList.remove("dragging");
            }
            return;
          }
          if (p.long) return;
          // A tap: it listens right there (its bubble shows what it hears, then the reply); listening, it stops.
          if (petListening.value) powos.speech.stop();
          else if (!face) startTalk();
          else openAssistant({ listen: true, autosend: true });
        }}
        onPointerCancel={() => {
          const p = press.current;
          press.current = null;
          if (p) clearTimeout(p.timer);
          if (el.current) {
            el.current.style.transform = "";
            el.current.classList.remove("dragging");
          }
        }}
      >
        <span
          key={`${s}-${hello}`}
          class="pet-body"
        >
          <Sprite />
        </span>
      </button>
    </>
  );
}

/** Home on screen (the page visible). */
function useShown() {
  const [v, setV] = useState(!document.hidden);
  useEffect(() => {
    const on = () => setV(!document.hidden);
    document.addEventListener("visibilitychange", on);
    return () => document.removeEventListener("visibilitychange", on);
  }, []);
  return v;
}

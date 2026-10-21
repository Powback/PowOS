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
import { carry, chat, chatting, closeDrawer, editing, home, menu, openPanel, page, pullPanels, stored } from "../state.ts";
import { drawerOpen, notifOpen } from "./gesture.ts";
// From bar.tsx, which re-exports ui/dictation.ts: the phone runs an older bar.tsx until the dictation rework ships.
import { dictate, hearing, speech, type MicTarget } from "./bar.tsx";
import { askQueued, openAssistant } from "./assistant.ts";
import { agent, agentIds, asks, tasks, useAgents } from "../agents.ts";
import { useDb, useRows } from "../apps/stdb.ts";
import { installedApps } from "../apps/pages.ts";
import { watchRegistry } from "../apps/registry.ts";
import { PetBody, type BodyHandle } from "./petbody.tsx";
import { edges, fall, perchAt, placeOn, where as perchWhere, type Edge, type Perch } from "./petperch.ts";
import { keyframes, plan } from "./petpath.ts";
import { Mover } from "./petmove.ts";
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

type State = "idle" | "happy" | "working" | "looking" | "worried" | "sleepy" | "hungry" | "eating" | "listening";

/** Its size (CSS px): a touch bigger unfolded (pet.css --pet-size says the same). */
const size = () => (innerWidth >= 600 ? 72 : 64);
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
/** Its perch (petperch.ts): a tile's top edge, or the search pill's - kept; at first, the pill's right end. */
const perchStored = stored("pet.perch", JSON.stringify({ key: "bar", fx: 0.85 }));
const perch = (): Perch | null => {
  try {
    const p = JSON.parse(perchStored.value || "null");
    return p && typeof p.key === "string" ? { key: p.key, fx: +p.fx || 0 } : null;
  } catch {
    return null;
  }
};
/**
 * Its movement: "on" = the platformer controller (petphys.ts: it runs, jumps and climbs on home's live rects, one
 * continuous position, no teleports); "off" = the keyframe hops (petpath.ts). Empty: the default below.
 * `__pet.physics("on" | "off" | "")` sets it (the page reloads its layer).
 */
const physics = stored("pet.physics", "");
const PHYSICS_DEFAULT = "off";
const physicsOn = () => (physics.value || PHYSICS_DEFAULT) === "on";
/** With physics on: it stands on a tile or the pill (the contact shadow), and its place at rest (the bubble's). */
const physPerched = signal(false);
const physRest = signal(0);

/** Bumped when home's layout may have moved under it (a page settled, tiles changed, the screen resized). */
const layout = signal(0);
const toPx = (p: { x: number; y: number }) => ({
  left: MARGIN + p.x * Math.max(0, innerWidth - size() - 2 * MARGIN),
  top: MARGIN + p.y * Math.max(0, innerHeight - size() - 2 * MARGIN),
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
  (agentIds.value ?? []).some((id) => {
    const a = agent(id)?.value;
    return a?.state === "working" && !a.id.includes("/");
  }),
);
const needsYou = computed(() => {
  const t = clock.value;
  return (
    waiting.value > 0 ||
    (asks.value ?? []).some((a) => a.answer == null && a.expires > t) ||
    (agentIds.value ?? []).some((id) => agent(id)?.value.state === "needs_you") ||
    (mailNow.value ?? []).some((m) => m?.from !== "deploy")
  );
});

/** Its hop to an edge (PetLayer sets it while it's on screen; a no-op otherwise). */
let hopTo: (e: Edge, fx: number, then?: () => void, retries?: number) => void = () => {};
/** A tap on a tile it stands on (a deploy it brings): a short press of its body and a nudge of the tile. */
function tapTile(key: string) {
  const tile = document.querySelector<HTMLElement>(`.page:not(.away) .home-tile[data-key="${CSS.escape(key)}"]`);
  tile?.animate([{ transform: "none" }, { transform: "translateY(2px) scale(0.99)" }, { transform: "none" }], { duration: 260, easing: "ease-out" });
}

/**
 * A deploy note: the tile it's about (its name in the note - "Lights got rooms" -> the Lights widget), on the page
 * showing. The pet hops onto it and taps it; the note shows in its bubble there.
 */
function deployTarget(note: string): Edge | null {
  const words = note.toLowerCase();
  const byKey = new Map(home.peek().items.map((i) => [i.key, i] as const));
  let best: { e: Edge; n: number } | null = null;
  for (const e of edges()) {
    const item = byKey.get(e.key) as { name?: string; app?: string } | undefined;
    const name = (item?.name ?? item?.app?.split(/[./]/).at(-1) ?? "").toLowerCase().trim();
    if (name.length < 3) continue;
    if (new RegExp(`\\b${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`).test(words) && (!best || name.length > best.n)) best = { e, n: name.length };
  }
  return best?.e ?? null;
}

/** A new piece of work started (an agent went working): it carries its parcel toward the board (PowOS AI's side). */
function carryToBoard() {
  const list = edges();
  if (!list.length) return;
  const left = list.reduce((m, e) => (e.left < m.left || (e.left === m.left && e.top > m.top) ? e : m));
  hopTo(left, 0.12);
}

/** The last `powos pet goto` it went on (ms): an order from before isn't done again. */
const gotoSeen = stored("pet.gotoAt", "0");

/**
 * Where "where" is on home: "x,y" (CSS px), a tile's key or its name ("lights", "Weather"), or a CSS selector - the
 * edge it can stand on nearest that spot.
 */
function resolve(where: string): { e: Edge; fx: number } | null {
  const list = edges();
  const w = where.trim();
  const xy = /^(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)$/.exec(w);
  let x: number | null = null;
  let y: number | null = null;
  if (xy) {
    x = +xy[1];
    y = +xy[2];
  } else {
    const low = w.toLowerCase();
    const item = home.peek().items.find((i) => i.key === w || (i.name ?? i.label ?? "").toLowerCase() === low);
    const direct = item && list.find((e) => e.key === item.key);
    if (direct) return { e: direct, fx: 0.5 };
    let el: Element | null = item ? document.querySelector(`.home-tile[data-key="${CSS.escape(item.key)}"]`) : null;
    if (!el) {
      try {
        el = document.querySelector(w);
      } catch {}
    }
    if (!el) return null;
    const r = el.getBoundingClientRect();
    x = r.left + r.width / 2;
    y = r.top;
  }
  const p = perchAt(x, y - 4, list);
  const e = p && list.find((k) => k.key === p.key);
  return e && p ? { e, fx: p.fx } : null;
}

/** say(), reached before its definition (hoisted function). */
const sayIt = (l: { text: string; from: string }) => say(l);

/** Goes where it's sent; says [say] when it's there (or, nowhere to stand there, says it where it is). */
function goTo(where: string, say: string) {
  const t = resolve(where);
  const speak = () => say && sayIt({ text: say, from: "agent" });
  if (t) hopTo(t.e, t.fx, speak);
  else speak();
}

/** A state forced from outside (review renders, CDP: `__pet.force("worried")`, null to let go). */
const forced = signal<State | null>(null);
(window as unknown as { __pet?: object }).__pet = {
  force: (s: State | null) => (forced.value = s),
  /** Put it on a perch (a tile's key or "bar", 0..1 along the edge); null: floating. */
  perch: (key: string | null, fx = 0.5) => (perchStored.value = key ? JSON.stringify({ key, fx }) : ""),
  edges,
  /** What an agent starting work makes it do (review renders). */
  carry: () => carryToBoard(),
  /** Go to an edge by its key (review renders): the platformer path. */
  go: (key: string, fx = 0.5) => {
    const e = edges().find((x) => x.key === key);
    if (e) hopTo(e, fx);
  },
  /** Its movement: "on" (the platformer), "off" (keyframe hops), "" (the default). */
  physics: (v: "on" | "off" | "") => (physics.value = v),
  /** `powos pet goto` from the page (review renders). */
  goto: (where: string, say = "") => goTo(where, say),
  /** The plan it would take there (review). */
  plan: (key: string, fx = 0.5) => {
    const list = edges();
    const cur = perch();
    const a = cur && list.find((x) => x.key === cur.key);
    const e = list.find((x) => x.key === key);
    return a && cur && e ? plan(list, { key: cur.key, x: a.left + cur.fx * (a.right - a.left) }, { key, x: e.left + fx * (e.right - e.left) }) : null;
  },
};

const state = computed<State>(() => {
  if (forced.value) return forced.value;
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
  // Low battery: sleepy (slow); charging (not full yet): eating. A display only - nothing is switched off.
  if (b.level != null && b.level < 20 && !b.charging) return "hungry";
  if (b.charging && b.level != null && b.level < 95 && !busy.value) return "eating";
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
  const items = chat.value.items ?? [];
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
  const items = chat.value.items ?? [];
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
function gotMail(got: AgentMail[] | null | undefined) {
  // An older host answers nothing (or not a list): as no mail.
  const list = Array.isArray(got) ? got : [];
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
    const target = m.from === "deploy" && !FAILED.test(m.text) ? deployTarget(m.text) : null;
    if (target) hopTo(target, 0.5, () => tapTile(target.key));
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
  /** Over apps too (`powos pet overlay on|off`); a module from before it: undefined = on. */
  overlay?: boolean;
  /** Where an agent sent it (`powos pet goto`), what to say there, and when (ms). */
  gotoTarget?: string;
  gotoSay?: string;
  gotoAt?: bigint | number;
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
    // Sent somewhere (`powos pet goto`): once per new order, while home shows.
    const at = Number(p.gotoAt ?? 0);
    if (at && at > (Number(gotoSeen.value) || 0)) {
      gotoSeen.value = String(at);
      if (Date.now() - at < 5 * 60_000) goTo(p.gotoTarget ?? "", p.gotoSay ?? "");
    }
    // The pet over apps follows the module's switch (the CLI sets it there; the host keeps it).
    if (typeof p.overlay === "boolean") powos.pet?.overlay(p.overlay).catch(() => {});
    moodSet.value = { mood: p.mood, until: Number(p.moodUntil) };
  }, [pets]);
  useEffect(() => {
    if (!said?.length) return;
    const last = Number(saidSeen.value) || Date.now();
    const fresh = said.filter((s) => Number(s.at) > last).sort((a, b) => Number(a.id) - Number(b.id));
    for (const s of fresh) say({ text: s.text, from: s.from });
    if (fresh.length) saidSeen.value = String(Math.max(...fresh.map((s) => Number(s.at))));
  }, [said]);
  // The board: what waits on the user, and a task going done - a jump (once per task).
  const statuses = useRef<Map<string, string> | null>(null);
  useEffect(() => {
    if (adb.status !== "connected" || !work?.length) return;
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
        for (const l of tasks.value?.values() ?? []) for (const t of l ?? []) if (t.status === "done") done.add(t.id);
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

/** The text the bubble will show, for sizing its place (roughly: the last line, or what's heard / the reply). */
function bubbleText() {
  const t = talk.value;
  if (t) return `${t.asked ?? ""} ${reply.value ?? ""}`.trim() || "listening…";
  return bubble.value?.lines.at(-1)?.text ?? "";
}

/**
 * Where the bubble goes: beside the pet - above it, else below, on the side with room - in the nearest place that
 * covers no home tile (widget content stays readable); flipped at the screen's edges. Its size is estimated from the
 * text (14 px, 300 px wide at most, 3 lines shown).
 */
function bubbleSpot(at: { left: number; top: number }, text: string) {
  const s = size();
  const w = Math.min(300, innerWidth - 32, 28 + text.length * 8);
  const lines = Math.min(3, Math.max(1, Math.ceil((text.length * 8) / Math.max(1, w - 28))));
  const h = 22 + lines * 20;
  const tiles = [...document.querySelectorAll<HTMLElement>(".page:not(.away) .home-tile, .bar")].map((e) => e.getBoundingClientRect());
  const hits = (x: number, y: number) => tiles.some((r) => x < r.right && x + w > r.left && y < r.bottom && y + h > r.top);
  const fits = (x: number, y: number) => x >= MARGIN && x + w <= innerWidth - MARGIN && y >= MARGIN + 30 && y + h <= innerHeight - MARGIN;
  const cands: { x: number; y: number; right: boolean; below: boolean }[] = [];
  for (const below of [false, true])
    for (const right of [at.left + s / 2 > innerWidth / 2, at.left + s / 2 <= innerWidth / 2]) {
      const x = right ? at.left + s - w : at.left;
      const y = below ? at.top + s + 6 : at.top - h - 6;
      cands.push({ x: Math.min(innerWidth - MARGIN - w, Math.max(MARGIN, x)), y, right, below });
    }
  // Beside it, at its height.
  for (const right of [false, true]) {
    const x = right ? at.left - w - 6 : at.left + s + 6;
    cands.push({ x, y: at.top + s / 2 - h / 2, right, below: false });
  }
  // Still nothing free: the nearest free band of the screen, straight down or up from it.
  for (let d = 12; d < innerHeight; d += 12)
    for (const y of [at.top + s + 6 + d, at.top - h - 6 - d]) {
      const x = Math.min(innerWidth - MARGIN - w, Math.max(MARGIN, at.left + s / 2 - w / 2));
      cands.push({ x, y, right: false, below: y > at.top });
    }
  const pick = cands.find((c) => fits(c.x, c.y) && !hits(c.x, c.y)) ?? cands.find((c) => fits(c.x, c.y)) ?? cands[0];
  // The tail under/over the pet's middle, wherever the bubble ended up.
  const tail = Math.min(w - 18, Math.max(8, at.left + s / 2 - pick.x - 5));
  const style: Record<string, string> = { left: `${pick.x}px`, top: `${pick.y}px`, "--tail": `${tail}px` };
  const far = pick.y > at.top + s + 30 || pick.y + h < at.top - 30;
  return { right: pick.right, below: pick.below, style, far };
}

function Bubble({ at }: { at: { left: number; top: number } }) {
  const b = bubble.value;
  if (!b && !talk.value) return null;
  const { right, below, style, far } = bubbleSpot(at, bubbleText());
  if (talk.value) return <TalkBubble style={style} cls={`${right ? "right" : "left"} ${below ? "below" : "above"} ${far ? "far" : ""}`} />;
  if (!b) return null;
  const lines = b.lines;
  const last = lines.at(-1);
  return (
    <div
      class={`pet-bubble tile ${b.open ? "open" : ""} ${right ? "right" : "left"} ${below ? "below" : "above"} ${far ? "far" : ""}`}
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
  return (installedApps?.value ?? []).some((a) => a.id === APP) ? <PetLayer /> : null;
}

function PetLayer() {
  const shown = useShown();
  useClocks(shown);
  const el = useRef<HTMLButtonElement>(null);
  const body = useRef<BodyHandle | null>(null);
  // Physics on: one Mover drives the element (petmove.ts); its place is the simulation's, nothing else writes it.
  const phys = physicsOn();
  const mover = useRef<Mover | null>(null);
  useEffect(() => {
    const node = el.current;
    if (!phys || !node) return;
    const m = new Mover(node, size(), {
      rest: (at) => {
        if (at) perchStored.value = JSON.stringify(at);
        physRest.value++;
      },
      ground: () => (physPerched.value = !!m.standing()),
    });
    mover.current = m;
    // It first appears once home's layout has settled (the first layout bump), on its perch - before that it isn't
    // shown, so the layout settling under it is never a move.
    let spawned = false;
    node.style.visibility = "hidden";
    const offLayout = layout.subscribe((n) => {
      if (!n) return;
      if (!spawned) {
        spawned = true;
        const p = perch();
        const start = toPx(pos());
        m.spawn(p?.key ?? null, p?.fx ?? 0.5, start.left + size() / 2, start.top + size() * 0.94);
        physPerched.value = !!m.standing();
        node.style.visibility = "";
        physRest.value++;
        return;
      }
      m.resize(size());
      m.wake();
    });
    const vis = () => !document.hidden && m.wake();
    document.addEventListener("visibilitychange", vis);
    return () => {
      offLayout();
      document.removeEventListener("visibilitychange", vis);
      m.stop();
      mover.current = null;
      node.style.transform = "";
      node.style.visibility = "";
    };
  }, [phys]);
  // Its eyes follow a finger anywhere on home while it's awake (touches only: no frames without one).
  useEffect(() => {
    if (!shown) return;
    const look = (e: PointerEvent) => {
      if (state.peek() !== "sleepy") body.current?.look(e.clientX, e.clientY);
    };
    const away = () => body.current?.look(null, null);
    addEventListener("pointerdown", look, { capture: true, passive: true });
    addEventListener("pointermove", look, { capture: true, passive: true });
    addEventListener("pointerup", away, { capture: true, passive: true });
    addEventListener("pointercancel", away, { capture: true, passive: true });
    return () => {
      removeEventListener("pointerdown", look, { capture: true });
      removeEventListener("pointermove", look, { capture: true });
      removeEventListener("pointerup", away, { capture: true });
      removeEventListener("pointercancel", away, { capture: true });
    };
  }, [shown]);
  // Home's layout moved under its perch: measured again once things settle (a page slide, tiles moved, a resize).
  useEffect(() => {
    let t = 0;
    const later = (ms: number) => {
      clearTimeout(t);
      t = window.setTimeout(() => layout.value++, ms);
    };
    const offPage = page.subscribe(() => later(340));
    const offHome = home.subscribe(() => later(60));
    const resize = () => later(120);
    addEventListener("resize", resize);
    later(400);
    return () => {
      clearTimeout(t);
      offPage();
      offHome();
      removeEventListener("resize", resize);
    };
  }, []);
  // Physics: the chat surface opened - it goes to the pill as the chat's face (by its own moves).
  const faceNow = chatOpen.value;
  useEffect(() => {
    if (!faceNow || !mover.current) return;
    const bar = edges().find((x) => x.key === "bar");
    if (bar) mover.current.goTo({ key: "bar", x: bar.left + 0.88 * (bar.right - bar.left) });
  }, [faceNow]);
  // An agent got to work: it carries its parcel toward the board (once per start, while home shows).
  useEffect(() => {
    let was = busy.peek();
    return busy.subscribe((now) => {
      if (now && !was && shown && !document.hidden) carryToBoard();
      was = now;
    });
  }, [shown]);
  // A bubble goes at the first touch somewhere else (it said its line; the user is doing something).
  const hasBubble = !!bubble.value || !!talk.value?.done;
  useEffect(() => {
    if (!hasBubble) return;
    const away = (e: PointerEvent) => {
      if ((e.target as Element | null)?.closest?.(".pet, .pet-bubble")) return;
      bubble.value = null;
      if (talk.peek()?.done) talk.value = null;
    };
    addEventListener("pointerdown", away, { capture: true, passive: true });
    return () => removeEventListener("pointerdown", away, { capture: true });
  }, [hasBubble]);
  // A hop from its perch to [e] at [fx] along it: a short arc (one compositor animation), a squash on landing.
  // [then]: after it landed (a tap on the tile, a bubble).
  hopTo = (e: Edge, fx: number, then?: () => void, retries = 2) => {
    if (mover.current) {
      // Physics: it goes there by its own moves (petai.ts presses its buttons); [then] once it's there or as near as
      // it gets. The planner re-plans on its own when the layout moves under it.
      if (document.hidden) return;
      mover.current.goTo({ key: e.key, x: e.left + fx * (e.right - e.left) }, () => then?.());
      return;
    }
    const node = el.current;
    const sz = size();
    // Its laid-out place (left/top), not its rect: a pose or a squash transforms the rect, and the path's keyframes
    // are offsets from the layout.
    const r = node ? { left: parseFloat(node.style.left) || 0, top: parseFloat(node.style.top) || 0 } : null;
    if (!node || !r || document.hidden) return;
    // Platformer (petpath.ts): the way there over the edges - walks, jumps, wall-jumps up a tile's side - as one
    // compositor animation. Out of reach: as close as it can get (the path ends there). No perch to start from: one
    // direct hop.
    const list = edges();
    const target = list.find((x) => x.key === e.key) ?? e;
    const cur = perch();
    const curEdge = cur && list.find((x) => x.key === cur.key);
    const tx = target.left + fx * (target.right - target.left);
    const curX = curEdge && cur ? curEdge.left + cur.fx * (curEdge.right - curEdge.left) : 0;
    const moves = curEdge && cur ? plan(list, { key: cur.key, x: curX }, { key: target.key, x: tx }, true) : null;
    // Where it ends: the last move's edge and x (a partial path ends short of the target).
    const last = moves?.at(-1);
    const endEdge = last ? (list.find((x) => x.key === last.key) ?? target) : target;
    const endX = last ? last.x : tx;
    const endFx = (endX - endEdge.left) / Math.max(1, endEdge.right - endEdge.left);
    const to = placeOn(endEdge, endFx, sz);
    const dx = to.left - r.left;
    const dy = to.top - r.top;
    if (Math.hypot(dx, dy) < 4) {
      perchStored.value = JSON.stringify({ key: endEdge.key, fx: endFx });
      then?.();
      return;
    }
    let a: Animation;
    body.current?.stretch(0.5);
    node.classList.add("falling");
    const layoutAt = layout.peek();
    if (moves && moves.length && curEdge && cur) {
      const k = keyframes(list, { left: r.left, top: r.top }, cur.key, curX, moves, sz);
      a = node.animate(k.frames, { duration: k.duration, easing: "linear" });
    } else {
      const up = Math.min(r.top, to.top) - r.top - 36;
      a = node.animate(
        [{ transform: "none" }, { transform: `translate(${dx / 2}px, ${up}px)`, offset: 0.45 }, { transform: `translate(${dx}px, ${dy}px)` }],
        { duration: 560 + Math.min(400, Math.hypot(dx, dy)), easing: "cubic-bezier(0.35, 0, 0.45, 1)" },
      );
    }
    a.onfinish = () => {
      node.style.left = `${to.left}px`;
      node.style.top = `${to.top}px`;
      node.classList.remove("falling");
      perchStored.value = JSON.stringify({ key: endEdge.key, fx: endFx });
      // Landed ON the edge: the contact shadow (perched) and a squash.
      body.current?.squash(0.6);
      // The layout moved under it on the way (a page settled, tiles moved): the edge it aimed at is somewhere else
      // now - it goes on from where it is, a couple of times at most.
      if (layout.peek() !== layoutAt && retries > 0 && endEdge.key === target.key) {
        const now = edges().find((x) => x.key === target.key);
        if (now && Math.abs(now.top - target.top) + Math.abs(now.left - target.left) > 6) return hopTo(now, fx, then, retries - 1);
      }
      then?.();
    };
  };
  // Now and then (every few minutes, screen on, home untouched a while, nothing to say) it hops to a neighbouring
  // edge by itself - one timer between hops, the hop itself one short compositor animation.
  useEffect(() => {
    if (!shown) return;
    let t = 0;
    const next = () => (t = window.setTimeout(hop, 180_000 + Math.random() * 240_000));
    const hop = () => {
      next();
      const node = el.current;
      const cur = perch();
      if (!node || !cur || bubble.peek() || talk.peek() || state.peek() !== "idle" || Date.now() - touched.peek() < 60_000) return;
      const sz = size();
      const list = edges();
      const from = perchWhere(cur, sz, list);
      if (!from) return;
      // The nearest other edge (by where it'd stand), a random spot along it.
      const others = list.filter((e) => e.key !== cur.key).map((e) => ({ e, at: placeOn(e, 0.2 + Math.random() * 0.6, sz) }));
      const to = others.sort((a, b) => Math.hypot(a.at.left - from.left, a.at.top - from.top) - Math.hypot(b.at.left - from.left, b.at.top - from.top))[0];
      if (!to) return;
      hopTo(to.e, (to.at.left + sz / 2 - to.e.left) / Math.max(1, to.e.right - to.e.left));
    };
    next();
    return () => clearTimeout(t);
  }, [shown]);
  // Alive at rest: a blink every 6-10 s (one short compositor animation; no timer while hidden or asleep).
  useEffect(() => {
    if (!shown) return;
    let t = 0;
    const next = () => {
      t = window.setTimeout(() => {
        const s = state.peek();
        if (s !== "sleepy" && s !== "happy") body.current?.blink();
        next();
      }, 6000 + Math.random() * 4000);
    };
    next();
    return () => clearTimeout(t);
  }, [shown]);
  // Listening: its ears glow with each word heard.
  useEffect(
    () =>
      effect(() => {
        const sp = speech.value;
        if (sp.listening && (petListening.peek() || chatOpen.peek()) && sp.text) body.current?.pulse();
      }),
    [],
  );
  const press = useRef<{ x: number; y: number; dx: number; dy: number; lx: number; ly: number; moved: boolean; timer: number; long: boolean; fx?: number; fy?: number } | null>(null);
  // On the chat surface it's the chat's face (pet.css .face: by the pill); over the app list, menus, edit mode: away.
  const face = chatOpen.value;
  const hidden = (drawerOpen.value && !face) || editing.value || notifOpen.value || !!carry.value || !!menu.value;
  // Where it is: by the pill as the chat's face; on its perch (or, its edge not on screen, the nearest edge there
  // is); else floating where it was put.
  void layout.value;
  void page.value;
  void home.value;
  const sz = size();
  // Physics: where the simulation has it (read at rest - physRest - for the bubble); nothing here moves it.
  void physRest.value;
  const pill = face && !phys ? document.querySelector<HTMLElement>(".bar .bar-pill, .bar")?.getBoundingClientRect() : null;
  const list = face || phys ? [] : edges();
  const mine = perch();
  const perched = phys ? physPerched.value : !face && !!perchWhere(mine, sz, list);
  const at =
    (phys && mover.current?.pos()) ||
    (pill && placeOn({ key: "pill", left: pill.left, right: pill.right, top: pill.top }, 0.88, sz)) ||
    (phys ? null : perchWhere(mine, sz, list)) ||
    (!phys && mine && list.length ? perchWhere(perchAt(innerWidth - sz, innerHeight * 0.68, list), sz, list) : null) ||
    toPx(pos());
  const s = state.value;
  return (
    <>
      {shown && <PetFeed />}
      {!hidden && !face && <Bubble at={at} />}
      <button
        type="button"
        ref={el}
        class={`pet ${phys ? "phys" : ""} ${hidden ? "away" : ""} ${face ? "face" : ""} ${perched ? "perched" : ""}`}
        data-state={s}
        data-night={night(clock.value) ? "" : undefined}
        aria-label={`${name.value}: ${s} - tap to talk, hold for PowOS AI's page`}
        style={phys ? { left: "0px", top: "0px" } : { left: `${at.left}px`, top: `${at.top}px` }}
        onPointerDown={(e) => {
          e.stopPropagation();
          (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
          const p = { x: e.clientX, y: e.clientY, dx: 0, dy: 0, lx: 0, ly: 0, moved: false, timer: 0, long: false };
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
            // Physics: the finger holds it by its feet from where they are now.
            const g = mover.current?.grab();
            if (g) Object.assign(p, { fx: g.x, fy: g.y });
          }
          if (p.moved && el.current) {
            // The body lags the finger: this move's step, as a push (it wobbles back when the finger rests).
            body.current?.push((p.dx - p.lx) * 0.35, (p.dy - p.ly) * 0.35);
            if (mover.current) mover.current.drag((p.fx ?? 0) + p.dx, (p.fy ?? 0) + p.dy);
            else el.current.style.transform = `translate(${p.dx}px, ${p.dy}px)`;
          }
          p.lx = p.dx;
          p.ly = p.dy;
        }}
        onPointerUp={() => {
          const p = press.current;
          press.current = null;
          if (!p) return;
          clearTimeout(p.timer);
          if (p.moved && mover.current) {
            // Physics: let go with the finger's speed; it falls and lands where it lands.
            el.current?.classList.remove("dragging");
            mover.current.release();
            return;
          }
          if (p.moved) {
            const node = el.current;
            if (!node) return;
            // Let go: it falls (with the finger's last speed) onto the first edge below - a tile's, the search pill's.
            const x0 = at.left + p.dx;
            const y0 = at.top + p.dy;
            if (!edges().length) {
              // Nothing to stand on (PowOS AI's page): it stays where it was put, floating.
              const free = (n: number) => Math.max(1, n - sz - 2 * MARGIN);
              where.value = JSON.stringify({ x: Math.min(1, Math.max(0, (x0 - MARGIN) / free(innerWidth))), y: Math.min(1, Math.max(0, (y0 - MARGIN) / free(innerHeight))) });
              body.current?.squash(0.6);
              node.style.transform = "";
              node.classList.remove("dragging");
              return;
            }
            node.classList.add("falling");
            node.classList.remove("dragging");
            fall(x0, y0, (p.dx - p.lx) * 0.9, (p.dy - p.ly) * 0.9, sz, (x, y) => (node.style.transform = `translate(${x - at.left}px, ${y - at.top}px)`), (landed, speed) => {
              // Landed: its place written straight away (no frame between the fall's last and the render's first).
              const to = perchWhere(landed, sz);
              if (to) {
                node.style.left = `${to.left}px`;
                node.style.top = `${to.top}px`;
              }
              node.style.transform = "";
              node.classList.remove("falling");
              perchStored.value = JSON.stringify(landed);
              body.current?.squash(Math.min(1, 0.3 + speed / 22));
            });
            return;
          }
          if (p.long) return;
          body.current?.squash(0.35);
          // A tap: it listens right there (its bubble shows what it hears, then the reply); listening, it stops.
          if (petListening.value) powos.speech.stop();
          else if (!face) startTalk();
          else openAssistant({ listen: true, autosend: true });
        }}
        onPointerCancel={() => {
          const p = press.current;
          press.current = null;
          if (p) clearTimeout(p.timer);
          mover.current?.release();
          if (el.current && mover.current) el.current.classList.remove("dragging");
          else if (el.current) {
            el.current.style.transform = "";
            el.current.classList.remove("dragging", "falling");
          }
        }}
      >
        {/* Not re-keyed: each state's move has its own animation name, so a new state replays it; the springs stay. */}
        <span class="pet-body">
          <span class="pet-inner">
            <PetBody handle={body} />
          </span>
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

/**
 * The pet over apps (app.tsx mode "petover", in system/PetOverlay.kt's small window): the same creature and state as
 * on home, alone - no perch, no bubble. Its touches are the host's (drag, tap, hold): the page only hears them, for
 * the body (a wobble while dragged, a squash on a tap or a drop).
 */
export function PetOver() {
  const shown = useShown();
  // This page isn't home: the registry (is the pet installed?) is watched here too - its socket only while shown.
  useEffect(() => watchRegistry(), []);
  useClocks(shown);
  const body = useRef<BodyHandle | null>(null);
  useEffect(() => {
    const offs = [
      powos.on("petover.drag", ({ dx, dy }: { dx: number; dy: number }) => body.current?.push(dx * 0.35, dy * 0.35)),
      powos.on("petover.drop", () => body.current?.squash(0.6)),
      powos.on("petover.down", () => body.current?.squash(0.25)),
      powos.on("petover.tap", () => body.current?.squash(0.4)),
      powos.on("petover.hold", () => body.current?.stretch(0.5)),
    ];
    return () => offs.forEach((off) => off());
  }, []);
  // A blink now and then, as on home (no timer while the window's hidden: the page is paused then).
  useEffect(() => {
    if (!shown) return;
    let t = 0;
    const next = () => (t = window.setTimeout(() => (state.peek() !== "sleepy" && body.current?.blink(), next()), 6000 + Math.random() * 4000));
    next();
    return () => clearTimeout(t);
  }, [shown]);
  if (!(installedApps?.value ?? []).some((a) => a.id === APP)) return null;
  const s = state.value;
  return (
    <>
      {shown && <PetFeed />}
      <div class="pet over" data-state={s} data-night={night(clock.value) ? "" : undefined}>
        <span class="pet-body">
          <span class="pet-inner">
            <PetBody handle={body} />
          </span>
        </span>
      </div>
    </>
  );
}

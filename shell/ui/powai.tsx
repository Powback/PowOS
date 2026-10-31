/**
 * The PowOS AI page: left of home's first page, the whole screen (home, its bar and dock slide away for it), and the
 * AI panel (pull.tsx) - one chat, messenger style (the user, 2026-10-31: "it just needs to be like a chat page with some
 * additional integration... streamlined and easy"): the conversation full height, the user's messages right, the
 * manager's left, tool steps folded into one quiet line, images their own shape; older messages load as it's scrolled
 * up. Things to try arrive as the manager's messages with works / still broken (trycard.tsx), mail the agents sent the
 * user as messages under it. The rest - Progress, Agents & terminals, Devices - is behind the header's ⋯, each its own
 * screen with back (aimenu.tsx). Under it the shared field to ask (the mic: hold to talk and send, tap to dictate).
 * Unfolded the same chat, centred at reading width; with Progress open, the two side by side.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { aiDraft, aiScreen, chat, page } from "../state.ts";
import { Pill, hearing, type MicTarget } from "./bar.tsx";
import { ago } from "./time.ts";
import { md } from "./md.ts";
import type { AgentMail, ChatItem } from "../types.ts";
import { AppBuild, NewAppAsk, newAppAsk } from "./appbuild.tsx";
import { Item } from "./chat.tsx";
import { Queued, Thread, onLink, toolLabel } from "./rich.tsx";
import { askQueued } from "./assistant.ts";
import { MenuScreen, SCREENS, type AiScreen } from "./aimenu.tsx";
import { WorkFeed, headline, needsYou } from "./aiboard.tsx";
import { agent, sessions as agentSessions } from "../agents.ts";
import "./trycard.tsx";

// The board's state, for what reads it from here (perfrec, the gate, the renders): it lives in aiboard.tsx now.
export { board, boardSeen, checks, type WorkRow } from "./aiboard.tsx";

const mail = signal<AgentMail[]>([]);
powos.on("ai.mail", (m: AgentMail[]) => (mail.value = m));

// What's typed and not sent yet: kept across reloads (an update mustn't lose it).
const draft = aiDraft;

const send = () => {
  const text = draft.value.trim();
  if (!text) return;
  draft.value = "";
  // The one queue (assistant.ts): mid-turn it waits as a queued bubble, here and in every other chat.
  askQueued(text);
};

const pageMic: MicTarget = {
  typed: () => draft.value,
  heard: (full, sendIt) => {
    draft.value = full;
    if (sendIt) send();
  },
};

/** Items the chat draws at first, and how many more each time its top comes near. */
const STEP = 60;

/** Where the drawn part starts: [count] from the end, moved back to the ask that turn began with (never mid-turn). */
function startOf(items: ChatItem[], count: number) {
  const from = Math.max(0, items.length - count);
  if (!from) return 0;
  const ask = items.findLastIndex((i, at) => at <= from && i.kind === "user");
  return Math.max(0, ask);
}

/** Read: out of the chat at once (the host's "ai.mail" confirms), its notification and inbox entry gone too. */
function readMail(m: AgentMail) {
  mail.value = mail.value.filter((x) => x !== m);
  // ?.: an APK from before mailRead (the page is hot-pushed ahead of it) has no such call.
  if (m.id) powos.ai.mailRead?.(m.id);
}

/** Mail an agent sent the user, unread: its own messages at the chat's end, oldest first; × reads one. */
function Unread() {
  const ms = [...mail.value].slice(0, 5).reverse();
  if (!ms.length) return null;
  return (
    <>
      {ms.map((m) => (
        <div key={m.id ?? `${m.from}-${m.time}`} class="msg assistant ai-mail">
          <div class="ai-mail-head muted">
            <span>
              {m.from} · {ago(m.time)}
            </span>
            <button type="button" class="ai-mail-x" aria-label="mark read" onClick={() => readMail(m)}>
              ×
            </button>
          </div>
          <div class="ai-mail-text md" onClick={onLink} dangerouslySetInnerHTML={{ __html: md(m.text) }} />
        </div>
      ))}
      {ms.length > 1 && (
        <button type="button" class="ai-mail-clear" onClick={() => ((mail.value = []), powos.ai.mailClear?.())}>
          mark all read
        </button>
      )}
    </>
  );
}

/** Its mail, read when it comes into view (not while hidden). */
function useMail(shown: boolean) {
  useEffect(() => {
    if (!shown) return;
    const ask = () => document.hidden || powos.ai.mail().then((m) => (mail.value = m));
    ask();
    document.addEventListener("visibilitychange", ask);
    return () => document.removeEventListener("visibilitychange", ask);
  }, [shown]);
}

/**
 * The conversation: the newest STEP items drawn, older ones as the top comes near (a sentinel, IntersectionObserver on
 * the scroller). The scroller is column-reverse (CSS .ai-chat), so it opens at the newest, stays there as a reply
 * streams in, and holds still when older ones arrive above.
 */
function Conversation() {
  const [count, setCount] = useState(STEP);
  const top = useRef<HTMLDivElement>(null);
  const { busy, items } = chat.value;
  const from = startOf(items, count);
  useEffect(() => {
    const el = top.current;
    const pane = el?.closest(".ai-chat");
    if (!el || !pane || from === 0) return;
    const io = new IntersectionObserver((e) => e[0].isIntersecting && setCount((c) => c + STEP), { root: pane, rootMargin: "600px 0px 0px 0px" });
    io.observe(el);
    return () => io.disconnect();
  }, [from]);
  return (
    <div class="ai-chat-in">
      <div ref={top} class="ai-chat-top" />
      {!items.length && <div class="ai-empty muted">Ask PowOS AI anything - about PowOS, the phone, your projects.</div>}
      <Thread items={items.slice(from)} render={(item, reply) => <Item item={item} reply={reply} />} />
      {busy && items.at(-1)?.kind !== "assistant" && <div class="msg note muted thinking">thinking…</div>}
      <Queued />
      <Unread />
    </div>
  );
}

/** The chat pane: "Create app"'s own thread view (steps, the finished app) or the question that starts one, else the conversation. */
function ChatPane({ shown }: { shown: boolean }) {
  useMail(shown);
  if (chat.value.thread?.kind === "app") return <AppBuild />;
  if (newAppAsk.value) return <NewAppAsk />;
  return <Conversation />;
}

/** What the manager is doing, in a word or two ("ready", "working · reading a file"). */
function stateOf() {
  const { busy, items } = chat.value;
  const step = busy ? [...items].reverse().find((i) => i.kind === "tool" && i.ok == null) : null;
  return busy ? `working${step && step.kind === "tool" ? ` · ${toolLabel(step)}` : "…"}` : "ready";
}

/** The ⋯ menu's list: a tap opens that screen. */
function Menu({ close }: { close: () => void }) {
  return (
    <div class="ai-menu tile" role="menu">
      {SCREENS.map(([s, name]) => (
        <button key={s} type="button" role="menuitem" class="ai-menu-item" onClick={() => ((aiScreen.value = s), close())}>
          {name}
        </button>
      ))}
    </div>
  );
}

const nameOf = (s: AiScreen) => SCREENS.find(([k]) => k === s)?.[1] ?? "";

/** Session agents working now (the live hooks, agents.ts). */
const agentsWorking = () => agentSessions.value.filter((id) => agent(id)?.value.state === "working").length;

/** "1 needs you": the newest things-to-try message still unanswered, else Progress (the board's Needs you). */
function showNeeds() {
  const open = [...document.querySelectorAll<HTMLElement>(".ai-view .msg.try")].filter((m) => m.querySelector(".try-acts")).pop();
  if (open) open.scrollIntoView({ block: "center", behavior: "smooth" });
  else aiScreen.value = "progress";
}

/**
 * The glanceable line at the chat's top (the user, 2026-10-31 02:36: "chat focused ... or chat primary"): what the agents
 * are doing, how far the task moving most is, what needs the user - each a tap into its screen. [shown]: the board's
 * feed runs only then. Nothing to say: no line.
 */
function Strip({ shown }: { shown: boolean }) {
  const n = agentsWorking();
  const h = headline();
  const you = needsYou();
  const segs: [string, string, () => void][] = [];
  if (n) segs.push(["agents", `${n} agent${n === 1 ? "" : "s"} working`, () => (aiScreen.value = "agents")]);
  if (h) segs.push(["progress", `${h.title} ${h.pct}%`, () => (aiScreen.value = "progress")]);
  if (you) segs.push(["you", `${you} need${you === 1 ? "s" : ""} you`, showNeeds]);
  return (
    <>
      {shown && <WorkFeed />}
      {segs.length > 0 && (
        <nav class="ai-strip" aria-label="at a glance">
          {segs.map(([k, label, go], i) => (
            <button key={k} type="button" class={`ai-strip-seg ${k}`} onClick={go}>
              {i > 0 && <span class="ai-strip-dot" aria-hidden="true">·</span>}
              {label}
            </button>
          ))}
        </nav>
      )}
    </>
  );
}

/** Its header: the chat's name and what the manager is doing and ⋯, or - on a menu's screen - back and that screen's name. */
function AiHeader({ sub, shown = false }: { sub: AiScreen | null; shown?: boolean }) {
  const [menu, setMenu] = useState(false);
  if (sub)
    return (
      <header class="ai-top">
        <button type="button" class="ai-back" aria-label="back" onClick={() => (aiScreen.value = "chat")}>
          ‹
        </button>
        <span class="ai-title">{nameOf(sub)}</span>
      </header>
    );
  const busy = chat.value.busy;
  return (
    <>
      <header class="ai-top">
        <span class="ai-title">PowOS AI</span>
        <span class={`ai-state ${busy ? "busy" : ""}`}>{stateOf()}</span>
        <button type="button" class="ai-more" aria-label="more" aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu(!menu)}>
          ⋯
        </button>
        <Strip shown={shown} />
      </header>
      {menu && <div class="ai-menu-scrim" onClick={() => setMenu(false)} />}
      {menu && <Menu close={() => setMenu(false)} />}
    </>
  );
}

/** Its compose field: ask PowOS AI right here (the mic: hold to talk and send, tap to dictate). */
function AiCompose() {
  const input = useRef<HTMLTextAreaElement>(null);
  return (
    <form
      class="ai-compose"
      onSubmit={(e) => {
        e.preventDefault();
        send();
      }}
    >
      <Pill
        target={pageMic}
        send
        inputRef={input}
        value={hearing(pageMic) ?? draft.value}
        onInput={(v: string) => (draft.value = v)}
        onFocus={() => powos.keyboard.show()}
        aria-label="Ask PowOS AI"
        enterKeyHint="send"
        autocomplete="off"
      />
    </form>
  );
}

/** The page's width, not the device's, picks the layout: chat + Progress side by side from WIDE_PX (the inner screen). */
const WIDE_PX = 700;
function useWide() {
  const ref = useRef<HTMLDivElement>(null);
  const [wide, setWide] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWide(el.clientWidth >= WIDE_PX));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, wide] as const;
}

/** A menu's screen beside the chat (wide, Progress only): its own header with back, its own scroll. */
function Aside({ s, shown }: { s: AiScreen; shown: boolean }) {
  return (
    <div class="ai-aside">
      <AiHeader sub={s} />
      <div class="ai-scroll ai-sub">
        <MenuScreen s={s} shown={shown} back={() => (aiScreen.value = "chat")} />
      </div>
    </div>
  );
}

/**
 * PowOS AI's screen, wherever it's held - its page beside home, the pull-up panel on home and over apps (home.tsx,
 * pull.tsx): one component, so every change lands in all of them. The header, then the chat (or the menu's screen)
 * full height, then the field. Wide (useWide: the holder's width) the chat is centred at reading width; Progress
 * opened there sits beside it. [pill] false: the holder's own pill asks (home's bar under a narrow panel); wide always
 * has its own.
 */
export function AiView({ shown, cls, pill = true }: { shown: boolean; cls: string; pill?: boolean }) {
  const [ref, wide] = useWide();
  const s = aiScreen.value;
  const split = wide && s === "progress";
  const sub = s !== "chat" && !split ? s : null;
  return (
    <div ref={ref} class={`${cls} ai-view ${wide ? "wide" : ""} ${split ? "split" : ""}`}>
      <AiHeader sub={sub} shown={shown && !sub} />
      {sub ? (
        <div class="ai-scroll ai-sub">
          <MenuScreen s={sub} shown={shown} back={() => (aiScreen.value = "chat")} />
        </div>
      ) : (
        <div class="ai-scroll ai-chat">
          <ChatPane shown={shown} />
        </div>
      )}
      {!sub && (pill || wide) && <AiCompose />}
      {split && <Aside s={s} shown={shown} />}
    </div>
  );
}

/** Its page, to the left of home. */
export function PowAiPage() {
  const shown = page.value === -1;
  return <AiView shown={shown} cls={`ai-screen ${shown ? "shown" : ""}`} />;
}

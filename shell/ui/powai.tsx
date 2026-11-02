/**
 * The PowOS AI page: left of home's first page, the whole screen (home, its bar and dock slide away for it), and the
 * AI panel (pull.tsx) - one chat, messenger style (the user, 2026-10-31: "it just needs to be like a chat page with some
 * additional integration... streamlined and easy"): the conversation full height, the user's messages right, the
 * manager's left, tool steps folded into one quiet line, images their own shape; older messages load as it's scrolled
 * up. Things to try arrive as the manager's messages with works / still broken (trycard.tsx); the agents' mail stays
 * in its notifications and inbox, no line of it in the chat (BM2, the user 18:25). The rest - Progress, Agents & terminals, Devices - is behind the header's ⋯, each its own
 * screen with back (aimenu.tsx). Under it the shared field to ask (the mic: hold to talk and send, tap to dictate).
 * Folded, the page (not the launcher's AI panel) is a status page instead of the chat (aistatus.tsx, 2026-10-31).
 * Unfolded the page is two columns (the manager's design, 11-01): that same status page left, the chat right over a
 * segmented row at its foot (Chat / Agents / Progress / Devices; above the field on Chat) that swaps the right column. A wide holder without panes (the
 * panel) keeps the chat centred at reading width, Progress a glass sheet over its side.
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { aiDraft, aiScreen, chat, page } from "../state.ts";
import { onManagerSend, type MicTarget } from "./bar.tsx";
import type { ChatItem } from "../types.ts";
import { AppBuild, NewAppAsk, newAppAsk } from "./appbuild.tsx";
import { renderItem } from "./chat.tsx";
import { Queued, Thread, toolLabel } from "./rich.tsx";
import { askQueued } from "./assistant.ts";
import { MenuScreen, SCREENS, dailyDriver, menuScreens, type AiScreen } from "./aimenu.tsx";
import { WorkFeed } from "./aiboard.tsx";
import { aiAgent } from "../agents.ts";
import { fleet, workingNow } from "../fleet.ts";
import { untried } from "./trycard.tsx";
import { AiSegs, FleetPane, useAgentsInPane } from "./aipanes.tsx";
import { AiStatus, noteAsked, openChat, OtherProjectsItem, otherProjectsCount } from "./aistatus.tsx";
import { Icon } from "./icons.tsx";
import { usePresence } from "./reveal.tsx";

// The board's state, for what reads it from here (perfrec, the gate, the renders): it lives in aiboard.tsx now.
export { board, boardSeen, checks, type WorkRow } from "./aiboard.tsx";


// What's typed and not sent yet: kept across reloads (an update mustn't lose it).
const draft = aiDraft;

const send = () => {
  const text = draft.value.trim();
  if (!text) return;
  draft.value = "";
  // The folded status page shows its reply as one bubble (aistatus.tsx), not a transcript.
  noteAsked(text);
  // The one queue (assistant.ts): mid-turn it waits as a queued bubble, here and in every other chat.
  askQueued(text);
};

// OB1: the one bar's "ai" role sends as this page's own field did - the status page's bubble noted, the one queue.
onManagerSend((text) => {
  noteAsked(text);
  askQueued(text);
});

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

/**
 * The chat, asked again of the host whenever the page comes back on screen: the page holds the one store (state.ts chat) the
 * folded status page and the assistant read, but filled only by load() and "ai.changed" - a page that missed those
 * (the unfolded screen's, asleep while folded) drew yesterday's thread (the user, 11-01: "then why is it still showing").
 */
function useChatSync(shown: boolean) {
  useEffect(() => {
    if (!shown) return;
    const ask = () => document.hidden || powos.ai.chat().then((c) => (chat.value = c), () => undefined);
    document.addEventListener("visibilitychange", ask);
    return () => document.removeEventListener("visibilitychange", ask);
  }, [shown]);
}

/**
 * The conversation: the newest STEP items drawn, older ones as the top comes near (a sentinel, IntersectionObserver on
 * the scroller). The scroller is column-reverse (CSS .ai-chat), so it opens at the newest, stays there as a reply
 * streams in, and holds still when older ones arrive above.
 */
/** Past this far from the end (px) the user has scrolled up: new messages don't pull the chat down, the pill offers to. */
const AWAY_PX = 80;

/** The newest item's identity (items carry no id): its place and its text's length while it streams. */
const lastKey = (items: ChatItem[]) => `${items.length}:${items.at(-1)?.kind ?? ""}:${"text" in (items.at(-1) ?? {}) ? (items.at(-1) as { text: string }).text.length : 0}`;

/**
 * Opens at the newest and follows it as messages stream in, unless the user scrolled up - then [pill] is up ("New
 * messages ↓", a tap goes to the end). The scroller is column-reverse: its end is scrollTop 0.
 */
function useFollow(top: preact.RefObject<HTMLDivElement>, key: string) {
  const away = useRef(false);
  const [pill, setPill] = useState(false);
  const pane = () => top.current?.closest<HTMLElement>(".ai-chat") ?? null;
  const toEnd = () => {
    const el = pane();
    if (el) el.scrollTop = 0;
    away.current = false;
    setPill(false);
  };
  useEffect(() => {
    const el = pane();
    if (!el) return;
    el.scrollTop = 0;
    const onScroll = () => {
      away.current = Math.abs(el.scrollTop) > AWAY_PX;
      if (!away.current) setPill(false);
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => el.removeEventListener("scroll", onScroll);
  }, []);
  useLayoutEffect(() => {
    const el = pane();
    if (!el) return;
    if (away.current) setPill(true);
    else el.scrollTop = 0;
  }, [key]);
  return [pill, toEnd] as const;
}

/** Up while new messages came in below where the user scrolled to: a tap goes to the newest. */
function NewPill({ go }: { go: () => void }) {
  return (
    <button type="button" class="ai-new-pill" onClick={go}>
      New messages ↓
    </button>
  );
}

function Conversation() {
  const [count, setCount] = useState(STEP);
  const top = useRef<HTMLDivElement>(null);
  const { busy, items } = chat.value;
  const from = startOf(items, count);
  const [pill, toEnd] = useFollow(top, lastKey(items));
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
      <Thread items={items.slice(from)} render={renderItem} />
      {busy && items.at(-1)?.kind !== "assistant" && <div class="msg note muted thinking">thinking…</div>}
      <Queued />
      {pill && <NewPill go={toEnd} />}
    </div>
  );
}

/** The chat pane: "Create app"'s own thread view (steps, the finished app) or the question that starts one, else the conversation. */
function ChatPane({ shown }: { shown: boolean }) {
  useChatSync(shown);
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

/** The ⋯ menu's list: a tap opens that screen. [tabs]: over the bottom tabs - only what no tab offers (the user, 11-01 17:56: "this is like a duplicate"). */
function Menu({ close, tabs = false, leaving = false, children }: { close: () => void; tabs?: boolean; leaving?: boolean; children?: preact.ComponentChildren }) {
  return (
    <div class={`ai-menu tile ${leaving ? "leaving" : ""}`} role="menu" inert={leaving || undefined}>
      {menuScreens(tabs).map(([s, name]) => (
        <button key={s} type="button" role="menuitem" class="ai-menu-item" onClick={() => ((aiScreen.value = s), close())}>
          {name}
        </button>
      ))}
      {children}
    </div>
  );
}

/**
 * The header's ⋯, or - when its menu would hold one item (unfolded with no other projects: only Friction) - that item
 * as a direct button in the same place and style (the coordinator's design, 11-02: no menu of one). [n]: the menu's items.
 */
function More({ n, menu, setMenu }: { n: number; menu: boolean; setMenu: (on: boolean) => void }) {
  const only = n === 1 ? menuScreens(true)[0] : null;
  if (only)
    return (
      <button type="button" class="ai-more ai-more-one" aria-label={only[1]} title={only[1]} onClick={() => (aiScreen.value = only[0])}>
        <Icon name="alertCircleOutline" size={20} />
      </button>
    );
  return (
    <button type="button" class="ai-more" aria-label="more" aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu(!menu)}>
      ⋯
    </button>
  );
}

const nameOf = (s: AiScreen) => SCREENS.find(([k]) => k === s)?.[1] ?? (s === "fleet" ? "Agent" : "");

/** Agents working now: fleet.ts workingNow, the one count the status page and the home widget show too. */
const agentsWorking = () => workingNow(fleet()).length;

/** "3 to try": the newest things-to-try message still unanswered, in view. */
function showTry() {
  const open = [...document.querySelectorAll<HTMLElement>(".ai-view .msg.try")].filter((m) => m.querySelector(".try-acts")).pop();
  open?.scrollIntoView({ block: "center", behavior: "smooth" });
}

/** The strip's segments: agents working, the daily driver's percentage (powos-progress), things to try unanswered. */
function stripSegs(): [string, string, () => void][] {
  const n = agentsWorking();
  const dd = dailyDriver();
  const tries = untried(chat.value.items.flatMap((i) => (i.kind === "assistant" ? [i.text] : [])));
  const segs: [string, string, () => void][] = [];
  if (n) segs.push(["agents", `${n} agent${n === 1 ? "" : "s"} working`, () => (aiScreen.value = "agents")]);
  if (dd != null) segs.push(["progress", `Daily driver ${dd}%`, () => (aiScreen.value = "progress")]);
  if (tries) segs.push(["you", `${tries} to try`, showTry]);
  return segs;
}

/**
 * The glanceable line at the chat's top (the user, 2026-10-31 02:36: "chat focused ... or chat primary"):
 * "1 agent working · Daily driver 50% · 3 to try" - each a tap into its screen, never a task's title. [shown]: the
 * board's feed runs only then. Nothing to say: no line.
 */
function Strip({ shown }: { shown: boolean }) {
  const segs = stripSegs();
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
function AiHeader({ sub, shown = false, strip = true, title = true }: { sub: AiScreen | null; shown?: boolean; strip?: boolean; title?: boolean }) {
  const [menu, setMenu] = useState(false);
  // Opens and closes on the spring (reveal.tsx; §6: the ⋯ menu popped in and out).
  const pop = usePresence(menu);
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
        {title && <span class="ai-title">PowOS AI</span>}
        <span class={`ai-state ${busy ? "busy" : ""}`}>{stateOf()}</span>
        <More n={menuScreens().length} menu={menu} setMenu={setMenu} />
        {strip && <Strip shown={shown} />}
      </header>
      {menu && <div class="ai-menu-scrim" onClick={() => setMenu(false)} />}
      {pop.on && <Menu close={() => setMenu(false)} leaving={pop.leaving} />}
    </>
  );
}

/** The page's width, not the device's, picks the layout: chat + Progress side by side from WIDE_PX (the inner screen). */
const WIDE_PX = 700;
/** Under this height, wide is the folded screen turned sideways (.rail: the two columns' spacing tighter). */
const RAIL_H = 600;
function useWide() {
  const ref = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ wide: false, rail: false });
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      const wide = el.clientWidth >= WIDE_PX;
      const rail = wide && el.clientHeight < RAIL_H;
      setSize((s) => (s.wide === wide && s.rail === rail ? s : { wide, rail }));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, size.wide, size.rail] as const;
}

/** A menu's screen as a glass sheet over the chat's side (wide, Progress only): its own header with back, its own scroll; a tap beside it closes it. */
function Aside({ s, shown }: { s: AiScreen; shown: boolean }) {
  return (
    <div class="ai-aside tile">
      <AiHeader sub={s} />
      <div class="ai-scroll ai-sub">
        <MenuScreen s={s} shown={shown} back={() => (aiScreen.value = "chat")} />
      </div>
    </div>
  );
}

/** Progress as a sheet over the chat (wide) and the scrim beside it that closes it. */
function Sheet({ s, shown }: { s: AiScreen; shown: boolean }) {
  return (
    <>
      <div class="ai-sheet-scrim" onClick={() => (aiScreen.value = "chat")} />
      <Aside s={s} shown={shown} />
    </>
  );
}

/**
 * PowOS AI's screen, wherever it's held - its page beside home, the pull-up panel on home and over apps (home.tsx,
 * pull.tsx): one component, so every change lands in all of them. The header, then the chat (or the menu's screen)
 * full height, then the field. Wide (useWide: the holder's width) the chat is centred at reading width - alone until
 * Progress is opened (⋯ or the strip), then that as a sheet over its side. [pill] false: the holder's own pill asks (home's bar under a narrow panel); wide always
 * has its own.
 */
function aiViewClass(cls: string, wide: boolean, split: boolean) {
  return `${cls} ai-view ${wide ? "wide" : ""} ${split ? "split" : ""}`;
}

/** Kept clear over the bar's pill: the thread's last line and its live row ("thinking…") end this far above it. */
const BAR_CLEAR = 16;

/** The page's one input: home's bar (seated on the AI page, or under the launcher's AI panel) or the overlay's. */
const barPill = () => document.querySelector<HTMLElement>(".bar[data-role] .bar-pill") ?? document.querySelector<HTMLElement>(".bar .bar-pill");

/**
 * Thread [el] ends above the bar (the user, 11-01 22:1x: "smh" - the newest message's last line and "thinking…" under
 * "Message the manager"): where the pill overlaps it, bottom padding of the overlap plus [BAR_CLEAR], so scrolled to
 * its end (column-reverse: always, unless scrolled up) all of it shows over the bar; else its own CSS padding.
 */
function clearOfBar(el: HTMLElement) {
  el.style.removeProperty("padding-bottom");
  const pill = barPill();
  if (!pill) return;
  const p = pill.getBoundingClientRect(), r = el.getBoundingClientRect();
  const across = r.width > 0 && p.width > 0 && p.left < r.right && p.right > r.left && p.top < r.bottom;
  const need = across ? r.bottom - (p.top - BAR_CLEAR) : 0;
  if (need > (parseFloat(getComputedStyle(el).paddingBottom) || 0)) el.style.paddingBottom = `${Math.ceil(need)}px`;
}

/** Keeps [ref]'s thread clear of the bar as either moves: the bar seated or growing, the strip, the keyboard. */
function useBarClear(ref: { current: HTMLElement | null }) {
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const run = () => clearOfBar(el);
    const ro = new ResizeObserver(run);
    ro.observe(el);
    const pill = barPill();
    if (pill) ro.observe(pill);
    // The seated bar's translate eases into place: measured again where it ends.
    const ended = (e: Event) => (e.target as Element).matches?.(".bar") && run();
    document.addEventListener("transitionend", ended);
    document.addEventListener("bar-seated", run);
    const off = powos.on("system.insets", () => requestAnimationFrame(run));
    run();
    return () => (ro.disconnect(), document.removeEventListener("transitionend", ended), document.removeEventListener("bar-seated", run), off());
  }, []);
}

/** The view's body: a menu screen with back, or the chat. */
function AiBody({ sub, shown, beside = false }: { sub: AiScreen | null; shown: boolean; beside?: boolean }) {
  if (sub) {
    return (
      <div class="ai-scroll ai-sub">
        <MenuScreen s={sub} shown={shown} back={() => (aiScreen.value = "chat")} beside={beside} />
      </div>
    );
  }
  return <PageChat shown={shown} />;
}

/**
 * THE chat, styled as one wherever it's held (.ai-page-chat: the page, its panes, the launcher's AI panel and the side
 * button's assist overlay - the user, 11-01: "same design as the AI page"; shell.css): one component, not a second one.
 */
export function PageChat({ shown, cls = "" }: { shown: boolean; cls?: string }) {
  return (
    <ChatScroll shown={shown} cls={cls} />
  );
}

/** THE chat's scroller, kept clear of the bar (useBarClear). */
function ChatScroll({ shown, cls = "" }: { shown: boolean; cls?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  useBarClear(ref);
  return (
    <div ref={ref} class={`ai-scroll ai-chat ai-page-chat ${cls}`}>
      <ChatPane shown={shown} />
    </div>
  );
}

/** The segmented row's screens: shown in the right column with no header of their own (the row names them). */
const SEGMENTED = new Set<AiScreen>(["chat", "fleet", "agents", "progress", "devices"]);

/**
 * The right column: what the segmented row picked, the row itself at the column's foot (the user, 11-01 16:43: "move the
 * tabs to the bottom"); a screen no segment names keeps back. No field of the page's own (the user, 11-01 18:24: "remove
 * the search entirely from the AI page: we reuse the main search bar"): unfolded, under the row, the room home's shared
 * bar takes (.ai-bar-slot, as folded); folded (not [beside]) the row is the screen's foot, the bar's room under it (CSS).
 */
function RightBody({ s, shown, beside = false }: { s: AiScreen; shown: boolean; beside?: boolean }) {
  const foot = (
    <>
      <AiSegs shown={shown} />
      {beside && <div class="ai-bar-slot" data-bar-slot="ai" aria-hidden="true" />}
    </>
  );
  if (s === "fleet")
    return (
      <>
        <FleetPane />
        {foot}
      </>
    );
  return (
    <>
      {!SEGMENTED.has(s) && <AiHeader sub={s} />}
      <AiBody sub={s === "chat" ? null : s} shown={shown} beside={beside} />
      {foot}
    </>
  );
}

/**
 * The unfolded AI page in two columns (the manager's design, 11-01; the user: "the unfolded page is still a bit shit"):
 * left (~42%) the folded status page itself (StatusColumn, beside the chat: no field of its own), right (~58%) what the
 * segmented row picked - the chat (its field at the column's foot) by default - and the row under it. Both on the
 * backdrop's glass.
 */
function AiPanes({ shown }: { shown: boolean }) {
  const s = aiScreen.value;
  useAgentsInPane(shown);
  return (
    <>
      <section class="ai-left tile" aria-label="status">
        <StatusColumn shown={shown} beside />
      </section>
      <div class="ai-right tile">
        <RightBody s={s} shown={shown} beside />
      </div>
    </>
  );
}

/**
 * The folded page (the manager's design, 11-01): on Chat the status stacked over the live chat (StatusColumn), on the
 * bottom tabs' other screens that screen over the same tabs (RightBody, as unfolded's right column); a screen no tab
 * names (Friction) the one column with back.
 */
function Folded({ shown }: { shown: boolean }) {
  const s = aiScreen.value;
  useAgentsInPane(shown && s === "fleet");
  if (s === "chat") return <StatusColumn shown={shown} />;
  if (foldedTabbed(s)) return <RightBody s={s} shown={shown} />;
  return <AiColumn shown={shown} wide={false} pill />;
}

/** Folded, a bottom tab's screen - but one agent opened (a Working now row) is its own full page with back ("Agent"). */
const foldedTabbed = (s: AiScreen) => SEGMENTED.has(s) && !(s === "fleet" && aiAgent.value);

/** The folded page's classes: .status on Chat (the status page), .stacked wherever the bottom tabs lead. */
const foldedClass = (s: AiScreen) => `${s === "chat" ? "status" : ""} ${foldedTabbed(s) ? "stacked" : ""}`;

export function AiView({ shown, cls, pill = true, panes = false }: { shown: boolean; cls: string; pill?: boolean; panes?: boolean }) {
  const [ref, wide, rail] = useWide();
  if (panes && wide)
    return (
      <div ref={ref} class={`${aiViewClass(cls, true, false)} panes ${rail ? "rail" : ""}`}>
        <AiPanes shown={shown} />
      </div>
    );
  // The page folded: one pane of the backdrop's glass under the stacked status, the chat and the tabs (shell.css .ai-glass).
  if (panes)
    return (
      <div ref={ref} class={`${aiViewClass(cls, false, false)} ${foldedClass(aiScreen.value)}`}>
        <div class="ai-glass tile" aria-hidden="true" />
        <Folded shown={shown} />
      </div>
    );
  return (
    <div ref={ref} class={aiViewClass(cls, wide, wide && aiScreen.value === "progress")}>
      <AiColumn shown={shown} wide={wide} pill={pill} />
    </div>
  );
}

/**
 * The AI page folded: the status page (aistatus.tsx) stacked over the live chat, the bottom tabs and the field under
 * it (the manager's design, 11-01) - its header's ⋯ opens what no bottom tab does (Friction;
 * folded "Open chat" - the launcher's AI panel - unfolded Other projects). [beside]: unfolded, the page's left column (the screens open in
 * the right one, the chat's field is the ask).
 */
function StatusColumn({ shown, beside = false }: { shown: boolean; beside?: boolean }) {
  const [menu, setMenu] = useState(false);
  const pop = usePresence(menu);
  // Friction, and folded "Open chat" / unfolded "Other projects (N)" while other projects' agents work.
  const n = menuScreens(true).length + (beside ? Number(otherProjectsCount() > 0) : 1);
  const more = <More n={n} menu={menu} setMenu={setMenu} />;
  return (
    <>
      <AiStatus shown={shown} more={more} compose={beside ? null : <FoldedFoot shown={shown} />} mic={pageMic} beside={beside} chat={beside ? null : <AiBody sub={null} shown={shown} />} />
      {menu && <div class="ai-menu-scrim" onClick={() => setMenu(false)} />}
      {pop.on && <Menu close={() => setMenu(false)} tabs leaving={pop.leaving}>{beside ? <OtherProjectsItem close={() => setMenu(false)} /> : <OpenChatItem close={() => setMenu(false)} />}</Menu>}
    </>
  );
}

/**
 * The folded page's foot: the same bottom tabs as unfolded (Chat the default), then the seam where home's one shared bar
 * mounts (the user, 11-01 17:52: "The chat here shouldn't have its own search bar: reuse the existing one from home, it
 * just acts differently on this page") - no field of the page's own; .ai-bar-slot only keeps the bar's room.
 */
function FoldedFoot({ shown }: { shown: boolean }) {
  return (
    <>
      <AiSegs shown={shown} />
      <div class="ai-bar-slot" data-bar-slot="ai" aria-hidden="true" />
    </>
  );
}

/** Folded, the ⋯ menu's "Open chat": the launcher's AI panel over home (the status page's old foot link). */
function OpenChatItem({ close }: { close: () => void }) {
  return (
    <button type="button" role="menuitem" class="ai-menu-item" onClick={() => (close(), openChat())}>
      Open chat
    </button>
  );
}

/** The one column (folded, or a holder without panes): the header, the chat or a menu screen, the field; Progress a sheet wide. */
function AiColumn({ shown, wide, pill }: { shown: boolean; wide: boolean; pill: boolean }) {
  const s = aiScreen.value;
  const split = wide && s === "progress";
  const sub = s !== "chat" && !split ? s : null;
  return (
    <>
      <AiHeader sub={sub} shown={shown && !sub} />
      <AiBody sub={sub} shown={shown} />
      {/* OB1: no field of its own - the one shared bar (bar.tsx, its "ai" role) takes this room. */}
      {!sub && (pill || wide) && <div class="ai-bar-slot" data-bar-slot="ai" aria-hidden="true" />}
      {split && <Sheet s={s} shown={shown} />}
    </>
  );
}

/** Its page, to the left of home. */
export function PowAiPage() {
  const shown = page.value === -1;
  // Tells the host the page is up (types.ts pageShown: hosts since 11-02 open the assist overlay over it all the same).
  useEffect(() => void powos.ai.pageShown?.(shown).catch(() => {}), [shown]);
  return <AiView shown={shown} cls={`ai-screen ${shown ? "shown" : ""}`} panes />;
}

/**
 * An "at work" session (PowOS AI's page) opened: its tmux session in the page's own terminal (terminal.tsx), grown out
 * of the card that was tapped to the whole screen, and back into it on Back - no other screen in between, as the
 * terminal widget's screen. The pty is the page's while it shows; closed, tmux keeps the session (only this client
 * detaches). A session of another host (the Mac's) opens over that host's link (`powos terms attach`). Every session
 * opens view-only - a read-only tmux client, so nothing typed reaches a live agent - until "take over" (an agent's:
 * tapped twice) reopens it as a read-write client.
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { closeSession, sessionView, takeOver } from "../state.ts";
import { closeTerminal, TerminalView } from "./terminal.tsx";

/** The grow and the shrink back (ms), as the drawer's settle. */
const MS = 260;
const EASE = "cubic-bezier(0.2, 0.8, 0.2, 1)";

/** Its touches are its own: nothing under it (home's swipes, the page) sees them. */
const own = {
  onTouchStart: (e: TouchEvent) => e.stopPropagation(),
  onTouchMove: (e: TouchEvent) => e.stopPropagation(),
  onPointerDown: (e: PointerEvent) => e.stopPropagation(),
};

/** Where [r] is, as a transform of the full-screen box (its top-left corner the origin). */
const at = (r: DOMRect) =>
  `translate(${r.left}px, ${r.top}px) scale(${r.width / innerWidth}, ${r.height / innerHeight})`;

export function SessionScreen() {
  const s = sessionView.value;
  const el = useRef<HTMLDivElement>(null);
  // Opened: from the card to the screen.
  useLayoutEffect(() => {
    const box = el.current;
    if (!box || !s || s.closing || !s.from) return;
    box.style.transition = "none";
    box.style.transform = at(s.from);
    box.style.borderRadius = "calc(var(--radius) * 4)";
    box.style.opacity = "0.6";
    void box.offsetWidth;
    box.style.transition = `transform ${MS}ms ${EASE}, border-radius ${MS}ms ${EASE}, opacity ${MS / 2}ms linear`;
    box.style.transform = "none";
    box.style.borderRadius = "0";
    box.style.opacity = "1";
  }, [s?.name]);
  // Closing: back into the card (or just away, if it isn't on screen), then the terminal goes.
  useLayoutEffect(() => {
    const box = el.current;
    if (!box || !s?.closing) return;
    const done = () => {
      closeTerminal(id(s));
      if (sessionView.value?.closing) sessionView.value = null;
    };
    const card = s.card?.isConnected ? s.card.getBoundingClientRect() : null;
    box.style.transform = card && card.width ? at(card) : "translateY(8%)";
    box.style.borderRadius = "calc(var(--radius) * 4)";
    box.style.opacity = "0";
    const t = window.setTimeout(done, MS);
    return () => clearTimeout(t);
  }, [s?.closing]);
  if (!s) return null;
  return (
    <div ref={el} class="session-screen" {...own}>
      <div class="session-head">
        <button type="button" class="session-back" onClick={closeSession}>
          ‹
        </button>
        <span class="session-title">{s.name}</span>
        {s.task && <span class="session-task muted">{s.task}</span>}
        <TakeOver />
      </div>
      <TerminalView id={id(s)} command={command(s)} focus={!!s.write} class="session-term" />
    </div>
  );
}

/** How long an agent's "take over" waits for its second tap. */
const CONFIRM_MS = 3000;

/** View-only: the mark and the way to the keys (an agent's asks a second tap: it's a live Claude). Taken over: the mark. */
function TakeOver() {
  const s = sessionView.value!;
  const [asked, setAsked] = useState(false);
  useEffect(() => {
    if (!asked) return;
    const t = window.setTimeout(() => setAsked(false), CONFIRM_MS);
    return () => clearTimeout(t);
  }, [asked]);
  if (s.write) return <span class="session-mode taken">typing</span>;
  const tap = () => (s.agent && !asked ? setAsked(true) : takeOver());
  return (
    <button type="button" class={`session-mode ${asked ? "asked" : ""}`} onClick={tap}>
      {asked ? "type into the live agent? tap again" : `${s.agent ? "agent · " : ""}view only · take over`}
    </button>
  );
}

type Opened = NonNullable<typeof sessionView.value>;

const id = (s: Opened) => `at-work:${s.host ?? "local"}:${s.name}`;

/** A read-only client until taken over; this host's tmux directly, another's over its link (lib/apps/powos-terms). */
const command = (s: Opened) =>
  s.local || !s.host
    ? `tmux attach ${s.write ? "" : "-r "}-t '${s.name}'`
    : `powos terms attach '${s.host}' '${s.name}'${s.write ? " --write" : ""}`;

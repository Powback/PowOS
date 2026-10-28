/**
 * PowOS AI in the launcher: what typing something that isn't an app shows - the conversation with PowOS's manager
 * (the same one its own app and the desktop's manager widget show), newest by the bar. Enter asks it what's typed.
 */
import { useEffect, useRef } from "preact/hooks";
import { chat, query } from "../state.ts";
import { powos } from "../bridge.ts";
import type { ChatItem } from "../types.ts";
import { MailCard, Queued, Said, SentImages, Thread, ToolRun, mailOf } from "./rich.tsx";

/** How much of the conversation the launcher shows; the rest is in PowOS AI's page (left of home). */
const SHOWN = 40;

/** One line of the conversation: here, and in PowOS AI's page (its whole history). */
export function Item({ item, reply = null }: { item: ChatItem; reply?: string | null }) {
  switch (item.kind) {
    case "user":
      // The question only: the screen the side button sent along with it (assist.tsx) isn't part of what was said.
      return (
        <div class="msg user">
          {item.text.split("\n\n[What's on my screen right now")[0]}
          <SentImages text={item.text} />
        </div>
      );
    case "assistant":
      return <Said text={item.text} reply={reply} />;
    case "tool":
      return <ToolRun tools={[item]} />;
    case "note":
      if (!item.error && mailOf(item.text)) return <MailCard text={item.text} />;
      return <div class={`msg note ${item.error ? "error" : "muted"}`}>{item.text}</div>;
  }
}

/** [head]: its "PowOS AI · open" line (the assistant's panel over an app has its own). */
export function ChatView({ head = true }: { head?: boolean } = {}) {
  const list = useRef<HTMLDivElement>(null);
  const { busy, items } = chat.value;
  // Kept at the newest, by the bar, as a turn streams in.
  useEffect(() => {
    const el = list.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [items.length, items.at(-1)]);
  return (
    <div class={`chat ${head ? "" : "headless"}`} ref={list}>
      {head && (
        <div class="chat-head">
          <span class="muted">PowOS AI</span>
          <button type="button" class="chat-open" onClick={() => powos.ai.open()}>
            open ↗
          </button>
        </div>
      )}
      <Thread items={items.slice(-SHOWN)} render={(item, reply) => <Item item={item} reply={reply} />} />
      {busy && <div class="msg tool muted thinking">thinking…</div>}
      <Queued />
      <AskHint list={list} busy={busy} empty={!items.length} />
    </div>
  );
}

/**
 * What Enter will ask. The only part of the chat that reads the pill: typing re-rendered the whole conversation and
 * scrolled it to the end on every key (the user, 2026-10-28: "launcher chat refreshes every keypress"). It follows the
 * text at the end only when the chat was already there; scrolled up, the conversation stays put.
 */
function AskHint({ list, busy, empty }: { list: { current: HTMLDivElement | null }; busy: boolean; empty: boolean }) {
  const typed = query.value.trim();
  const atEnd = useRef(true);
  const el = list.current;
  if (el) atEnd.current = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
  useEffect(() => {
    const box = list.current;
    if (box && atEnd.current) box.scrollTop = box.scrollHeight;
  }, [typed]);
  if (typed && !busy) return <div class="msg ask muted">↵ ask “{typed}”</div>;
  return empty && !typed ? <div class="msg muted">Type anything that isn't an app to ask PowOS AI.</div> : null;
}

/**
 * PowOS AI in the launcher: what typing something that isn't an app shows - the conversation with PowOS's manager
 * (the same one its own app and the desktop's manager widget show), newest by the bar. Enter asks it what's typed.
 */
import { useEffect, useRef } from "preact/hooks";
import { chat, query } from "../state.ts";
import { powos } from "../bridge.ts";
import type { ChatItem } from "../types.ts";
import { Queued, Said, Thread, ToolRun } from "./rich.tsx";

/** How much of the conversation the launcher shows; the rest is in PowOS AI's page (left of home). */
const SHOWN = 40;

/** One line of the conversation: here, and in PowOS AI's page (its whole history). */
export function Item({ item, reply = null }: { item: ChatItem; reply?: string | null }) {
  switch (item.kind) {
    case "user":
      // The question only: the screen the side button sent along with it (assist.tsx) isn't part of what was said.
      return <div class="msg user">{item.text.split("\n\n[What's on my screen right now")[0]}</div>;
    case "assistant":
      return <Said text={item.text} reply={reply} />;
    case "tool":
      return <ToolRun tools={[item]} />;
    case "note":
      return <div class={`msg note ${item.error ? "error" : "muted"}`}>{item.text}</div>;
  }
}

/** [head]: its "PowOS AI · open" line (the assistant's panel over an app has its own). */
export function ChatView({ head = true }: { head?: boolean } = {}) {
  const list = useRef<HTMLDivElement>(null);
  const { busy, items } = chat.value;
  const typed = query.value.trim();
  // Kept at the newest, by the bar, as a turn streams in.
  useEffect(() => {
    const el = list.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [items.length, items.at(-1), typed]);
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
      {typed && !busy && <div class="msg ask muted">↵ ask “{typed}”</div>}
      {!items.length && !typed && <div class="msg muted">Type anything that isn't an app to ask PowOS AI.</div>}
    </div>
  );
}

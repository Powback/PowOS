/**
 * PowOS AI in the launcher: what typing something that isn't an app shows - the conversation with PowOS's manager
 * (the same one its own app and the desktop's manager widget show), newest by the bar. Enter asks it what's typed.
 */
import { useEffect, useRef } from "preact/hooks";
import { chat, query } from "../state.ts";
import { powos } from "../bridge.ts";
import type { ChatItem } from "../types.ts";

/** How much of the conversation the launcher shows; the rest is in PowOS AI's page (left of home). */
const SHOWN = 40;

/** One line of the conversation: here, and in PowOS AI's page (its whole history). */
export function Item({ item }: { item: ChatItem }) {
  switch (item.kind) {
    case "user":
      return <div class="msg user">{item.text}</div>;
    case "assistant":
      return <div class="msg assistant">{item.text}</div>;
    case "tool":
      return (
        <div class="msg tool muted">
          <span class={item.ok === null ? "run" : item.ok ? "ok" : "fail"}>{item.ok === null ? "…" : item.ok ? "✓" : "✗"}</span>{" "}
          {item.name} <span class="hint">{item.hint}</span>
        </div>
      );
    case "note":
      return <div class={`msg note ${item.error ? "error" : "muted"}`}>{item.text}</div>;
  }
}

export function ChatView() {
  const list = useRef<HTMLDivElement>(null);
  const { busy, items } = chat.value;
  const typed = query.value.trim();
  // Kept at the newest, by the bar, as a turn streams in.
  useEffect(() => {
    const el = list.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [items.length, items.at(-1), typed]);
  return (
    <div class="chat" ref={list}>
      <div class="chat-head">
        <span class="muted">PowOS AI</span>
        <button type="button" class="chat-open" onClick={() => powos.ai.open()}>
          open ↗
        </button>
      </div>
      {items.slice(-SHOWN).map((item, i) => (
        <Item key={i} item={item} />
      ))}
      {busy && <div class="msg tool muted thinking">thinking…</div>}
      {typed && !busy && <div class="msg ask muted">↵ ask “{typed}”</div>}
      {!items.length && !typed && <div class="msg muted">Type anything that isn't an app to ask PowOS AI.</div>}
    </div>
  );
}

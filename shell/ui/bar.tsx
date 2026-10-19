/**
 * The bar at the bottom: it finds apps and asks PowOS AI. Tapping it types - the keyboard comes up then, not when the
 * drawer is swiped open, which is for browsing. Enter opens the best match; with none, it asks PowOS AI (chat.tsx).
 */
import { useRef } from "preact/hooks";
import { matches } from "./drawer.tsx";
import { ask, drawer, launch, query } from "../state.ts";
import { powos } from "../bridge.ts";

export function Bar() {
  const input = useRef<HTMLInputElement>(null);
  return (
    <form
      class="bar tile"
      onSubmit={(e) => {
        e.preventDefault();
        const best = matches.value[0];
        if (best) launch(best.key);
        else ask(query.value);
      }}
      onClick={() => {
        drawer.value = 1;
        input.current?.focus();
        powos.keyboard.show();
      }}
    >
      <span class="prompt">❯</span>
      <input
        ref={input}
        value={query.value}
        onInput={(e) => (query.value = (e.currentTarget as HTMLInputElement).value)}
        placeholder="find an app or ask PowOS AI"
        enterKeyHint={query.value.trim() && !matches.value.length ? "send" : "go"}
        autocomplete="off"
        autoCapitalize="off"
        spellcheck={false}
      />
    </form>
  );
}

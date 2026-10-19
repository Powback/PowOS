/**
 * The bar at the bottom: it finds apps (and, later, asks agents). Tapping it types - the keyboard comes up then, not
 * when the drawer is swiped open, which is for browsing. Enter opens the best match.
 */
import { useRef } from "preact/hooks";
import { matches } from "./drawer.tsx";
import { drawer, launch, query } from "../state.ts";
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
        placeholder="find an app"
        enterKeyHint="go"
        autocomplete="off"
        autoCapitalize="off"
        spellcheck={false}
      />
    </form>
  );
}

/**
 * The bar at the bottom: it finds apps (and, later, asks agents). Tapping it types - the keyboard comes up then, not
 * when the drawer is swiped open, which is for browsing. Enter opens the best match.
 */
import { useRef } from "preact/hooks";
import { html } from "./html.js";
import { drawer, launch, query } from "../state.js";
import { powos } from "../bridge.js";

export function Bar() {
  const input = useRef(null);
  return html`
    <form
      class="bar tile"
      onSubmit=${(e) => {
        e.preventDefault();
        const first = document.querySelector(".drawer .app");
        first?.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));
        first?.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
      }}
      onPointerDown=${() => {
        drawer.value = 1;
        input.current?.focus();
        powos.keyboard.show();
      }}
    >
      <span class="prompt">❯</span>
      <input
        ref=${input}
        value=${query.value}
        onInput=${(e) => (query.value = e.currentTarget.value)}
        placeholder="find an app"
        enterkeyhint="go"
        autocomplete="off"
        autocapitalize="off"
        spellcheck=${false}
      />
    </form>
  `;
}

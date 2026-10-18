/** html`...`: htm bound to Preact - JSX in a tagged template, so the shell needs no compiler. */
import { h } from "preact";
import htm from "htm";

export const html = htm.bind(h);

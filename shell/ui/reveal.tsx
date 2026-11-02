/**
 * Folds and menus without pop-ins (docs/DESIGN-LANGUAGE.md §6; design wave 5, the AI page): [Reveal] for a fold's
 * body, [usePresence] for a menu leaving, [Details] for a native <details> that opens on the spring. One copy for the
 * shell and the apps: it is ui/shared/reveal.tsx (`@powos/shared/reveal`, which apps' own UIs import - they can't
 * reach this file), re-exported here so the shell's imports and lint-design's rule keep naming ui/reveal.tsx.
 */
export { Details, Reveal, reducedMotion, springToken, usePresence } from "./shared/reveal.tsx";

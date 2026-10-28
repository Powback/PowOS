/**
 * An open folder (state.ts folder: a home folder's key, or an app library category's "lib:<category>"): the tile
 * itself grows into it and shrinks back (the user, 2026-10-23: "opening folders is so jarring").
 *
 * - The morph is FLIP: the sheet's frost layer (.folder-bg, a .tile: its compositor region follows the transition,
 *   nativeglass.ts) starts at the tile's box - translate + scale - and eases to the sheet's own; the first four icons
 *   fly from their mini places in the tile to their cells, the others and the title fade in. Closing is the same
 *   backwards, into wherever the tile is then (Back, a tap outside, a swipe down, an app opened, it all ends there).
 * - Focus: home's own content steps out (shell.css .home:has(.folder-view.open)) and a page-sized frost (.folder-focus,
 *   its compositor blur and a soft dim) fades in, so only the blurred wallpaper is behind the sheet - the compositor
 *   blurs what's under the window, never home's tiles in it, so they fade rather than blur.
 * - Transforms and opacity only, inline only while it moves: at rest nothing is left to draw.
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { folder, home } from "../state.ts";
import { AppPress, folderNames, morphing, nameFolder, type DragOut } from "./folders.tsx";
import { library } from "./library.tsx";
import { geometry } from "./grid.tsx";

const MORPH_MS = 240;
/** A spring's ease: a little past, then home. */
const EASE = "cubic-bezier(0.3, 1.25, 0.4, 1)";
const SWIPE_CLOSE = 70;

type Shown = { key: string; name: string; apps: { key: string; label: string; app: string }[]; own: boolean };

function shownOf(key: string | null): Shown | null {
  if (!key) return null;
  const f = home.value.items.find((i) => i.key === key && i.kind === "folder");
  if (f) return { key, name: folderNames.value[key] ?? "", apps: f.apps!, own: true };
  const l = library.value.find((x) => x.key === key);
  return l ? { key, name: l.name, apps: l.apps, own: l.own } : null;
}

/** The tile the folder opens from (its face on home, its card in the library). */
const tileOf = (key: string) =>
  document.querySelector<HTMLElement>(`.home-tile[data-key="${CSS.escape(key)}"] .folder-face, .lib-card[data-key="${CSS.escape(key)}"]`);

/** Its mini icons, in order. */
const minisOf = (tile: HTMLElement | null) => (tile ? [...tile.querySelectorAll<HTMLElement>(".folder-face > img, .folder-face > span, .lib-icons > .app-icon")] : []);

/** [a] -> [b] as a transform from the top left (b's box drawn at a's). */
function from(a: DOMRect, b: DOMRect) {
  return `translate(${a.left - b.left}px, ${a.top - b.top}px) scale(${a.width / (b.width || 1)}, ${a.height / (b.height || 1)})`;
}

/** Sets where each moving part is at the far end ([out]: at the tile) - with no transition, or easing to it. */
function place(root: HTMLElement, out: boolean, ease: boolean) {
  const bg = root.querySelector<HTMLElement>(".folder-bg")!;
  const focus = root.querySelector<HTMLElement>(".folder-focus")!;
  const tile = tileOf(root.dataset.key!);
  const t = tile?.getBoundingClientRect();
  const icons = [...root.querySelectorAll<HTMLElement>(".folder-grid .app .app-icon")];
  const minis = minisOf(tile);
  const fades = [...root.querySelectorAll<HTMLElement>(".folder-title, .folder-grid .app-label")];
  const all = [bg, focus, ...icons, ...fades];
  for (const el of all) el.style.transition = ease ? `transform ${MORPH_MS}ms ${EASE}, opacity ${MORPH_MS}ms ease-out` : "none";
  focus.style.opacity = out ? "0" : "1";
  bg.style.transform = out && t ? from(t, bg.getBoundingClientRect()) : "";
  icons.forEach((icon, i) => {
    const m = minis[i]?.getBoundingClientRect();
    const r = icon.getBoundingClientRect();
    icon.style.transform = out ? (m && i < 4 ? from(m, r) : "scale(0.4)") : "";
    icon.style.opacity = out && !(m && i < 4) ? "0" : "";
  });
  for (const el of fades) el.style.opacity = out ? "0" : "";
}

/** Clears what the morph left inline: at rest the sheet is as its CSS says. */
function rest(root: HTMLElement) {
  for (const el of root.querySelectorAll<HTMLElement>(".folder-bg, .folder-focus, .app-icon, .folder-title, .app-label")) {
    el.style.transition = "";
    el.style.transform = "";
    el.style.opacity = "";
  }
}

/** Once every transition in [el] has ended (or was cancelled); at once when none runs. */
function transitionsEnded(el: HTMLElement) {
  const moving = el.getAnimations({ subtree: true }).filter((a) => a instanceof CSSTransition);
  return Promise.allSettled(moving.map((a) => a.finished));
}

/** Mounts the morph: grows out of the tile on open; when [folder] closes, shrinks back into it, then goes. */
function useMorph(root: { current: HTMLElement | null }, closing: boolean, done: () => void) {
  useLayoutEffect(() => {
    const el = root.current;
    if (!el) return;
    if (!closing) {
      place(el, true, false);
      void el.offsetWidth;
      place(el, false, true);
    } else place(el, true, true);
    // Ends when the transitions do, not on a clock: a timer of MORPH_MS + 40 fired before a late-starting transition
    // (a busy frame on open) was through - it cut the sheet's last frames (a snap) and left the frost still fading.
    let live = true;
    void transitionsEnded(el).then(async () => {
      if (!live) return;
      if (!closing) return rest(el);
      // Closing is the mirror of opening: the tile's own mini icons come back under the landed ones, and only once they
      // are painted do the sheet's go - never a frame where the tile is empty (the user, 2026-10-28).
      tileOf(el.dataset.key!)?.closest(".home-tile, .lib-card")?.classList.remove("opened");
      tileOf(el.dataset.key!)?.classList.remove("opened");
      await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
      if (live) done();
    });
    return () => void (live = false);
  }, [closing]);
}

function Sheet({ s, closing, onHold, done }: { s: Shown; closing: boolean; onHold: DragOut; done: () => void }) {
  const root = useRef<HTMLDivElement>(null);
  const swipe = useRef<number | null>(null);
  useMorph(root, closing, done);
  const close = () => (folder.value = null);
  const g = geometry.value;
  const cols = Math.min(4, Math.max(1, s.apps.length));
  return (
    <div
      ref={root}
      class={`folder-view ${closing ? "" : "open"}`}
      data-key={s.key}
      style={{ "--fcell-w": `${g.cellW || 76}px`, "--fcell-h": `${Math.max(g.cellH, g.cellW) || 86}px`, "--fcols": cols }}
      onClick={close}
      onPointerDown={(e) => (swipe.current = e.clientY)}
      onPointerUp={(e) => {
        // Swiped down: it closes (as a tap outside does).
        if (swipe.current != null && e.clientY - swipe.current > SWIPE_CLOSE) close();
        swipe.current = null;
      }}
    >
      <div class="folder-focus tile" />
      <div class="folder-sheet" onClick={(e) => e.stopPropagation()}>
        <div class="folder-bg tile" />
        <div class="folder-body">
          {s.own ? (
            <input
              class="folder-title folder-name"
              key={s.key}
              value={s.name}
              placeholder="Folder"
              aria-label="Folder name"
              enterKeyHint="done"
              onChange={(e) => nameFolder(s.key, (e.currentTarget as HTMLInputElement).value)}
              onKeyDown={(e) => e.key === "Enter" && (e.currentTarget as HTMLInputElement).blur()}
            />
          ) : (
            <div class="folder-title">{s.name}</div>
          )}
          <div class="folder-grid">
            {s.apps.map((a) => (
              <AppPress key={a.key} a={a} from={s.own ? s.key : undefined} onHold={onHold} onLeave={close} onLift={close} />
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

/** The open folder, its morph in and out (mounted once, in the pages: grid.tsx). */
export function FolderView({ onHold }: { onHold: DragOut }) {
  const live = shownOf(folder.value);
  // The last one shown, kept while it shrinks back after the folder closed.
  const [last, setLast] = useState<Shown | null>(null);
  useEffect(() => void (live && live.key !== last?.key && setLast(live)), [live?.key]);
  const s = live ?? last;
  useLayoutEffect(() => void (morphing.value = s?.key ?? null), [s?.key]);
  if (!s) return null;
  return <Sheet key={s.key} s={live ?? s} closing={!live} onHold={onHold} done={() => setLast(null)} />;
}

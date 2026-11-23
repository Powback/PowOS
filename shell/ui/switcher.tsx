/**
 * A task's card in the switcher (recents.tsx, a layer of home): its app's icon and label above its last frame. A tap
 * opens it (the card grows to the screen, then the app is there); flung or pushed up it's removed, carried on at the
 * finger's speed; let go short of that it springs back; sideways the row scrolls (the browser's, with momentum). The
 * icon (or a long press) opens its menu. Android's split screen is one card (t.split): its apps' icons as ONE combined
 * icon (GroupIcon, the dock's DG1 group cell's) over the whole split - each side's last frame at its share of the
 * screen, side by side or one over the other as on the screen (t.splitLayout).
 *
 * Unfolded with Open Canvas ([canDock]): pushed up AND toward a side (ui/carddock.ts) it docks into the native split
 * view on that side - the card follows the finger sideways too and the target half lights up ([onDockHover]) while
 * it's in a dock zone; a mostly vertical push is a removal as before.
 */
import { useRef, useState } from "preact/hooks";
import type { RecentTask, SplitSide } from "../types.ts";
import { spring } from "./spring.ts";
import { tick } from "./haptics.ts";
import { memo } from "./memo.ts";
import { cardRelease, dockSide, type DockSide } from "./carddock.ts";

const SLOP = 10;
/** Held this long without moving: the card's menu (Android's long-press timeout). */
const LONG_PRESS = 450;

/** A press on a card as it goes: where it began, how far up / sideways the card is, the dock half it targets. */
interface Drag {
  x: number;
  y: number;
  dy: number;
  dx: number;
  side: DockSide | null;
  up: boolean | null;
  samples: { y: number; t: number }[];
  press: number;
}

export interface Rect {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** Memoised: recents.tsx passes stable handlers (by task id), so a card renders again only when its own task does. */
export const TaskCard = memo(function TaskCard({
  t,
  current,
  eager,
  pinned,
  picked,
  load = true,
  onOpen,
  onRemove,
  onMenu,
  canDock,
  onDockHover,
  onDock,
}: {
  t: RecentTask;
  /** The first card: where the window of the app the switcher was opened over lands (recents.tsx). */
  current?: boolean;
  /** Its snapshot loaded at once (the cards in view), not when scrolled to. */
  eager?: boolean;
  /** Kept on "clear all" (a pin on its head). */
  pinned?: boolean;
  /** Picked as split screen's first app (the second is being picked). */
  picked?: boolean;
  /**
   * Its snapshot in the page: off while the switcher is closed - a hidden layer of decoded snapshots took the page's
   * GPU memory from home's own tiles (hosted widgets blanked mid-swipe). They're in the HTTP cache for the next time.
   */
  load?: boolean;
  onOpen: (id: number, shot: HTMLElement) => void;
  /** False: it stays (the card springs back). */
  onRemove: (id: number) => boolean | void;
  onMenu: (id: number, card: HTMLElement) => void;
  /** Open Canvas is there (unfolded, supported, an Android app's card): up and to a side docks it. */
  canDock?: boolean;
  /** The half a dock would go to as the finger moves (null: none) - the layer shows it. */
  onDockHover?: (side: DockSide | null) => void;
  /** Let go in a dock zone; false: it stays (the card springs back). */
  onDock?: (id: number, side: DockSide) => boolean | void;
}) {
  const el = useRef<HTMLDivElement>(null);
  const shot = useRef<HTMLElement>(null);
  const drag = useRef<Drag | null>(null);
  const gone = useRef(false);

  /** Back to its place, as a spring from where the finger left it. */
  const springBack = (dy: number, dx = 0) => {
    const card = el.current!;
    card.style.transform = "";
    card.style.opacity = "";
    card.animate(
      [
        { transform: `translate(${dx}px, ${dy}px)`, opacity: String(1 - Math.min(1, -dy / card.clientHeight)) },
        { transform: "none", opacity: "1" },
      ],
      { duration: spring.ms, easing: spring.easing },
    );
  };

  /** The half shown under the finger (or none), told to the layer only when it changes; entering one ticks. */
  const hover = (side: DockSide | null) => {
    const d = drag.current;
    if (!d || d.side === side) return;
    d.side = side;
    if (side) tick();
    onDockHover?.(side);
  };

  /**
   * Docked: the card goes on toward its half and fades (the app comes up there); [onDock] refusing it (no partner,
   * the host said no) springs it back. The half's highlight goes either way.
   */
  const dockAway = (dx: number, dy: number, side: DockSide) => {
    const card = el.current!;
    onDockHover?.(null);
    if (onDock?.(t.id, side) === false) return springBack(dy, dx);
    gone.current = true;
    const to = side === "left" ? -card.getBoundingClientRect().right : innerWidth - card.getBoundingClientRect().left;
    card.style.transform = "";
    card.animate(
      [
        { transform: `translate(${dx}px, ${dy}px)`, opacity: "1" },
        { transform: `translate(${dx + to * 0.25}px, ${dy}px) scale(0.9)`, opacity: "0" },
      ],
      { duration: spring.ms, easing: spring.easing, fill: "forwards" },
    ).onfinish = () => (gone.current = false);
  };

  /** Removed: on up and out at the finger's speed (at least a brisk one), then gone from the list. */
  const flingAway = (dy: number, v: number, dx = 0) => {
    const card = el.current!;
    gone.current = true;
    const to = -(card.getBoundingClientRect().bottom + 40);
    const speed = Math.max(Math.abs(v), 1.6); // px/ms
    const ms = Math.min(260, Math.max(120, (dy - to) / speed));
    card.style.transform = "";
    card.animate(
      [
        { transform: `translate(${dx}px, ${dy}px)`, opacity: String(1 - Math.min(1, -dy / card.clientHeight)) },
        { transform: `translate(${dx}px, ${to}px)`, opacity: "0" },
      ],
      { duration: ms, easing: spring.easing, fill: "forwards" },
    ).onfinish = () => onRemove(t.id);
  };

  /** An upward drag's move: down past its place it barely moves (a rubber band), up it follows the finger. */
  const follow = (d: Drag, e: PointerEvent, dx: number, dy: number) => {
    d.dy = dy < 0 ? dy : dy * 0.15;
    // Sideways it follows the finger only where it can dock (the old pure-vertical drag everywhere else).
    d.dx = canDock ? dx : 0;
    d.samples.push({ y: e.clientY, t: e.timeStamp });
    while (d.samples.length > 2 && e.timeStamp - d.samples[0].t > 80) d.samples.shift();
    const card = el.current!;
    if (canDock) hover(dockSide({ dx, dy, x: e.clientX, cardH: card.clientHeight, screenW: innerWidth }));
    card.style.transform = `translate(${d.dx}px, ${d.dy}px)`;
    card.style.opacity = String(1 - Math.min(1, Math.max(0, -d.dy) / card.clientHeight));
  };

  /** An upward drag let go ([mx]: the finger's sideways travel): docked, removed or back (ui/carddock.ts cardRelease). */
  const letGo = (d: Drag, e: PointerEvent, mx: number) => {
    // The click this release makes (on whatever is under it now - the layer beside the cards, which closes the
    // switcher) isn't one: swallowed.
    // (Only the click of this release: one that never came is no longer waited for at the next touch.)
    const swallow = (c: MouseEvent) => c.stopPropagation();
    window.addEventListener("click", swallow, { capture: true, once: true });
    window.addEventListener("pointerdown", () => window.removeEventListener("click", swallow, true), { capture: true, once: true });
    const first = d.samples[0];
    const v = (e.clientY - first.y) / Math.max(1, e.timeStamp - first.t);
    const r = cardRelease({ dx: mx, dy: d.dy, x: e.clientX, cardH: el.current!.clientHeight, screenW: innerWidth }, v, !!canDock);
    if (r.kind === "dock") return dockAway(d.dx, d.dy, r.side);
    if (d.side) onDockHover?.(null);
    if (r.kind === "remove") flingAway(d.dy, v, d.dx);
    else springBack(d.dy, d.dx);
  };

  const cancelPress = () => {
    const d = drag.current;
    if (d?.press) clearTimeout(d.press);
    if (d) d.press = 0;
  };

  return (
    <div
      ref={el}
      class={`task ${current ? "current" : ""} ${pinned ? "pinned" : ""} ${picked ? "picked" : ""}`}
      data-task={t.id}
      onPointerDown={(e) => {
        if (gone.current) return;
        const press = window.setTimeout(() => {
          // Held still: its menu, and the touch is the menu's now.
          drag.current = null;
          tick();
          onMenu(t.id, el.current!);
        }, LONG_PRESS);
        drag.current = { x: e.clientX, y: e.clientY, dy: 0, dx: 0, side: null, up: null, samples: [{ y: e.clientY, t: e.timeStamp }], press };
        // The rest of this press is the card's, wherever it goes (a touch is captured by its target anyway): a mouse's or
        // pen's quick swipe whose moves came coalesced into one far above the card (11-02, gate under load) went to the
        // layer beside the cards - its release there "a tap beside the cards", the app it was opened over opened.
        if (e.pointerType !== "touch") el.current!.setPointerCapture(e.pointerId);
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d) return;
        const dx = e.clientX - d.x;
        const dy = e.clientY - d.y;
        if (d.up == null && Math.hypot(dx, dy) > SLOP) {
          cancelPress();
          // Up: the card's (removing it); sideways: the row scrolls (the browser has it, touch-action pan-x).
          d.up = dy < 0 && Math.abs(dy) > Math.abs(dx);
          if (d.up) el.current!.setPointerCapture(e.pointerId);
          else (drag.current = null), el.current!.releasePointerCapture(e.pointerId);
        }
        if (d.up) follow(d, e, dx, dy);
      }}
      onPointerUp={(e) => {
        const d = drag.current;
        cancelPress();
        drag.current = null;
        if (!d || gone.current) return;
        const mx = e.clientX - d.x;
        const my = e.clientY - d.y;
        // Moved without the moves coming in (a quick swipe whose moves the page got coalesced into the release): what
        // it was is decided now, from where it ended - up a long way is a removal, not a tap.
        if (d.up == null && Math.hypot(mx, my) > SLOP) {
          if (my < 0 && Math.abs(my) > Math.abs(mx)) {
            d.up = true;
            d.dy = my;
            d.dx = canDock ? mx : 0;
            d.samples.push({ y: e.clientY, t: e.timeStamp });
          } else return; // sideways: the row's scroll
        }
        if (d.up) letGo(d, e, mx);
        else if (d.up == null) {
          // A tap: on the icon, its menu; elsewhere, the app.
          if ((e.target as HTMLElement).closest(".task-icon")) onMenu(t.id, el.current!);
          else onOpen(t.id, shot.current!);
        }
      }}
      onPointerCancel={() => {
        const d = drag.current;
        cancelPress();
        drag.current = null;
        if (d?.side) onDockHover?.(null);
        if (d?.up) springBack(d.dy, d.dx);
      }}
      onContextMenu={(e) => e.preventDefault()}
    >
      <TaskHead t={t} />
      {t.split ? <SplitShot t={t} load={load} eager={eager || current} /> : <CardShot t={t} load={load} eager={eager || current} shotRef={shot} />}
    </div>
  );
});

/**
 * A card's picture; none, or one that failed to load (a 404: no snapshot and nothing cached; an SVG that didn't
 * decode): its placeholder instead - never the browser's broken image, never a hidden (empty) card. Its own component:
 * a failure re-renders it alone, not its card.
 */
function CardShot({ t, load, eager, shotRef }: { t: RecentTask; load: boolean; eager?: boolean; shotRef: { current: HTMLElement | null } }) {
  const [failed, setFailed] = useState<string | null>(null);
  const src = load ? t.snapshot : undefined;
  if (noPicture(load, t.snapshot, failed)) return <ShotPlaceholder shotRef={shotRef} icon={t.icon} class="task-shot" />;
  return (
    <img
      ref={shotRef as { current: HTMLImageElement | null }}
      class="task-shot"
      src={src}
      alt=""
      draggable={false}
      decoding="async"
      loading={eager ? "eager" : "lazy"}
      onLoad={(e) => ((e.currentTarget as HTMLImageElement).style.visibility = "")}
      onError={(e) => setFailed((e.currentTarget as HTMLImageElement).getAttribute("src"))}
    />
  );
}

/** A card's picture shows its placeholder: it has none (while loaded), or the one it has failed. */
const noPicture = (load: boolean, snapshot: string, failed: string | null) => load && (!snapshot || failed === snapshot);

/**
 * No picture of a task (none yet, or it failed to load): its app's icon centred on glass tinted by the icon itself, as
 * a launch's splash - never the browser's broken image or a black card (11-01: "native apps fail to render in the
 * switcher"). A <div> as .task-shot: recents.tsx's landing decodes only an <img> shot, opening one opens the app plainly.
 */
export function ShotPlaceholder({ icon, class: cls, shotRef, grow }: { icon: string | null; class: string; shotRef?: { current: HTMLElement | null }; grow?: number }) {
  const [bad, setBad] = useState(false);
  const ok = !!icon && !bad;
  const style = { ...(ok && { "--ph-icon": `url("${icon}")` }), ...(grow != null && { flexGrow: grow }) };
  return (
    <div ref={shotRef as { current: HTMLDivElement | null } | undefined} class={`${cls} task-ph`} style={style}>
      {ok ? <img class="task-ph-icon" src={icon} alt="" draggable={false} onError={() => setBad(true)} /> : <span class="task-ph-icon blank" />}
    </div>
  );
}

/**
 * An app's icon, or a blank in its place. Memoised: its card re-renders on every recents update (new onOpen/onMenu),
 * the icon's src the same - 117 of 131 renders needless in perf-1793409569119's render scan.
 */
const Icon = memo(function Icon({ src }: { src: string | null }) {
  // One that fails to load is a blank too, never a broken image.
  const [bad, setBad] = useState<string | null>(null);
  return src && bad !== src ? <img class="task-icon" src={src} alt="" draggable={false} onError={() => setBad(src)} /> : <span class="task-icon blank" />;
});

/**
 * A group's icons together: a split card's apps (Android's split screen), and the dock's cell for a PowOS window group
 * (ui/dockgroups.tsx: a tiling's tiles, a tab stack's tabs) - 2-4 mini icons, laid out as [layout] (a Tiling's layout,
 * "stack" for tabs; CSS lays each out as the group sits on screen; none: side by side).
 */
export function SplitIcons({ icons, layout }: { icons: (string | null)[]; layout?: string }) {
  return (
    <span class="task-icons" data-layout={layout}>
      {icons.map((src, i) => (
        <Icon key={i} src={src} />
      ))}
    </span>
  );
}

/**
 * A group's combined icon: one tile holding its apps' mini icons (SplitIcons) in its layout - the dock's cell for a
 * PowOS window group (ui/dockgroups.tsx) and a split card's head (Android's split screen), the same component.
 */
export function GroupIcon({ icons, layout, class: cls }: { icons: (string | null)[]; layout?: string; class: string }) {
  return (
    <div class={`${cls} group-icon`}>
      <SplitIcons icons={icons} layout={layout} />
    </div>
  );
}

/** What a head shows of [t]: a new task object from each recents update is the same head when these are. */
const sameHead = (a: { t: RecentTask }, b: { t: RecentTask }) =>
  a.t === b.t ||
  (a.t.icon === b.t.icon &&
    a.t.label === b.t.label &&
    a.t.pip === b.t.pip &&
    a.t.splitLayout === b.t.splitLayout &&
    (a.t.split ?? []).length === (b.t.split ?? []).length &&
    (a.t.split ?? []).every((s, i) => s.id === b.t.split![i].id && s.icon === b.t.split![i].icon));

/** A card's head: its app's icon (a split's: every app's, combined) and its label. Re-rendered only when those change ([sameHead]). */
const TaskHead = memo(function TaskHead({ t }: { t: RecentTask }) {
  return (
    <div class="task-head">
      {t.split ? (
        <GroupIcon class="task-group" icons={t.split.map((s) => s.icon)} layout={t.splitLayout ?? "2h"} />
      ) : (
        <Icon src={t.icon} />
      )}
      <span class="task-label">{t.label}</span>
      {t.pip && <span class="task-pip">PiP</span>}
    </div>
  );
}, sameHead);

/**
 * A split card's picture: the whole split, each side's last frame at its share of the screen, as the split divides it
 * (side by side, or one over the other folded: t.splitLayout) (a <div>
 * as .task-shot: recents.tsx's landing decodes only an <img> shot, and leaves this one as it is).
 */
function SplitShot({ t, load, eager }: { t: RecentTask; load: boolean; eager?: boolean }) {
  return (
    <div class="task-shot task-split" data-layout={t.splitLayout ?? "2h"}>
      {t.split!.map((s) => (
        <SplitSideShot key={s.id} s={s} load={load} eager={eager} />
      ))}
    </div>
  );
}

/** One side of a split card's picture; none (or it failed): that app's placeholder at its share. */
function SplitSideShot({ s, load, eager }: { s: SplitSide; load: boolean; eager?: boolean }) {
  const [failed, setFailed] = useState<string | null>(null);
  const src = load ? s.snapshot : undefined;
  if (noPicture(load, s.snapshot, failed)) return <ShotPlaceholder icon={s.icon} class="task-split-side" grow={s.share} />;
  return (
    <img
      class="task-split-side"
      style={{ flexGrow: s.share }}
      src={src}
      alt=""
      draggable={false}
      decoding="async"
      loading={eager ? "eager" : "lazy"}
      onError={(e) => setFailed((e.currentTarget as HTMLImageElement).getAttribute("src"))}
    />
  );
}

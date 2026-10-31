/**
 * Needs you on the folded status page as a stack of cards (design QA, 2026-10-31: "more dynamic and futuristic"): one
 * big glass card at a time - the task, its try line or question, a screenshot when it has one - the rest peeking behind
 * it (how many are left). Swipe right: works (a thing to do: done); left: still broken (can't), opening the field to say
 * why by voice or text; up: later (to the back). The same buttons under it. Asks, things to do and things ready to try
 * are all in the one stack. Every answer goes through trycard.tsx's calls (tryVerdict / doVerdict / askVerdict), as the
 * rows did. "Try" opens the thing (the app by name, the launcher, home's windows); back on the page, that card is first
 * and asks "Worked?".
 */
import { useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { apps, launch, openPanel, page } from "../state.ts";
import { list } from "./aiboard.tsx";
import { BrokenReply } from "./brokenreply.tsx";
import { itemOf, type Need } from "./needsyou.tsx";
import { imageUrl, openFull } from "./rich.tsx";
import { askVerdict, doVerdict, sendOf, tryVerdict } from "./trycard.tsx";

/** A drag this far (px) sideways or up commits its action; less springs back. */
const COMMIT_PX = 96;
/** The fly-out before the answer takes the card away (ms; the CSS's .ais-card-top.fly). */
const FLY_MS = 220;
/** How many cards peek behind the top one. */
const PEEK = 2;

/** Put off this session ("later"): to the back of the stack. */
const later = signal<string[]>([]);
/** The card whose Try was pressed: first when the page shows again, asking "Worked?" (kept across a reload). */
const TRYING = "powos.ai.trying";
const read = () => {
  try {
    return localStorage.getItem(TRYING);
  } catch {
    return null;
  }
};
export const trying = signal<string | null>(read());
function setTrying(id: string | null) {
  trying.value = id;
  try {
    if (id) localStorage.setItem(TRYING, id);
    else localStorage.removeItem(TRYING);
  } catch {
    // No storage: it is still first for this session.
  }
}

/** The stack's order: the one just tried first, then the rest, the ones put off last (in the order they were). */
export function stackOrder(needs: Need[], tried = trying.value, off = later.value) {
  const rank = (n: Need) => (n.w.id === tried ? -1 : off.indexOf(n.w.id) + 1);
  return [...needs].sort((a, b) => rank(a) - rank(b));
}

/** What a try line opens: an app it names (the longest label in it), the launcher, or home (where windows live). */
export function tryTarget(line: string): { kind: "app"; key: string; label: string } | { kind: "launcher" | "home" } {
  const low = ` ${line.toLowerCase()} `;
  const named = apps.value
    .filter((a) => a.label.length >= 3 && new RegExp(`[^a-z0-9]${a.label.toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}[^a-z0-9]`).test(low))
    .sort((a, b) => b.label.length - a.label.length)[0];
  if (named) return { kind: "app", key: named.key, label: named.label };
  return /launcher|app drawer|drawer|all apps/i.test(line) ? { kind: "launcher" } : { kind: "home" };
}

/** Try pressed: the thing opens; this card is marked to come first, asking "Worked?", on the way back. */
function openTry(n: Need) {
  setTrying(n.w.id);
  const t = tryTarget(n.line);
  page.value = 0;
  if (t.kind === "app") void launch(t.key);
  else if (t.kind === "launcher") openPanel("apps");
}

type Dir = "right" | "left" | "up";

/** right: works / done; up: later; left: the field (its send is the "still broken" / "can't" / answer). */
function commit(n: Need, dir: Dir, ask: () => void) {
  const it = itemOf(n);
  if (dir === "left") return ask();
  if (n.w.id === trying.value) setTrying(null);
  if (dir === "up") return (later.value = [...later.value.filter((x) => x !== n.w.id), n.w.id]);
  if (it.ask) return ask();
  if (it.do) doVerdict(it);
  else void tryVerdict(it, true, undefined, "board");
}

/** The answer field's send: the same call as the rows' reply line, and the try mark cleared. */
function sendWhy(n: Need) {
  const send = sendOf(itemOf(n), "board");
  return (b: Parameters<typeof send>[0]) => {
    if (n.w.id === trying.value) setTrying(null);
    send(b);
  };
}

/** Which way a drag of [dx, dy] commits (null: not far enough). */
function dirOf(dx: number, dy: number): Dir | null {
  if (-dy > COMMIT_PX && -dy > Math.abs(dx)) return "up";
  if (Math.abs(dx) > COMMIT_PX) return dx > 0 ? "right" : "left";
  return null;
}

/** The top card's drag: it follows the finger (transform only, no re-render), commits past COMMIT_PX, else springs back. */
function useSwipe(onCommit: (d: Dir) => void) {
  const ref = useRef<HTMLDivElement>(null);
  const at = useRef<{ x: number; y: number; id: number } | null>(null);
  const move = (dx: number, dy: number) => {
    const el = ref.current;
    if (!el) return;
    el.style.transform = `translate(${dx}px, ${Math.min(0, dy)}px) rotate(${dx / 24}deg)`;
    el.dataset.lean = dirOf(dx, dy) ?? "";
  };
  const end = (e: PointerEvent) => {
    const s = at.current;
    const el = ref.current;
    at.current = null;
    if (!s || !el) return;
    const d = dirOf(e.clientX - s.x, e.clientY - s.y);
    el.style.transform = "";
    el.dataset.lean = "";
    el.classList.remove("dragging");
    if (d) onCommit(d);
  };
  const handlers = {
    onPointerDown: (e: PointerEvent) => {
      if ((e.target as Element).closest("button, textarea, input, .ai-reply")) return;
      at.current = { x: e.clientX, y: e.clientY, id: e.pointerId };
      (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
      ref.current?.classList.add("dragging");
    },
    onPointerMove: (e: PointerEvent) => at.current && move(e.clientX - at.current.x, e.clientY - at.current.y),
    onPointerUp: end,
    onPointerCancel: end,
  };
  return [ref, handlers] as const;
}

const KIND: Record<Need["kind"], string> = { try: "Ready to try", do: "To do", ask: "Question" };

/** The card's screenshot: a thumbnail (a tap: full screen); none when the page can't load it. */
function Shot({ n }: { n: Need }) {
  const [failed, setFailed] = useState(false);
  const url = list<string>(n.w.images).map(imageUrl).find(Boolean);
  if (!url || failed) return null;
  return (
    <button type="button" class="ais-shot" onClick={() => openFull(n.w.title, <img class="ai-img-full" src={url} alt="" />)}>
      <img src={url} alt="" loading="lazy" onError={() => setFailed(true)} />
    </button>
  );
}

/** The buttons under the top card: the same three actions as the swipes; a question: its options and "answer". */
function Acts({ n, go }: { n: Need; go: (d: Dir) => void }) {
  const it = itemOf(n);
  if (it.ask)
    return (
      <div class="ais-acts">
        {(it.options ?? []).map((o) => (
          <button key={o} type="button" class="ais-act yes" onClick={() => void askVerdict(it, o, "board")}>
            {o}
          </button>
        ))}
        <button type="button" class="ais-act" onClick={() => go("left")}>
          answer
        </button>
        <button type="button" class="ais-act later" onClick={() => go("up")}>
          later
        </button>
      </div>
    );
  return (
    <div class="ais-acts">
      <button type="button" class="ais-act no" onClick={() => go("left")}>
        {it.do ? "can't" : "still broken"}
      </button>
      <button type="button" class="ais-act later" onClick={() => go("up")}>
        later
      </button>
      <button type="button" class="ais-act yes" onClick={() => go("right")}>
        {it.do ? "done" : "works"}
      </button>
    </div>
  );
}

/** The top card: kind, title, its sentence, the screenshot, Try; dragged, it leans to the action it would take. */
function TopCard({ n, count }: { n: Need; count: number }) {
  const [why, setWhy] = useState(false);
  const [fly, setFly] = useState<Dir | null>(null);
  const go = (d: Dir) => {
    if (d === "left" || (d === "right" && n.kind === "ask")) return setWhy(true);
    setFly(d);
    window.setTimeout(() => commit(n, d, () => setWhy(true)), FLY_MS);
  };
  const [ref, drag] = useSwipe(go);
  const asking = n.w.id === trying.value;
  return (
    <div ref={ref} class={`ais-card-top ${fly ? `fly ${fly}` : ""}`} data-task={n.w.id} data-kind={n.kind} data-owns-gesture {...drag}>
      <span class="ais-card-kind">{asking ? "Worked?" : KIND[n.kind]}</span>
      {count > 1 && <span class="ais-card-count">1 of {count}</span>}
      <span class="ais-card-title">{n.w.title}</span>
      <span class="ais-card-line">{n.line}</span>
      <Shot n={n} />
      {n.kind === "try" && (
        <button type="button" class="ais-try" onClick={() => openTry(n)}>
          Try it
        </button>
      )}
      {why ? (
        <BrokenReply id={n.w.id} onSend={sendWhy(n)} onCancel={() => setWhy(false)} ask={n.kind === "ask" ? "your answer" : n.kind === "do" ? "what's in the way" : undefined} />
      ) : (
        <Acts n={n} go={go} />
      )}
    </div>
  );
}

/** Needs you: the stack (top card + the next ones peeking), its count; none: not drawn. */
export function NeedStack({ needs }: { needs: Need[] }) {
  if (!needs.length) return null;
  const order = stackOrder(needs);
  const top = order[0];
  const behind = Math.min(PEEK, order.length - 1);
  return (
    <section class="ais-sec ais-stack-sec" data-sec="needs" aria-label="Needs you">
      <h3 class="ais-h">
        Needs you<span class="ais-n">{needs.length}</span>
      </h3>
      <div class="ais-stack" data-count={needs.length} style={{ "--peek": behind }}>
        {Array.from({ length: behind }, (_, i) => (
          <span key={i} class="ais-card-peek" style={{ "--i": behind - i }} aria-hidden="true" />
        ))}
        <TopCard key={top.w.id} n={top} count={needs.length} />
      </div>
    </section>
  );
}

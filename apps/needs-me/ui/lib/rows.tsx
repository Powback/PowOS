/**
 * The rows the widget and the page share: app icon(s), who, one line, when. A tap opens the reply field under the row
 * (the bar's pill: keyboard, mic, send), a swipe sideways marks it read, a tap on an app icon opens that conversation in
 * its app. Every action is the notification's own (act.ts), on that one gesture.
 */
import { useLayoutEffect, useRef, useState } from "preact/hooks";
import { isMarked, markRead, openEntry, sendReply, stateOf, type Host, type ReplyFieldProps } from "./act";
import { ago, groups, replyTarget, sourceOf, type Entry, type Group } from "./model";

export type Phase = "old" | "loading" | "no-access" | "ok";

/** The rows now, live: marked-read notifications left out while unchanged. */
export function useGroups(host: Host, app: string): { phase: Phase; groups: Group[] } {
  const l = host.notifications?.useList(app);
  if (!host.notifications) return { phase: "old", groups: [] };
  if (!l) return { phase: "loading", groups: [] };
  if (!l.available) return { phase: "no-access", groups: [] };
  return { phase: "ok", groups: groups(l.items).map((g) => ({ ...g, entries: g.entries.filter((e) => !isMarked(e)) })).filter((g) => g.entries.length) };
}

const stop = (e: Event) => e.stopPropagation();

/** [ref]'s laid-out size (CSS px, transforms aside), live. */
export function useSize(ref: { current: HTMLElement | null }): [number, number] {
  const [size, setSize] = useState<[number, number]>([0, 0]);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const read = () => setSize((s) => (s[0] === el.offsetWidth && s[1] === el.offsetHeight ? s : [el.offsetWidth, el.offsetHeight]));
    read();
    const ro = new ResizeObserver(read);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return size;
}

/** Line height of a clamped text, em of its own size: rows are a fixed height (widgets/main.tsx counts what fits). */
export const LINE = 1.25;

const cut = (text: string, k: number) => (k >= text.length ? text : text.slice(0, k).trimEnd() + "…");

/**
 * [text] in at most [lines] lines, shortened at a word's or letter's end with "…" when longer - measured, so nothing
 * is cut by the box (a probe beside it, never the shown node).
 */
export function Clamp({ text, lines, style }: { text: string; lines: number; style?: Record<string, unknown> }) {
  const ref = useRef<HTMLDivElement>(null);
  const [w] = useSize(ref);
  const [n, setN] = useState(text.length);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el?.parentElement || !w) return;
    const probe = el.cloneNode(false) as HTMLDivElement;
    Object.assign(probe.style, { position: "absolute", visibility: "hidden", width: `${el.clientWidth}px`, left: "0", top: "0" });
    el.parentElement.appendChild(probe);
    const max = (parseFloat(getComputedStyle(el).lineHeight) || 16) * lines + 1;
    const fits = (k: number) => ((probe.textContent = cut(text, k)), probe.offsetHeight <= max);
    let lo = 0;
    let hi = text.length;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (fits(mid)) lo = mid;
      else hi = mid - 1;
    }
    probe.remove();
    setN(lo);
  }, [text, lines, w]);
  return (
    <div ref={ref} style={{ ...style, whiteSpace: "normal", overflowWrap: "anywhere", overflow: "visible", minHeight: `${lines * LINE}em` }}>
      {cut(text, n)}
    </div>
  );
}
const soft = "color-mix(in srgb, currentColor 10%, transparent)";

/** One app icon per app in the row (newest first): its tap opens that app's conversation. */
function Icons({ g, host, app }: { g: Group; host: Host; app: string }) {
  const seen = new Map<string, Entry>();
  for (const e of g.entries) if (!seen.has(sourceOf(e.n))) seen.set(sourceOf(e.n), e);
  return (
    <div style={{ display: "flex", flex: "none" }}>
      {[...seen.values()].slice(0, 2).map((e, i) => (
        <button
          key={e.n.key}
          aria-label={`open in ${sourceOf(e.n)}`}
          data-open={e.n.key}
          style={{ ...S.icon, marginLeft: i ? "-0.6em" : 0 }}
          onPointerDown={stop}
          onClick={(ev) => {
            ev.stopPropagation();
            openEntry(host, app, e);
          }}
        >
          {e.n.icon ? <img src={e.n.icon} alt="" style={{ width: "100%", height: "100%", borderRadius: "50%" }} /> : sourceOf(e.n).slice(0, 1)}
        </button>
      ))}
    </div>
  );
}

const SWIPE = 0.3;

/** A sideways drag past [SWIPE] of the row's width: [onSwipe]; less, it springs back. A drag is never a tap. */
function useSwipe(onSwipe: () => void) {
  const [dx, setDx] = useState(0);
  const at = useRef<{ x: number; y: number; w: number; moved: boolean } | null>(null);
  const moved = useRef(false);
  const handlers = {
    onPointerDown(e: PointerEvent) {
      e.stopPropagation();
      at.current = { x: e.clientX, y: e.clientY, w: (e.currentTarget as HTMLElement).offsetWidth || 1, moved: false };
      moved.current = false;
    },
    onPointerMove(e: PointerEvent) {
      const a = at.current;
      if (!a) return;
      const x = e.clientX - a.x;
      if (!a.moved && Math.abs(x) > 8 && Math.abs(x) > Math.abs(e.clientY - a.y)) {
        a.moved = moved.current = true;
        // The drag stays the row's off its edge; a pointer that's already gone has none to capture.
        try {
          (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
        } catch {}
      }
      if (a.moved) setDx(x);
    },
    onPointerUp(e: PointerEvent) {
      const a = at.current;
      at.current = null;
      setDx(0);
      if (a?.moved && Math.abs(e.clientX - a.x) > a.w * SWIPE) onSwipe();
    },
    onPointerCancel() {
      at.current = null;
      setDx(0);
    },
  };
  return { dx, moved, handlers };
}

function Line({ g, lines }: { g: Group; lines: number }) {
  const s = stateOf(g);
  const text = s?.state === "sending" ? "Sending…" : s?.state === "sent" ? "Sent" : s?.state === "error" ? `Didn't go: ${s.message}` : g.entries[0].line;
  return <Clamp text={text} lines={lines} style={{ ...S.line, color: s?.state === "error" ? "var(--color-red)" : undefined }} />;
}

export function Row({ g, host, app, open, onToggle, lines = 2 }: { g: Group; host: Host; app: string; open: boolean; onToggle(): void; lines?: number }) {
  const { dx, moved, handlers } = useSwipe(() => void markRead(host, app, g));
  return (
    <div class="nm-row" data-group={g.id} style={{ display: "flex", flexDirection: "column", gap: "0.35em", flex: "none" }}>
      <div
        {...handlers}
        role="button"
        data-owns-gesture=""
        style={{ ...S.row, transform: dx ? `translateX(${dx}px)` : undefined, opacity: dx ? 1 - Math.min(0.6, Math.abs(dx) / 300) : 1 }}
        onClick={() => !moved.current && onToggle()}
      >
        <Icons g={g} host={host} app={app} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={S.who}>
            <Clamp text={g.who} lines={1} style={{ flex: 1, minWidth: 0, lineHeight: LINE }} />
            {g.count > 1 && <span style={S.badge}>{g.count}</span>}
          </div>
          <Line g={g} lines={lines} />
        </div>
        <div style={S.time}>{ago(g.time)}</div>
      </div>
      {open && <Reply g={g} host={host} app={app} done={onToggle} />}
    </div>
  );
}

/** A plain field and send, where the shell has no pill to lend (an older one). */
function Plain(p: ReplyFieldProps) {
  return (
    <form
      onPointerDown={stop}
      onSubmit={(e) => {
        e.preventDefault();
        if (p.value.trim() && !p.sending) p.onSend();
      }}
      style={{ display: "flex", gap: "0.4em" }}
    >
      <input value={p.value} onInput={(e) => p.onInput((e.currentTarget as HTMLInputElement).value)} placeholder={p.placeholder} aria-label="reply" style={S.input} />
      <button type="submit" disabled={!p.value.trim() || p.sending} aria-label="send" style={S.pillButton}>
        Send
      </button>
    </form>
  );
}

/** The reply field under a row: the text goes only when send (or Enter) is tapped, once. */
function Reply({ g, host, app, done }: { g: Group; host: Host; app: string; done(): void }) {
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const going = useRef(false);
  const t = replyTarget(g);
  if (!t) {
    const e = g.entries[0];
    return (
      <div style={{ ...S.line, display: "flex", alignItems: "center", gap: "0.5em" }} onPointerDown={stop}>
        <span style={{ flex: 1 }}>{sourceOf(e.n)} takes replies in the app</span>
        <button style={S.pillButton} onClick={() => openEntry(host, app, e)}>
          Open
        </button>
      </div>
    );
  }
  const Field = host.notifications?.ReplyField ?? Plain;
  const send = async () => {
    // One press per tap: a second tap (or Enter) while it goes is ignored - the state lags a render, the ref doesn't.
    if (going.current) return;
    going.current = true;
    setSending(true);
    const ok = await sendReply(host, app, g, text);
    going.current = false;
    setSending(false);
    if (ok) {
      setText("");
      done();
    }
  };
  return <Field value={text} onInput={setText} onSend={send} sending={sending} placeholder={`Reply in ${sourceOf(t.n)}`} />;
}

export const S = {
  row: { display: "flex", alignItems: "center", gap: "0.6em", touchAction: "pan-y", cursor: "pointer", userSelect: "none" },
  icon: {
    width: "2.1em",
    height: "2.1em",
    flex: "none",
    padding: 0,
    border: "2px solid var(--color-background)",
    borderRadius: "50%",
    background: soft,
    color: "var(--color-foreground)",
    font: "inherit",
    fontWeight: 600,
    display: "grid",
    placeItems: "center",
    overflow: "hidden",
  },
  who: { display: "flex", alignItems: "center", gap: "0.4em", fontWeight: 600, position: "relative" },
  line: { fontSize: "0.85em", color: "var(--color-muted)", lineHeight: LINE },
  time: { fontSize: "0.75em", color: "var(--color-muted)", flex: "none", alignSelf: "flex-start", marginTop: "0.2em" },
  badge: { fontSize: "0.7em", fontWeight: 600, padding: "0 0.5em", borderRadius: "1em", background: "var(--color-accent)", color: "var(--color-background)", lineHeight: 1.5 },
  input: { flex: 1, minWidth: 0, font: "inherit", padding: "0.5em 0.8em", borderRadius: "1.2em", border: 0, background: soft, color: "var(--color-foreground)" },
  pillButton: { font: "inherit", fontSize: "0.85em", padding: "0.35em 0.9em", borderRadius: "1em", border: 0, background: soft, color: "var(--color-foreground)" },
} as const;

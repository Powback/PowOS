/**
 * OWL widgets in the web shell. The host runs the widget (the same engine the Compose launcher uses) and sends its
 * node tree whenever it changes (ShellWidgets / WidgetTree.kt); this draws it the way Render.kt does - same defaults,
 * gaps, alignments and text sizes - and sends back taps, drags and sizes. Lengths are dp, which are CSS px.
 */
import type { JSX } from "preact";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { signal, type Signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { carry, selected } from "../state.ts";
import { takeTap, tapTaken } from "./taps.ts";
import { TerminalView } from "./terminal.tsx";
import type { Cell, OwlNode, OwlOp, OwlRoot, ThemeColors } from "../types.ts";

/**
 * Text colours as the shell's tokens, so a widget's words read on the glass in every theme (docs/DESIGN-LANGUAGE.md:
 * text >= 4.5:1). The engine resolves a widget's `color: muted` / `accent` / `green` to the theme palette's value
 * (WidgetInstance.kt): the theme's own muted grey measured 1.5-3.7:1 and a raw hue as little as 1.04:1 on the glass.
 * So a text colour that is the theme's muted becomes --color-muted, its accent --accent-text, its foreground the
 * foreground; any other (a hue, or a palette that isn't the shell's) 35% its own, 65% the foreground (small text: a
 * half-way mix still measured 2.9-3.6:1 on a light theme).
 * Only text: rings, bars and fills keep the widget's colours.
 */
let palette: { muted: Set<string>; accent?: string; foreground?: string } = { muted: new Set() };
const rgbKey = (c: string) => {
  const m = c.match(/rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/i);
  if (m) return [m[1], m[2], m[3]].map((v) => Math.round(Number(v))).join(",");
  const h = c.trim().match(/^#([0-9a-f]{6})/i);
  if (h) {
    const n = parseInt(h[1], 16);
    return `${n >> 16},${(n >> 8) & 255},${n & 255}`;
  }
  return c.trim().toLowerCase();
};
function learnTheme(t: ThemeColors | null) {
  if (!t) return;
  // A theme's grey for secondary text comes under more than one name (the host's css.muted is its dark_foreground; a
  // widget's `muted` can be the palette's own muted): any of them is the muted token (kanagawa's measured 4.06:1 as
  // an unknown hue's mix).
  const named = (t.colors ?? {}) as Record<string, string | undefined>;
  palette = {
    muted: new Set([t.css.muted, named.muted, named.dark_foreground].filter((c): c is string => !!c).map(rgbKey)),
    accent: rgbKey(t.css.accent ?? ""),
    foreground: rgbKey(t.css.foreground ?? ""),
  };
}
powos.on("theme.changed", learnTheme);
powos.theme.get().then(learnTheme, () => {});
/** A text's colour: [c] (the engine's) as the token it stands for; none - [fallback]. */
export function textColor(c: unknown, fallback: string) {
  if (typeof c !== "string" || !c) return fallback;
  const k = rgbKey(c);
  if (palette.muted.has(k)) return "var(--color-muted)";
  if (k === palette.accent) return "var(--accent-text)";
  if (k === palette.foreground) return "var(--color-foreground)";
  return `color-mix(in srgb, ${c} 35%, var(--color-foreground))`;
}
/** The same for a canvas's text (no CSS variables there): [c] mixed into the foreground [fg] in JS. */
function canvasText(c: string, fg: string) {
  const a = rgbKey(c).split(",").map(Number);
  const b = rgbKey(fg).split(",").map(Number);
  if (a.length !== 3 || b.length !== 3 || [...a, ...b].some((v) => !Number.isFinite(v))) return c;
  return `rgb(${a.map((v, i) => Math.round(v * 0.35 + b[i] * 0.65)).join(",")})`;
}

type Style = JSX.CSSProperties;
type Props = Record<string, any>;

interface Ctx {
  key: string;
  /** Drawing the widget's screen (full size), not its tile. */
  screen: boolean;
  fire(id: string, name: string, args: number[]): void;
  canvas(id: string, w: number, h: number): void;
  image(src: string): HTMLImageElement;
}

/** Trees by widget key (and key#screen): signals, so only the widget whose tree changed redraws. */
const trees = new Map<string, Signal<OwlRoot | null>>();
const tree = (id: string) => {
  if (!trees.has(id)) trees.set(id, signal(null));
  return trees.get(id)!;
};
powos.on("widget.tree", ({ key, screen, tree: t }: { key: string; screen: boolean; tree: OwlRoot | null }) => (tree(screen ? `${key}#screen` : key).value = t));

/** As long as a home tile's long press: a press held this long lifts the tile, it isn't the widget's tap. */
const TAP_MS = 400;
const SIZES: Record<string, number> = { huge: 44, title: 20, small: 11, label: 11 };
const FONTS: Record<string, string> = { sans: "system-ui, sans-serif", serif: "serif", icon: '"Symbols Nerd Font", "JetBrainsMono Nerd Font", monospace' };
const BOX_ALIGN: Record<string, [string, string]> = {
  center: ["center", "center"],
  top: ["center", "start"],
  bottom: ["center", "end"],
  start: ["start", "center"],
  end: ["end", "center"],
  topEnd: ["end", "start"],
  bottomStart: ["start", "end"],
  bottomEnd: ["end", "end"],
};
const JUSTIFY: Record<string, string> = { center: "center", end: "flex-end", spaceBetween: "space-between", spaceAround: "space-around", spaceEvenly: "space-evenly" };

const num = (v: unknown, d: number) => (typeof v === "number" && isFinite(v) ? v : d);
const px = (v: unknown) => `${Math.min(num(v, 0), 4000)}px`;
const text = (v: unknown) => (v == null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));

function padding(v: unknown) {
  if (typeof v === "number") return px(Math.max(0, v));
  if (Array.isArray(v) && v.length === 2) return `${px(v[1])} ${px(v[0])}`;
  if (Array.isArray(v) && v.length === 4) return `${px(v[1])} ${px(v[2])} ${px(v[3])} ${px(v[0])}`;
  return undefined;
}

/** What every node takes (Render.kt common()): sizing, weight, offset, opacity/rotation/scale, clip, frame, padding. */
function common(p: Props, parent: string): Style {
  const s: Style = {};
  const w = num(p.weight, 0);
  if (w > 0 && (parent === "Row" || parent === "Column")) Object.assign(s, { flex: `${w} 1 0`, minWidth: 0, minHeight: 0 });
  if (p.fill === "height") s.height = "100%";
  else if (typeof p.fill === "string") s.width = "100%";
  else if (p.fill) Object.assign(s, { width: "100%", height: "100%" });
  if (p.size != null) s.width = s.height = px(p.size);
  if (p.width != null) s.width = px(p.width);
  if (p.height != null) s.height = px(p.height);
  const t: string[] = [];
  if (Array.isArray(p.offset)) t.push(`translate(${px(p.offset[0])}, ${px(p.offset[1])})`);
  if (p.rotation != null) t.push(`rotate(${num(p.rotation, 0)}deg)`);
  if (p.scale != null) t.push(`scale(${num(p.scale, 1)})`);
  if (t.length) s.transform = t.join(" ");
  if (p.opacity != null) s.opacity = Math.max(0, Math.min(1, num(p.opacity, 1)));
  const radius = num(p.radius, p.border != null ? 8 : 0);
  if (p.clip) s.overflow = "hidden";
  if (radius) s.borderRadius = px(radius);
  if (p.background) s.background = p.background;
  // No hard outlines (docs/DESIGN-LANGUAGE.md): a bordered box is a surface - the soft fill and --lift - and a border
  // in a colour of its own (a selection, a state) a soft ring of that colour.
  if (num(p.border, 0) > 0) {
    s.background ??= "var(--soft-fill)";
    s.boxShadow = p.borderColor ? `inset 0 0 0 1px color-mix(in srgb, ${p.borderColor} 55%, transparent)` : "var(--lift)";
  }
  const pad = padding(p.padding);
  if (pad) s.padding = pad;
  return s;
}

/**
 * onTap and onDrag, with coordinates in dp (the element's own). The press isn't stopped: the home tile's own long
 * press (lifting it) sees it too, and a press held that long isn't a tap.
 */
function handlers(node: OwlNode, fire: Ctx["fire"]) {
  if (!node.h?.length) return {};
  const tap = node.h.includes("onTap");
  const drag = node.h.includes("onDrag");
  let from: { x: number; y: number; t: number } | null = null;
  let last: { x: number; y: number } | null = null;
  return {
    onPointerDown: (e: PointerEvent) => {
      from = { x: e.clientX, y: e.clientY, t: performance.now() };
      last = { x: e.clientX, y: e.clientY };
    },
    onPointerMove: (e: PointerEvent) => {
      if (!drag || !last || !e.buttons || carry.value) return;
      const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
      fire(node.id, "onDrag", [e.clientX - last.x, e.clientY - last.y, e.clientX - r.left, e.clientY - r.top]);
      last = { x: e.clientX, y: e.clientY };
    },
    onPointerUp: (e: PointerEvent) => {
      const f = from;
      from = last = null;
      if (!tap || !f || carry.value || selected.value || tapTaken(e)) return;
      if (performance.now() - f.t > TAP_MS || Math.hypot(e.clientX - f.x, e.clientY - f.y) >= 10) return;
      takeTap(e); // an onTap further out doesn't also run
      const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
      fire(node.id, "onTap", [e.clientX - r.left, e.clientY - r.top]);
    },
  };
}

/** Kinds Render.kt draws at the full width they're offered when nothing sizes them (fillMaxWidth / fillMaxSize). */
const FILLS = new Set(["Text", "Grid", "Canvas", "Sparkline", "Progress", "Slider", "Shader", "Terminal"]);
const wideSeen = new WeakMap<OwlNode, boolean>();

/**
 * Compose's measuring, which CSS's shrink-to-fit doesn't do: an unsized Text, Grid, Canvas or chart, a `fill: width`,
 * or a Row whose children share it by weight takes the whole width it's offered - and so does whatever holds one. In a
 * Column (align-items: start) such a node is stretched; without it a screen's chart, list or grid came out at its
 * content's width - half the screen (the weather screen's 24 h chart and 3-day list).
 */
function wide(n: OwlNode): boolean {
  const seen = wideSeen.get(n);
  if (seen != null) return seen;
  const p = n.p ?? {};
  let w: boolean;
  if (p.width != null || p.size != null || p.fill === "height") w = false;
  else if (p.fill === true || p.fill === "width") w = true;
  else if (FILLS.has(n.k)) w = p.weight == null;
  else if ((n.k === "Row" || n.k === "Flow") && n.c?.some((c) => num(c.p?.weight, 0) > 0)) w = true;
  else w = !!n.c?.some(wide);
  wideSeen.set(n, w);
  return w;
}

function Nodes({ nodes, ctx, parent }: { nodes?: OwlNode[]; ctx: Ctx; parent: string }) {
  return <>{nodes?.map((n) => <Node key={n.id} node={n} ctx={ctx} parent={parent} />)}</>;
}

function Node({ node, ctx, parent }: { node: OwlNode; ctx: Ctx; parent: string }) {
  const p = node.p ?? {};
  const style = common(p, parent);
  if (parent === "Column" && wide(node)) style.alignSelf = "stretch";
  else if (parent === "Box" && wide(node)) style.justifySelf = "stretch";
  const on = handlers(node, ctx.fire);
  const sized = ["width", "height", "size", "fill", "weight"].some((k) => p[k] != null);
  const full: Style = sized ? {} : { width: "100%", height: "100%" };
  switch (node.k) {
    case "Column":
      return (
        <div
          {...on}
          style={{
            display: "flex",
            flexDirection: "column",
            gap: px(num(p.gap, 4)),
            alignItems: ({ center: "center", end: "flex-end" } as Record<string, string>)[p.align] ?? "flex-start",
            justifyContent: JUSTIFY[p.justify],
            overflowY: p.scroll ? "auto" : undefined,
            minHeight: 0,
            ...style,
          }}
        >
          <Nodes nodes={node.c} ctx={ctx} parent="Column" />
        </div>
      );
    case "Row":
    case "Flow":
      return (
        <div
          {...on}
          style={{
            display: "flex",
            flexDirection: "row",
            flexWrap: node.k === "Flow" || p.wrap ? "wrap" : "nowrap",
            gap: px(num(p.gap, 8)),
            alignItems: ({ top: "flex-start", start: "flex-start", bottom: "flex-end", end: "flex-end" } as Record<string, string>)[p.align] ?? "center",
            justifyContent: JUSTIFY[p.justify],
            minWidth: 0,
            ...style,
          }}
        >
          <Nodes nodes={node.c} ctx={ctx} parent="Row" />
        </div>
      );
    case "Box": {
      const [x, y] = BOX_ALIGN[p.align] ?? ["start", "start"];
      return (
        <div {...on} class="owl-box" style={{ display: "grid", justifyItems: x, alignItems: y, ...style }}>
          <Nodes nodes={node.c} ctx={ctx} parent="Box" />
        </div>
      );
    }
    case "Grid":
      return (
        <div {...on} style={{ display: "grid", gridTemplateColumns: `repeat(${Math.max(1, Math.min(12, num(p.columns, 2)))}, minmax(0, 1fr))`, gap: px(num(p.gap, 6)), ...style }}>
          <Nodes nodes={node.c} ctx={ctx} parent="Grid" />
        </div>
      );
    case "Text": {
      const lines = num(p.maxLines, p.style === "huge" || p.style === "title" ? 1 : 0);
      const muted = p.style === "muted" || p.style === "label";
      return (
        <div
          {...on}
          style={{
            // Across its column; in a Row only as wide as its text (shrinking to an ellipsis) - Render.kt's fillMaxWidth
            // there takes all the room a weighted sibling was meant to share ("8° / 5°" and "21 oct" drawn 0 wide).
            ...(p.width == null && p.weight == null && p.fill == null ? (parent === "Row" ? { flex: "0 1 auto", minWidth: 0 } : { width: "100%" }) : {}),
            color: textColor(p.color, muted ? "var(--color-muted)" : "var(--color-foreground)"),
            font: `${p.italic ? "italic " : ""}${p.bold ? "bold " : ""}${num(p.fontSize, SIZES[p.style] ?? 13)}px ${FONTS[p.font] ?? "var(--font)"}`,
            textAlign: (({ center: "center", end: "end" } as Record<string, string>)[p.align] ?? "start") as any,
            whiteSpace: lines === 1 ? "nowrap" : "pre-wrap",
            overflow: "hidden",
            textOverflow: "ellipsis",
            ...(lines > 1 ? { display: "-webkit-box", WebkitLineClamp: lines, WebkitBoxOrient: "vertical" } : {}),
            ...style,
          }}
        >
          {text(p.text)}
        </div>
      );
    }
    case "Button":
      return (
        <div
          {...on}
          style={{
            background: "var(--soft-fill)",
            boxShadow: "var(--lift)",
            borderRadius: px(num(p.radius, 8)),
            padding: "6px 10px",
            color: textColor(p.color, "var(--accent-text)"),
            font: "13px var(--font)",
            whiteSpace: "nowrap",
            overflow: "hidden",
            textOverflow: "ellipsis",
            textAlign: "center",
            ...style,
          }}
        >
          {text(p.text)}
        </div>
      );
    case "Progress": {
      const f = Math.max(0, Math.min(1, num(p.value, 0) / Math.max(num(p.max, 100), 1e-6)));
      return (
        <div {...on} style={{ background: p.track ?? "var(--color-surface)", ...(sized ? {} : { width: "100%", height: "8px" }), ...style }}>
          <div style={{ width: `${f * 100}%`, height: "100%", background: p.color ?? "var(--color-accent)" }} />
        </div>
      );
    }
    case "Ring":
      return <Ring p={p} on={on} style={{ ...(sized ? {} : { width: "64px", height: "64px" }), ...style }} />;
    case "Sparkline":
      return <Sparkline p={p} on={on} style={{ ...(sized ? {} : { width: "100%", height: "48px" }), ...style }} />;
    case "Image": {
      const src = text(p.src);
      if (!src) return null;
      return (
        <img
          {...on}
          src={`/_wimg/${encodeURIComponent(ctx.key)}/${encodeURIComponent(src)}`}
          alt=""
          draggable={false}
          style={{ objectFit: (({ cover: "cover", fill: "fill" } as Record<string, string>)[p.fit] ?? "contain") as any, display: "block", ...style }}
        />
      );
    }
    case "Canvas":
      return <Canvas node={node} ctx={ctx} on={on} style={{ ...full, ...style }} />;
    case "Shader":
      // AGSL shaders: WebGL later; their fallback color meanwhile, as Android before 13 shows.
      return <div {...on} style={{ background: p.fallback ?? "var(--color-surface)", ...full, ...style }} />;
    case "Spacer":
      return <div {...on} style={style} />;
    case "Slider":
      return (
        <input
          type="range"
          min={num(p.min, 0)}
          max={num(p.max, 1)}
          step={num(p.step, 0) || "any"}
          value={num(p.value, 0)}
          style={{ accentColor: p.color ?? "var(--color-accent)", ...(sized ? {} : { width: "100%" }), ...style }}
          onPointerDown={(e) => e.stopPropagation()}
          onInput={(e) => node.h?.includes("onChange") && ctx.fire(node.id, "onChange", [Number((e.currentTarget as HTMLInputElement).value)])}
        />
      );
    case "Input":
      return <div class="muted" style={{ font: "13px var(--font)", ...style }}>{text(p.placeholder ?? p.text)}</div>;
    case "Terminal": {
      // A command still loading (null) waits for its value, rather than starting a shell and restarting it (Render.kt).
      if ("command" in p && p.command == null) return null;
      // Terminals naming one session are one shell (a tile and its screen); else each node is its own.
      return (
        <div {...on} style={{ ...full, ...style }}>
          <TerminalView
            id={`${ctx.key}#${p.session != null ? `session:${text(p.session)}` : node.id}`}
            owner={ctx.key}
            command={p.command != null ? text(p.command) : null}
            interactive={p.interactive !== false}
            fontSize={typeof p.fontSize === "number" ? p.fontSize : null}
            textSize={typeof p.textSize === "number" ? p.textSize : null}
            // Only a screen takes the keyboard by itself (Render.kt's LocalInputFocus); a tile waits for a tap.
            focus={ctx.screen && p.focus === true}
            style={{ width: "100%", height: "100%" }}
          />
        </div>
      );
    }
    default:
      return (
        <div style={style}>
          <Nodes nodes={node.c} ctx={ctx} parent="Box" />
        </div>
      );
  }
}

function arc(cx: number, cy: number, r: number, from: number, sweep: number) {
  const rad = (d: number) => ((d - 90) * Math.PI) / 180;
  const a0 = rad(from);
  const a1 = rad(from + Math.min(sweep, 359.99));
  return `M ${cx + r * Math.cos(a0)} ${cy + r * Math.sin(a0)} A ${r} ${r} 0 ${sweep > 180 ? 1 : 0} 1 ${cx + r * Math.cos(a1)} ${cy + r * Math.sin(a1)}`;
}

interface Drawn {
  p: Props;
  on: object;
  style: Style;
}

/** Ring: 0 degrees is 12 o'clock, clockwise; a track, then the value's share of the sweep. */
function Ring({ p, on, style }: Drawn) {
  const t = num(p.thickness, 6);
  const start = num(p.start, 0);
  const sweep = num(p.sweep, 360);
  const f = Math.max(0, Math.min(1, num(p.value, 0) / Math.max(num(p.max, 1), 1e-6)));
  const r = 50 - t / 2;
  return (
    <svg {...on} viewBox="0 0 100 100" style={style}>
      <path d={arc(50, 50, r, start, sweep)} fill="none" stroke={p.track ?? "var(--color-surface)"} stroke-width={t} stroke-linecap="round" />
      {f > 0 && <path d={arc(50, 50, r, start, sweep * f)} fill="none" stroke={p.color ?? "var(--color-accent)"} stroke-width={t} stroke-linecap="round" />}
    </svg>
  );
}

function Sparkline({ p, on, style }: Drawn) {
  const values: number[] = (Array.isArray(p.values) ? p.values : []).filter((v: unknown) => typeof v === "number");
  if (values.length < 2) return <div {...on} style={style} />;
  const lo = num(p.min, 0);
  const hi = num(p.max, Math.max(lo + 1, lo + (Math.max(...values) - lo) * 1.15));
  const pts = values.map((v, i) => [(i / (values.length - 1)) * 100, 100 * (1 - Math.max(0, Math.min(1, (v - lo) / (hi - lo))))]);
  const line = pts.map(([x, y], i) => `${i ? "L" : "M"} ${x} ${y}`).join(" ");
  const area = typeof p.area === "string" ? p.area : p.area ? "color-mix(in srgb, currentColor 20%, transparent)" : null;
  return (
    <svg {...on} viewBox="0 0 100 100" preserveAspectRatio="none" style={{ color: p.color ?? "var(--color-accent)", ...style }}>
      {area && <path d={`${line} L 100 100 L 0 100 Z`} fill={area} stroke="none" />}
      <path d={line} fill="none" stroke="currentColor" stroke-width={num(p.thickness, 2)} stroke-linecap="round" vector-effect="non-scaling-stroke" />
    </svg>
  );
}

/** A Canvas: the host evaluates its drawing at the size this reports; this replays the ops on a 2D canvas. */
function Canvas({ node, ctx, on, style }: { node: OwlNode; ctx: Ctx; on: object; style: Style }) {
  const el = useRef<HTMLCanvasElement>(null);
  useLayoutEffect(() => {
    const c = el.current!;
    const ro = new ResizeObserver(() => {
      const r = c.getBoundingClientRect();
      ctx.canvas(node.id, r.width, r.height);
      paint(c, node.ops, ctx);
    });
    ro.observe(c);
    return () => ro.disconnect();
  }, [node.id]);
  useEffect(() => paint(el.current, node.ops, ctx), [node.ops]);
  return <canvas {...on} ref={el} style={{ display: "block", ...style }} />;
}

function paint(c: HTMLCanvasElement | null, ops: OwlOp[] | undefined, ctx: Ctx) {
  if (!c) return;
  const r = c.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  if (c.width !== Math.round(r.width * dpr) || c.height !== Math.round(r.height * dpr)) {
    c.width = Math.round(r.width * dpr);
    c.height = Math.round(r.height * dpr);
  }
  const g = c.getContext("2d")!;
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, r.width, r.height);
  draw(g, ops ?? [], ctx);
}

type Paint = string | CanvasGradient | null;

function brush(g: CanvasRenderingContext2D, v: any): Paint {
  if (!v) return null;
  if (typeof v === "string") return v;
  if (v.gradient) {
    const c: number[] = v.coords;
    const gr = v.gradient === "radial" ? g.createRadialGradient(c[0], c[1], 0, c[0], c[1], Math.max(c[2], 0.01)) : g.createLinearGradient(c[0], c[1], c[2], c[3]);
    v.colors.forEach((col: string | null, i: number) => gr.addColorStop(v.colors.length > 1 ? i / (v.colors.length - 1) : 0, col ?? "transparent"));
    return gr;
  }
  return null;
}

/** Canvas.kt's ops on a 2D context: same coordinates (dp), same defaults (fill with the foreground). */
function draw(g: CanvasRenderingContext2D, ops: OwlOp[], ctx: Ctx) {
  const fg = getComputedStyle(document.documentElement).getPropertyValue("--color-foreground").trim() || "#ddd";
  for (const o of ops) {
    const a = o.a;
    const n = o.n ?? {};
    const nested = () => draw(g, o.c ?? [], ctx);
    const group = (setup: () => void) => {
      g.save();
      setup();
      nested();
      g.restore();
    };
    switch (o.op) {
      case "translate":
        group(() => g.translate(a[0], a[1]));
        continue;
      case "rotate":
        group(() => {
          g.translate(a[1] ?? 0, a[2] ?? 0);
          g.rotate(((a[0] ?? 0) * Math.PI) / 180);
          g.translate(-(a[1] ?? 0), -(a[2] ?? 0));
        });
        continue;
      case "scale": {
        const sx = a[0] ?? 1;
        const sy = a.length > 1 ? a[1] : sx;
        group(() => {
          g.translate(a[2] ?? 0, a[3] ?? 0);
          g.scale(sx, sy);
          g.translate(-(a[2] ?? 0), -(a[3] ?? 0));
        });
        continue;
      }
      case "clip":
        group(() => {
          g.beginPath();
          g.rect(a[0], a[1], a[2], a[3]);
          g.clip();
        });
        continue;
      case "layer":
        group(() => (g.globalAlpha *= Math.max(0, Math.min(1, a[0] ?? 1))));
        continue;
    }
    const stroke = brush(g, n.stroke);
    const fill = brush(g, n.fill) ?? (stroke ? null : brush(g, n.color) ?? fg);
    g.lineWidth = num(n.width, 1);
    g.lineCap = (({ round: "round", square: "square" } as Record<string, CanvasLineCap>)[n.cap] ?? "butt");
    const paintPath = (withFill = true) => {
      if (fill && withFill) {
        g.fillStyle = fill;
        g.fill();
      }
      if (stroke) {
        g.strokeStyle = stroke;
        g.stroke();
      }
    };
    switch (o.op) {
      case "rect":
        g.beginPath();
        g.roundRect(a[0], a[1], a[2], a[3], num(n.radius, 0));
        paintPath();
        break;
      case "circle":
        g.beginPath();
        g.arc(a[0], a[1], Math.max(0, a[2]), 0, Math.PI * 2);
        paintPath();
        break;
      case "arc": {
        const s = ((a[3] - 90) * Math.PI) / 180;
        const e = ((a[3] + a[4] - 90) * Math.PI) / 180;
        g.beginPath();
        if (fill) g.moveTo(a[0], a[1]);
        g.arc(a[0], a[1], Math.max(0, a[2]), s, e, a[4] < 0);
        if (fill) g.closePath();
        paintPath();
        break;
      }
      case "line":
        g.beginPath();
        g.moveTo(a[0], a[1]);
        g.lineTo(a[2], a[3]);
        g.strokeStyle = (stroke ?? fill)!;
        g.stroke();
        break;
      case "path": {
        const pts = (Array.isArray(a[0]) ? a[0] : []).map((pt: any) => (Array.isArray(pt) ? pt : [pt?.x, pt?.y])).filter((pt: any[]) => typeof pt[0] === "number");
        if (pts.length < 2) break;
        g.beginPath();
        pts.forEach(([x, y]: number[], i: number) => (i ? g.lineTo(x, y) : g.moveTo(x, y)));
        if (n.closed) g.closePath();
        // An unclosed path is a line: only filled when asked to.
        paintPath(n.fill != null);
        break;
      }
      case "text":
        g.fillStyle = typeof (n.color ?? n.fill) === "string" ? canvasText((n.color ?? n.fill) as string, fg) : (brush(g, n.color) ?? brush(g, n.fill) ?? fg);
        g.font = `${n.bold ? "bold " : ""}${num(n.size, 13)}px ui-monospace, monospace`;
        g.textAlign = (({ center: "center", end: "end" } as Record<string, CanvasTextAlign>)[n.align] ?? "start");
        g.textBaseline = "middle";
        g.fillText(text(a[0]), a[1], a[2]);
        break;
      case "image": {
        const img = ctx.image(text(a[0]));
        if (img.complete && img.naturalWidth) g.drawImage(img, a[1], a[2], a[3], a[4]);
        break;
      }
      case "sprite":
        sprite(g, a, n, fill);
        break;
    }
  }
}

/** Pixel art: rows of letters, a palette of colors; each letter a px-sized square. */
function sprite(g: CanvasRenderingContext2D, a: any[], n: Props, fill: Paint) {
  const rows: string[] = Array.isArray(a[0]) ? a[0] : typeof a[0] === "string" ? a[0].split("\n") : [];
  const [x, y, size] = [a[1] ?? 0, a[2] ?? 0, a[3] ?? 1];
  const palette = n.palette && typeof n.palette === "object" ? (n.palette as Record<string, unknown>) : null;
  rows.forEach((row, r) => {
    [...String(row)].forEach((ch, c) => {
      if (ch === " " || ch === ".") return;
      const color = palette ? palette[ch] : fill;
      if (!color || typeof color !== "string") return;
      g.fillStyle = color;
      g.fillRect(x + c * size, y + r * size, size, size);
    });
  });
}

/**
 * A widget as the host runs it: watched while mounted (its tree arrives on "widget.tree"), its tile's size reported.
 * [cells]: the tile's size in grid cells, for the widget's cols and rows.
 */
export function OwlWidget({ widget, cells, screen = false }: { widget: string; cells?: Cell | null; screen?: boolean }) {
  const t = tree(screen ? `${widget}#screen` : widget).value;
  const el = useRef<HTMLDivElement>(null);
  const images = useRef(new Map<string, HTMLImageElement>());
  useEffect(() => {
    powos.widgets.watch(widget, screen);
    return () => void powos.widgets.unwatch(widget, screen);
  }, [widget, screen]);
  useLayoutEffect(() => {
    // The tile's size (its cells and dp): a screen drawn full size isn't the tile.
    if (screen) return;
    const ro = new ResizeObserver(() => {
      const r = el.current!.getBoundingClientRect();
      powos.widgets.size(widget, cells?.w ?? 0, cells?.h ?? 0, r.width, r.height);
    });
    ro.observe(el.current!);
    return () => ro.disconnect();
  }, [widget, screen, cells?.w, cells?.h]);
  const ctx: Ctx = {
    key: widget,
    screen,
    fire: (id, name, args) => void powos.widgets.fire(widget, screen, id, name, args),
    canvas: (id, w, h) => void powos.widgets.canvas(widget, id, w, h),
    image: (src) => {
      if (!images.current.has(src)) {
        const img = new Image();
        img.src = `/_wimg/${encodeURIComponent(widget)}/${encodeURIComponent(src)}`;
        images.current.set(src, img);
      }
      return images.current.get(src)!;
    },
  };
  return (
    <div ref={el} class="owl" style={{ padding: t ? px(Math.max(0, num(t.padding, 0))) : undefined, background: t?.background ?? undefined }}>
      {t && <Nodes nodes={t.c} ctx={ctx} parent="Column" />}
    </div>
  );
}

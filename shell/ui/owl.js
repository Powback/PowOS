/**
 * OWL widgets in the web shell. The host runs the widget (the same engine the Compose launcher uses) and sends its
 * node tree whenever it changes (ShellWidgets / WidgetTree.kt); this draws it the way Render.kt does - same defaults,
 * gaps, alignments and text sizes - and sends back taps, drags and sizes.
 *
 * A tree node: { k: kind, id, p: props (colors already CSS), h: handler names, c: children, ops: Canvas drawing }.
 * Lengths are dp, which are CSS px.
 */
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { html } from "./html.js";
import { powos } from "../bridge.js";

/** Trees by widget key (and key#screen): signals, so only the widget whose tree changed redraws. */
const trees = new Map();
const tree = (id) => {
  if (!trees.has(id)) trees.set(id, signal(null));
  return trees.get(id);
};
powos.on("widget.tree", ({ key, screen, tree: t }) => (tree(screen ? `${key}#screen` : key).value = t));

const SIZES = { huge: 44, title: 20, small: 11, label: 11 };
const FONTS = { sans: "system-ui, sans-serif", serif: "serif", icon: '"Symbols Nerd Font", "JetBrainsMono Nerd Font", monospace' };
const BOX_ALIGN = {
  center: ["center", "center"],
  top: ["center", "start"],
  bottom: ["center", "end"],
  start: ["start", "center"],
  end: ["end", "center"],
  topEnd: ["end", "start"],
  bottomStart: ["start", "end"],
  bottomEnd: ["end", "end"],
};
const JUSTIFY = { center: "center", end: "flex-end", spaceBetween: "space-between", spaceAround: "space-around", spaceEvenly: "space-evenly" };

const num = (v, d) => (typeof v === "number" && isFinite(v) ? v : d);
const px = (v) => `${Math.min(num(v, 0), 4000)}px`;
const text = (v) => (v == null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));

function padding(v) {
  if (typeof v === "number") return px(Math.max(0, v));
  if (Array.isArray(v) && v.length === 2) return `${px(v[1])} ${px(v[0])}`;
  if (Array.isArray(v) && v.length === 4) return `${px(v[1])} ${px(v[2])} ${px(v[3])} ${px(v[0])}`;
  return undefined;
}

/** What every node takes (Render.kt common()): sizing, weight, offset, opacity/rotation/scale, clip, frame, padding. */
function common(p, parentKind) {
  const s = {};
  const w = num(p.weight, 0);
  if (w > 0 && (parentKind === "Row" || parentKind === "Column")) {
    s.flex = `${w} 1 0`;
    s.minWidth = 0;
    s.minHeight = 0;
  }
  if (p.fill === "height") s.height = "100%";
  else if (typeof p.fill === "string") s.width = "100%";
  else if (p.fill) Object.assign(s, { width: "100%", height: "100%" });
  if (p.size != null) s.width = s.height = px(p.size);
  if (p.width != null) s.width = px(p.width);
  if (p.height != null) s.height = px(p.height);
  const t = [];
  if (Array.isArray(p.offset)) t.push(`translate(${px(p.offset[0])}, ${px(p.offset[1])})`);
  if (p.rotation != null) t.push(`rotate(${num(p.rotation, 0)}deg)`);
  if (p.scale != null) t.push(`scale(${num(p.scale, 1)})`);
  if (t.length) s.transform = t.join(" ");
  if (p.opacity != null) s.opacity = Math.max(0, Math.min(1, num(p.opacity, 1)));
  const radius = num(p.radius, p.border != null ? 8 : 0);
  if (p.clip) s.overflow = "hidden";
  if (radius) s.borderRadius = px(radius);
  if (p.background) s.background = p.background;
  if (num(p.border, 0) > 0) s.border = `${px(p.border)} solid ${p.borderColor ?? "var(--color-border)"}`;
  const pad = padding(p.padding);
  if (pad) s.padding = pad;
  return s;
}

/** onTap and onDrag, with their coordinates in dp (the element's own). */
function handlers(node, fire) {
  if (!node.h?.length) return {};
  const tap = node.h.includes("onTap");
  const drag = node.h.includes("onDrag");
  let from = null;
  let last = null;
  return {
    onPointerDown: (e) => {
      e.stopPropagation();
      from = last = { x: e.clientX, y: e.clientY };
      if (drag) e.currentTarget.setPointerCapture(e.pointerId);
    },
    onPointerMove: (e) => {
      if (!drag || !last || !e.buttons) return;
      const r = e.currentTarget.getBoundingClientRect();
      fire(node.id, "onDrag", [e.clientX - last.x, e.clientY - last.y, e.clientX - r.left, e.clientY - r.top]);
      last = { x: e.clientX, y: e.clientY };
    },
    onPointerUp: (e) => {
      e.stopPropagation();
      if (tap && from && Math.hypot(e.clientX - from.x, e.clientY - from.y) < 10) {
        const r = e.currentTarget.getBoundingClientRect();
        fire(node.id, "onTap", [e.clientX - r.left, e.clientY - r.top]);
      }
      from = last = null;
    },
  };
}

function Nodes({ nodes, ctx, parent }) {
  return nodes?.map((n) => html`<${Node} key=${n.id} node=${n} ctx=${ctx} parent=${parent} />`);
}

function Node({ node, ctx, parent }) {
  const p = node.p ?? {};
  const style = common(p, parent);
  const on = handlers(node, ctx.fire);
  const sized = ["width", "height", "size", "fill", "weight"].some((k) => p[k] != null);
  switch (node.k) {
    case "Column": {
      const align = { center: "center", end: "flex-end" }[p.align] ?? "flex-start";
      const justify = JUSTIFY[p.justify];
      return html`<div ...${on} style=${{ display: "flex", flexDirection: "column", gap: px(num(p.gap, 4)), alignItems: align, justifyContent: justify, overflowY: p.scroll ? "auto" : undefined, minHeight: 0, ...style }}>
        <${Nodes} nodes=${node.c} ctx=${ctx} parent="Column" />
      </div>`;
    }
    case "Row":
    case "Flow": {
      const align = { top: "flex-start", start: "flex-start", bottom: "flex-end", end: "flex-end" }[p.align] ?? "center";
      return html`<div ...${on} style=${{ display: "flex", flexDirection: "row", flexWrap: node.k === "Flow" || p.wrap ? "wrap" : "nowrap", gap: px(num(p.gap, 8)), alignItems: align, justifyContent: JUSTIFY[p.justify], minWidth: 0, ...style }}>
        <${Nodes} nodes=${node.c} ctx=${ctx} parent="Row" />
      </div>`;
    }
    case "Box": {
      const [x, y] = BOX_ALIGN[p.align] ?? ["start", "start"];
      return html`<div ...${on} style=${{ display: "grid", justifyItems: x, alignItems: y, ...style }} class="owl-box">
        <${Nodes} nodes=${node.c} ctx=${ctx} parent="Box" />
      </div>`;
    }
    case "Grid":
      return html`<div ...${on} style=${{ display: "grid", gridTemplateColumns: `repeat(${Math.max(1, Math.min(12, num(p.columns, 2)))}, minmax(0, 1fr))`, gap: px(num(p.gap, 6)), ...style }}>
        <${Nodes} nodes=${node.c} ctx=${ctx} parent="Grid" />
      </div>`;
    case "Text": {
      const lines = num(p.maxLines, p.style === "huge" || p.style === "title" ? 1 : 0);
      const muted = p.style === "muted" || p.style === "label";
      return html`<div
        ...${on}
        style=${{
          width: p.width == null && p.weight == null && p.fill == null ? "100%" : undefined,
          color: p.color ?? (muted ? "var(--color-muted)" : "var(--color-foreground)"),
          font: `${p.italic ? "italic " : ""}${p.bold ? "bold " : ""}${num(p.fontSize, SIZES[p.style] ?? 13)}px ${FONTS[p.font] ?? "var(--font)"}`,
          textAlign: { center: "center", end: "end" }[p.align] ?? "start",
          whiteSpace: lines === 1 ? "nowrap" : "pre-wrap",
          overflow: "hidden",
          textOverflow: "ellipsis",
          ...(lines > 1 ? { display: "-webkit-box", WebkitLineClamp: lines, WebkitBoxOrient: "vertical" } : {}),
          ...style,
        }}
      >${text(p.text)}</div>`;
    }
    case "Button":
      return html`<div
        ...${on}
        style=${{ border: `1px solid ${p.color ?? "var(--color-accent)"}`, borderRadius: px(num(p.radius, 8)), padding: "6px 10px", color: p.color ?? "var(--color-accent)", font: "13px var(--font)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", textAlign: "center", ...style }}
      >${text(p.text)}</div>`;
    case "Progress": {
      const f = Math.max(0, Math.min(1, num(p.value, 0) / Math.max(num(p.max, 100), 1e-6)));
      return html`<div ...${on} style=${{ background: p.track ?? "var(--color-surface)", ...(sized ? {} : { width: "100%", height: "8px" }), ...style }}>
        <div style=${{ width: `${f * 100}%`, height: "100%", background: p.color ?? "var(--color-accent)" }}></div>
      </div>`;
    }
    case "Ring":
      return html`<${Ring} p=${p} on=${on} style=${{ ...(sized ? {} : { width: "64px", height: "64px" }), ...style }} />`;
    case "Sparkline":
      return html`<${Sparkline} p=${p} on=${on} style=${{ ...(sized ? {} : { width: "100%", height: "48px" }), ...style }} />`;
    case "Image": {
      const src = text(p.src);
      if (!src) return null;
      const url = `/_wimg/${encodeURIComponent(ctx.key)}/${encodeURIComponent(src)}`;
      return html`<img ...${on} src=${url} alt="" draggable="false" style=${{ objectFit: { cover: "cover", fill: "fill" }[p.fit] ?? "contain", display: "block", ...style }} />`;
    }
    case "Canvas":
      return html`<${Canvas} node=${node} ctx=${ctx} on=${on} style=${{ ...(sized ? {} : { width: "100%", height: "100%" }), ...style }} />`;
    case "Shader":
      // AGSL shaders: WebGL later; their fallback color meanwhile, as Android before 13 shows.
      return html`<div ...${on} style=${{ background: p.fallback ?? "var(--color-surface)", ...(sized ? {} : { width: "100%", height: "100%" }), ...style }}></div>`;
    case "Spacer":
      return html`<div ...${on} style=${style}></div>`;
    case "Slider":
      return html`<input
        type="range"
        min=${num(p.min, 0)}
        max=${num(p.max, 1)}
        step=${num(p.step, 0) || "any"}
        value=${num(p.value, 0)}
        style=${{ accentColor: p.color ?? "var(--color-accent)", ...(sized ? {} : { width: "100%" }), ...style }}
        onPointerDown=${(e) => e.stopPropagation()}
        onInput=${(e) => node.h?.includes("onChange") && ctx.fire(node.id, "onChange", [Number(e.currentTarget.value)])}
      />`;
    case "Input":
      return html`<div class="muted" style=${{ font: "13px var(--font)", ...style }}>${text(p.placeholder ?? p.text)}</div>`;
    case "Terminal":
      // Phase 5: xterm.js over the pty bridge.
      return html`<div ...${on} class="owl-terminal" style=${{ ...(sized ? {} : { width: "100%", height: "100%" }), ...style }}>terminal</div>`;
    default:
      return html`<div style=${style}><${Nodes} nodes=${node.c} ctx=${ctx} parent="Box" /></div>`;
  }
}

function arc(cx, cy, r, from, sweep) {
  const rad = (d) => ((d - 90) * Math.PI) / 180;
  const a0 = rad(from);
  const a1 = rad(from + Math.min(sweep, 359.99));
  const large = sweep > 180 ? 1 : 0;
  return `M ${cx + r * Math.cos(a0)} ${cy + r * Math.sin(a0)} A ${r} ${r} 0 ${large} 1 ${cx + r * Math.cos(a1)} ${cy + r * Math.sin(a1)}`;
}

/** Ring: 0 degrees is 12 o'clock, clockwise; a track, then the value's share of the sweep. */
function Ring({ p, on, style }) {
  const t = num(p.thickness, 6);
  const start = num(p.start, 0);
  const sweep = num(p.sweep, 360);
  const f = Math.max(0, Math.min(1, num(p.value, 0) / Math.max(num(p.max, 1), 1e-6)));
  const r = 50 - t / 2;
  return html`<svg ...${on} viewBox="0 0 100 100" style=${style}>
    <path d=${arc(50, 50, r, start, sweep)} fill="none" stroke=${p.track ?? "var(--color-surface)"} stroke-width=${t} stroke-linecap="round" />
    ${f > 0 && html`<path d=${arc(50, 50, r, start, sweep * f)} fill="none" stroke=${p.color ?? "var(--color-accent)"} stroke-width=${t} stroke-linecap="round" />`}
  </svg>`;
}

function Sparkline({ p, on, style }) {
  const values = (Array.isArray(p.values) ? p.values : []).filter((v) => typeof v === "number");
  if (values.length < 2) return html`<div ...${on} style=${style}></div>`;
  const lo = num(p.min, 0);
  const hi = num(p.max, Math.max(lo + 1, lo + (Math.max(...values) - lo) * 1.15));
  const pts = values.map((v, i) => [(i / (values.length - 1)) * 100, 100 * (1 - Math.max(0, Math.min(1, (v - lo) / (hi - lo))))]);
  const line = pts.map(([x, y], i) => `${i ? "L" : "M"} ${x} ${y}`).join(" ");
  const area = typeof p.area === "string" ? p.area : p.area ? "color-mix(in srgb, currentColor 20%, transparent)" : null;
  return html`<svg ...${on} viewBox="0 0 100 100" preserveAspectRatio="none" style=${{ color: p.color ?? "var(--color-accent)", ...style }}>
    ${area && html`<path d=${`${line} L 100 100 L 0 100 Z`} fill=${area} stroke="none" />`}
    <path d=${line} fill="none" stroke="currentColor" stroke-width=${num(p.thickness, 2)} stroke-linecap="round" vector-effect="non-scaling-stroke" />
  </svg>`;
}

/** A Canvas: the host evaluates its drawing at the size this reports; this replays the ops on a 2D canvas. */
function Canvas({ node, ctx, on, style }) {
  const el = useRef(null);
  useLayoutEffect(() => {
    const c = el.current;
    const ro = new ResizeObserver(() => {
      const r = c.getBoundingClientRect();
      ctx.canvas(node.id, r.width, r.height);
      paint(c, node.ops, ctx);
    });
    ro.observe(c);
    return () => ro.disconnect();
  }, [node.id]);
  useEffect(() => paint(el.current, node.ops, ctx), [node.ops]);
  return html`<canvas ...${on} ref=${el} style=${{ display: "block", ...style }}></canvas>`;
}

function paint(c, ops, ctx) {
  if (!c) return;
  const r = c.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  if (c.width !== Math.round(r.width * dpr) || c.height !== Math.round(r.height * dpr)) {
    c.width = Math.round(r.width * dpr);
    c.height = Math.round(r.height * dpr);
  }
  const g = c.getContext("2d");
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, r.width, r.height);
  draw(g, ops ?? [], ctx);
}

function brush(g, v) {
  if (!v) return null;
  if (typeof v === "string") return v;
  if (v.gradient) {
    const c = v.coords;
    const gr = v.gradient === "radial" ? g.createRadialGradient(c[0], c[1], 0, c[0], c[1], Math.max(c[2], 0.01)) : g.createLinearGradient(c[0], c[1], c[2], c[3]);
    v.colors.forEach((col, i) => gr.addColorStop(v.colors.length > 1 ? i / (v.colors.length - 1) : 0, col ?? "transparent"));
    return gr;
  }
  return null;
}

/** Canvas.kt's ops on a 2D context: same coordinates (dp), same defaults (fill with the foreground). */
function draw(g, ops, ctx) {
  const fg = getComputedStyle(document.documentElement).getPropertyValue("--color-foreground").trim() || "#ddd";
  for (const o of ops) {
    const a = o.a;
    const n = o.n ?? {};
    const nested = () => draw(g, o.c ?? [], ctx);
    switch (o.op) {
      case "translate":
        g.save(); g.translate(a[0], a[1]); nested(); g.restore(); continue;
      case "rotate":
        g.save(); g.translate(a[1] ?? 0, a[2] ?? 0); g.rotate(((a[0] ?? 0) * Math.PI) / 180); g.translate(-(a[1] ?? 0), -(a[2] ?? 0)); nested(); g.restore(); continue;
      case "scale": {
        const sx = a[0] ?? 1;
        const sy = a.length > 1 ? a[1] : sx;
        g.save(); g.translate(a[2] ?? 0, a[3] ?? 0); g.scale(sx, sy); g.translate(-(a[2] ?? 0), -(a[3] ?? 0)); nested(); g.restore(); continue;
      }
      case "clip":
        g.save(); g.beginPath(); g.rect(a[0], a[1], a[2], a[3]); g.clip(); nested(); g.restore(); continue;
      case "layer":
        g.save(); g.globalAlpha *= Math.max(0, Math.min(1, a[0] ?? 1)); nested(); g.restore(); continue;
    }
    const stroke = brush(g, n.stroke);
    const fill = brush(g, n.fill) ?? (stroke ? null : brush(g, n.color) ?? fg);
    g.lineWidth = num(n.width, 1);
    g.lineCap = { round: "round", square: "square" }[n.cap] ?? "butt";
    const paintPath = (closedFill = true) => {
      if (fill && closedFill) { g.fillStyle = fill; g.fill(); }
      if (stroke) { g.strokeStyle = stroke; g.stroke(); }
    };
    switch (o.op) {
      case "rect":
        g.beginPath();
        g.roundRect ? g.roundRect(a[0], a[1], a[2], a[3], num(n.radius, 0)) : g.rect(a[0], a[1], a[2], a[3]);
        paintPath();
        break;
      case "circle":
        g.beginPath(); g.arc(a[0], a[1], Math.max(0, a[2]), 0, Math.PI * 2); paintPath();
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
        g.beginPath(); g.moveTo(a[0], a[1]); g.lineTo(a[2], a[3]); g.strokeStyle = stroke ?? fill; g.stroke();
        break;
      case "path": {
        const pts = (Array.isArray(a[0]) ? a[0] : []).map((pt) => (Array.isArray(pt) ? pt : [pt?.x, pt?.y])).filter((pt) => typeof pt[0] === "number");
        if (pts.length < 2) break;
        g.beginPath();
        pts.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y)));
        if (n.closed) g.closePath();
        // An unclosed path is a line: only filled when asked to.
        paintPath(n.fill != null);
        break;
      }
      case "text": {
        g.fillStyle = brush(g, n.color) ?? brush(g, n.fill) ?? fg;
        g.font = `${n.bold ? "bold " : ""}${num(n.size, 13)}px ui-monospace, monospace`;
        g.textAlign = { center: "center", end: "end" }[n.align] ?? "start";
        g.textBaseline = "middle";
        g.fillText(text(a[0]), a[1], a[2]);
        break;
      }
      case "image": {
        const img = ctx.image(text(a[0]));
        if (img.complete && img.naturalWidth) g.drawImage(img, a[1], a[2], a[3], a[4]);
        break;
      }
      case "sprite":
        // Pixel art: rows of letters, a palette of colors; each letter a px-sized square.
        sprite(g, a, n, fill);
        break;
    }
  }
}

function sprite(g, a, n, fill) {
  const rows = Array.isArray(a[0]) ? a[0] : typeof a[0] === "string" ? a[0].split("\n") : [];
  const [x, y, size] = [a[1] ?? 0, a[2] ?? 0, a[3] ?? 1];
  const palette = n.palette && typeof n.palette === "object" ? n.palette : null;
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
export function OwlWidget({ widget, cells, screen = false }) {
  const t = tree(screen ? `${widget}#screen` : widget).value;
  const el = useRef(null);
  const images = useRef(new Map());
  useEffect(() => {
    powos.widgets.watch(widget, screen);
    return () => powos.widgets.unwatch(widget, screen);
  }, [widget, screen]);
  useLayoutEffect(() => {
    const ro = new ResizeObserver(() => {
      const r = el.current.getBoundingClientRect();
      powos.widgets.size(widget, cells?.w ?? 0, cells?.h ?? 0, r.width, r.height);
    });
    ro.observe(el.current);
    return () => ro.disconnect();
  }, [widget, cells?.w, cells?.h]);
  const ctx = {
    key: widget,
    fire: (id, name, args) => powos.widgets.fire(widget, screen, id, name, args),
    canvas: (id, w, h) => powos.widgets.canvas(widget, id, w, h),
    image: (src) => {
      if (!images.current.has(src)) {
        const img = new Image();
        img.src = `/_wimg/${encodeURIComponent(widget)}/${encodeURIComponent(src)}`;
        images.current.set(src, img);
      }
      return images.current.get(src);
    },
  };
  return html`
    <div ref=${el} class="owl" style=${{ padding: t ? px(Math.max(0, num(t.padding, 0))) : undefined, background: t?.background ?? undefined }}>
      ${t ? html`<${Nodes} nodes=${t.c} ctx=${ctx} parent="Column" />` : null}
    </div>
  `;
}

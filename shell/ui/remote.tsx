/**
 * Remote input: the phone as the keyboard and touchpad of a computer (RemoteInput.kt) - over the USB cable it's
 * plugged in with (a real USB keyboard and mouse to the computer: no software there, works in its BIOS) or Bluetooth
 * (paired like any Bluetooth keyboard).
 *
 * - The touchpad: one finger moves the pointer, a tap clicks, two fingers scroll, a two-finger tap right-clicks;
 *   held still, a finger holds the button down (drag).
 * - The extra keys: Esc, Tab, the modifiers (a tap latches one for the next key, a second tap locks it), arrows and
 *   the rest a phone keyboard hasn't, F1-F12, and shortcuts.
 * - The text field: whatever the phone's keyboard does in it is typed on the computer as it happens - letters as they
 *   compose, autocorrect's swaps as Backspace and the new word, the caret moved by the keyboard's cursor control as
 *   arrows (remote.ts diff), on the computer's layout.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { Icon } from "./icons.tsx";
import {
  ALT,
  CTRL,
  KEY,
  LAYOUTS,
  SHIFT,
  SUPER,
  closeRemote,
  diff,
  latched,
  layout,
  press,
  remoteOpen,
  repeat,
  send,
  setLayout,
  shortcutLatched,
  tapModifier,
  typeText,
} from "../remote.ts";
import type { RemoteState, RemoteTarget } from "../types.ts";

/** Its touches are its own: nothing under it (home's swipes) sees them. */
const own = {
  onTouchStart: (e: TouchEvent) => e.stopPropagation(),
  onTouchMove: (e: TouchEvent) => e.stopPropagation(),
  onPointerDown: (e: PointerEvent) => e.stopPropagation(),
};

/** A key that doesn't take the focus: the text field keeps it, and the phone's keyboard stays up. */
const keep = {
  onMouseDown: (e: MouseEvent) => e.preventDefault(),
  onPointerDown: (e: PointerEvent) => {
    e.preventDefault();
    e.stopPropagation();
  },
};

export function RemoteScreen() {
  return remoteOpen.value ? <Remote /> : null;
}

function Remote() {
  const [st, setSt] = useState<RemoteState | null>(null);
  useEffect(() => {
    let live = true;
    const get = () => powos.remote.state().then((s) => live && setSt(s)).catch(() => {});
    get();
    const off = powos.on("remote.state", (s: RemoteState) => live && setSt(s));
    // The cable's state (plugged in, unplugged) has no event: asked while the screen shows.
    const timer = window.setInterval(() => document.hidden || get(), 2000);
    return () => {
      live = false;
      off();
      clearInterval(timer);
    };
  }, []);
  return (
    <div class="remote-screen" {...own}>
      <header class="remote-top">
        <button type="button" class="session-back" onClick={closeRemote}>
          ‹
        </button>
        <span class="ai-title">Remote input</span>
        <Target st={st} side="usb" />
        <Target st={st} side="bluetooth" />
      </header>
      {st && <Status st={st} />}
      <Touchpad />
      <ExtraKeys />
      <TypeField />
    </div>
  );
}

/** A side's chip: picks it; its dot says whether a computer has it. */
function Target({ st, side }: { st: RemoteState | null; side: RemoteTarget }) {
  const picked = st?.target === side;
  const linked = side === "usb" ? st?.usb.state === "configured" : !!st?.bluetooth.host;
  const on = side === "usb" ? st?.usb.on : st?.bluetooth.registered;
  return (
    <button
      type="button"
      class={`remote-target ${picked ? "picked" : ""}`}
      onClick={() => powos.remote.target(picked ? null : side).then(() => {}, () => {})}
    >
      <Icon name={side === "usb" ? "usb" : "bluetooth"} size={18} />
      <span>{side === "usb" ? "USB" : "BT"}</span>
      <span class={`remote-dot ${linked ? "linked" : on ? "on" : ""}`} />
    </button>
  );
}

/** What the picked side is doing, and what can be done about it. */
function Status({ st }: { st: RemoteState }) {
  if (!st.target) {
    return (
      <div class="remote-status tile muted">
        Pick where the keys go: <b>USB</b> - the cable to the computer (a real keyboard and mouse to it, in its BIOS
        too) - or <b>BT</b>, paired over Bluetooth.
      </div>
    );
  }
  if (st.target === "usb") {
    const u = st.usb;
    const text = u.error
      ? `USB keyboard failed: ${u.error}`
      : u.busy
        ? "Setting up the USB keyboard…"
        : !u.on
          ? "USB keyboard is off"
          : u.state === "configured"
            ? "Connected: the computer has a keyboard and a mouse"
            : u.state === "not attached"
              ? "Plug the phone into the computer with a USB cable"
              : u.state === "suspended"
                ? "The computer is asleep - a key wakes it"
                : `USB: ${u.state}`;
    return (
      <div class={`remote-status tile ${u.error ? "error" : ""}`}>
        <span class="remote-status-text">{text}</span>
        {u.on && (
          <button type="button" class="remote-action" onClick={() => powos.remote.off("usb")}>
            turn off
          </button>
        )}
      </div>
    );
  }
  const b = st.bluetooth;
  if (!b.available) return <div class="remote-status tile error">This phone has no Bluetooth</div>;
  if (!b.enabled) {
    return (
      <div class="remote-status tile">
        <span class="remote-status-text">Bluetooth is off</span>
        <button type="button" class="remote-action" onClick={() => powos.remote.target("bluetooth")}>
          turn on
        </button>
      </div>
    );
  }
  return (
    <div class={`remote-status tile ${b.error ? "error" : ""}`}>
      <span class="remote-status-text">
        {b.error
          ? b.error
          : b.host
            ? `Connected to ${b.host.name}`
            : !b.registered
              ? "Starting the Bluetooth keyboard…"
              : b.connecting
                ? `Connecting to ${b.hosts.find((h) => h.address === b.connecting)?.name ?? b.connecting}…`
                : b.discoverable
                  ? `Visible: on the computer, add a Bluetooth device - ${b.name ?? "this phone"}`
                  : b.hosts.length
                    ? "Pick the computer"
                    : "Pair a computer first"}
      </span>
      <span class="remote-hosts">
        {!b.host &&
          b.hosts.map((h) => (
            <button type="button" key={h.address} class="remote-chip" onClick={() => powos.remote.connect(h.address)}>
              <Icon name="monitor" size={14} /> {h.name}
            </button>
          ))}
        {b.host ? (
          <button type="button" class="remote-action" onClick={() => powos.remote.disconnect()}>
            disconnect
          </button>
        ) : (
          <button type="button" class="remote-action" onClick={() => powos.remote.discoverable()}>
            pair new
          </button>
        )}
        <button type="button" class="remote-action" onClick={() => powos.remote.off("bluetooth")}>
          off
        </button>
      </span>
    </div>
  );
}

/** Pointer speed: report counts per CSS px, and how much faster a quick swipe goes. */
const GAIN = 1.4;
const ACCEL = 1.6;
/** CSS px of two-finger travel per wheel step. */
const SCROLL_STEP = 22;
/** A tap: shorter than this (ms), moving less than this (px). */
const TAP_MS = 240;
const TAP_SLOP = 9;
/** Held this long without moving: the button goes down, for a drag. */
const HOLD_MS = 450;

function Touchpad() {
  const pad = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = pad.current!;
    const points = new Map<number, { x: number; y: number; t: number }>();
    // This gesture: when it began, how many fingers it had at most, how far it went, the button it holds.
    let start = 0;
    let fingers = 0;
    let travel = 0;
    let held = 0;
    let hold = 0;
    // Motion and scroll not sent yet (fractions carried), sent once a frame.
    let dx = 0;
    let dy = 0;
    let sx = 0;
    let sy = 0;
    let frame = 0;
    const flush = () => {
      frame = 0;
      const mx = Math.trunc(dx);
      const my = Math.trunc(dy);
      const wheel = Math.trunc(sy / SCROLL_STEP);
      const pan = Math.trunc(-sx / SCROLL_STEP);
      dx -= mx;
      dy -= my;
      sy -= wheel * SCROLL_STEP;
      sx += pan * SCROLL_STEP;
      if (mx || my || wheel || pan) powos.remote.mouse(held, mx, my, wheel, pan).catch(() => {});
    };
    const queue = () => (frame ||= requestAnimationFrame(flush));
    const click = (button: number) => {
      powos.remote.mouse(button, 0, 0).catch(() => {});
      powos.remote.mouse(0, 0, 0).catch(() => {});
    };
    const down = (e: PointerEvent) => {
      el.setPointerCapture(e.pointerId);
      if (!points.size) {
        start = e.timeStamp;
        fingers = 0;
        travel = 0;
        clearTimeout(hold);
        hold = window.setTimeout(() => {
          if (points.size === 1 && travel < TAP_SLOP) {
            held = 1;
            powos.remote.mouse(1, 0, 0).catch(() => {});
            navigator.vibrate?.(12);
          }
        }, HOLD_MS);
      }
      points.set(e.pointerId, { x: e.clientX, y: e.clientY, t: e.timeStamp });
      fingers = Math.max(fingers, points.size);
    };
    const move = (e: PointerEvent) => {
      const p = points.get(e.pointerId);
      if (!p) return;
      const mx = e.clientX - p.x;
      const my = e.clientY - p.y;
      const dt = Math.max(1, e.timeStamp - p.t);
      points.set(e.pointerId, { x: e.clientX, y: e.clientY, t: e.timeStamp });
      travel += Math.hypot(mx, my);
      if (points.size === 1 && fingers === 1) {
        const speed = Math.hypot(mx, my) / dt; // px per ms
        const g = GAIN * (1 + ACCEL * Math.min(speed, 2.5));
        dx += mx * g;
        dy += my * g;
      } else if (points.size >= 2) {
        // Two fingers: each moves half the scroll (the content follows the fingers, as on a touchpad).
        sx += mx / points.size;
        sy += my / points.size;
      }
      queue();
    };
    const up = (e: PointerEvent) => {
      if (!points.delete(e.pointerId) || points.size) return;
      clearTimeout(hold);
      const quick = e.timeStamp - start < TAP_MS + (fingers > 1 ? 120 : 0) && travel < TAP_SLOP * fingers;
      if (held) {
        held = 0;
        powos.remote.mouse(0, 0, 0).catch(() => {});
      } else if (quick) click(fingers >= 3 ? 4 : fingers === 2 ? 2 : 1);
    };
    const cancel = (e: PointerEvent) => {
      points.delete(e.pointerId);
      if (!points.size && held) {
        held = 0;
        powos.remote.mouse(0, 0, 0).catch(() => {});
      }
    };
    el.addEventListener("pointerdown", down);
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up);
    el.addEventListener("pointercancel", cancel);
    return () => {
      clearTimeout(hold);
      cancelAnimationFrame(frame);
      el.removeEventListener("pointerdown", down);
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerup", up);
      el.removeEventListener("pointercancel", cancel);
    };
  }, []);
  /** A button under the pad: down while the finger is. */
  const button = (bit: number, label: string) => (
    <button
      type="button"
      class="remote-button"
      {...keep}
      onPointerDown={(e) => {
        keep.onPointerDown(e);
        powos.remote.mouse(bit, 0, 0).catch(() => {});
      }}
      onPointerUp={() => powos.remote.mouse(0, 0, 0).catch(() => {})}
      onPointerCancel={() => powos.remote.mouse(0, 0, 0).catch(() => {})}
    >
      {label}
    </button>
  );
  return (
    <div class="remote-pad-wrap">
      <div ref={pad} class="remote-pad tile">
        <Icon name="trackpad" size={28} class="remote-pad-mark" />
      </div>
      <div class="remote-buttons">
        {button(1, "left")}
        {button(4, "middle")}
        {button(2, "right")}
      </div>
    </div>
  );
}

const MODS: [number, string][] = [
  [CTRL, "Ctrl"],
  [ALT, "Alt"],
  [SUPER, "Super"],
  [SHIFT, "Shift"],
];

/** Keys a phone keyboard hasn't, and shortcuts: [label or icon, reports]. */
const NAV: [string, () => number[][]][] = [
  ["Esc", () => press(KEY.esc)],
  ["Tab", () => press(KEY.tab)],
  ["arrowLeft", () => press(KEY.left)],
  ["arrowUp", () => press(KEY.up)],
  ["arrowDown", () => press(KEY.down)],
  ["arrowRight", () => press(KEY.right)],
  ["Home", () => press(KEY.home)],
  ["End", () => press(KEY.end)],
  ["PgUp", () => press(KEY.pageUp)],
  ["PgDn", () => press(KEY.pageDown)],
  ["Del", () => press(KEY.del)],
  ["backspaceOutline", () => press(KEY.backspace)],
  ["keyboardReturn", () => press(KEY.enter)],
  ["Ins", () => press(KEY.insert)],
  ["PrtSc", () => press(KEY.printScreen)],
];

const SHORTCUTS: [string, number[][]][] = [
  ["Alt-Tab", [[ALT, KEY.tab], [ALT], [0]]],
  ["Super", [[SUPER], [0]]],
  ["Ctrl-C", [[CTRL, 0x06], [0]]],
  ["Ctrl-V", [[CTRL, 0x19], [0]]],
  ["Ctrl-X", [[CTRL, 0x1b], [0]]],
  ["Ctrl-Z", [[CTRL, 0x1d], [0]]],
  ["Ctrl-A", [[CTRL, 0x04], [0]]],
  ["Ctrl-S", [[CTRL, 0x16], [0]]],
  ["Ctrl-L", [[CTRL, 0x0f], [0]]],
  ["Ctrl-W", [[CTRL, 0x1a], [0]]],
  ["Ctrl-T", [[CTRL, 0x17], [0]]],
  ["Ctrl-Alt-Del", [[CTRL | ALT, KEY.del], [0]]],
  ["Ctrl-Alt-T", [[CTRL | ALT, 0x17], [0]]],
];

function ExtraKeys() {
  const [fn, setFn] = useState(false);
  const l = latched.value;
  return (
    <div class="remote-keys">
      <div class="remote-row">
        {MODS.map(([bit, name]) => (
          <button
            type="button"
            key={name}
            class={`remote-key mod ${l.locked & bit ? "locked" : l.mods & bit ? "latched" : ""}`}
            {...keep}
            onClick={() => tapModifier(bit)}
          >
            {name}
          </button>
        ))}
        <button type="button" class={`remote-key ${fn ? "latched" : ""}`} {...keep} onClick={() => setFn(!fn)}>
          Fn
        </button>
        {fn
          ? Array.from({ length: 12 }, (_, i) => (
              <button type="button" key={i} class="remote-key" {...keep} onClick={() => send(press(KEY.f1 + i))}>
                F{i + 1}
              </button>
            ))
          : NAV.map(([name, reports]) => (
              <button type="button" key={name} class="remote-key" {...keep} onClick={() => send(reports())}>
                {name in ICON_KEYS ? <Icon name={ICON_KEYS[name]} size={16} /> : name}
              </button>
            ))}
      </div>
      <div class="remote-row">
        {SHORTCUTS.map(([name, reports]) => (
          <button type="button" key={name} class="remote-key chip" {...keep} onClick={() => send(reports)}>
            {name}
          </button>
        ))}
      </div>
    </div>
  );
}

const ICON_KEYS: Record<string, "arrowLeft" | "arrowUp" | "arrowDown" | "arrowRight" | "backspaceOutline" | "keyboardReturn"> = {
  arrowLeft: "arrowLeft",
  arrowUp: "arrowUp",
  arrowDown: "arrowDown",
  arrowRight: "arrowRight",
  backspaceOutline: "backspaceOutline",
  keyboardReturn: "keyboardReturn",
};

/**
 * The text field: its text is what the computer was sent (since it was last cleared), its caret where the computer's
 * is - each change goes as the keys that make it (remote.ts diff). Cleared after Enter, so it never grows long.
 */
function TypeField() {
  const field = useRef<HTMLTextAreaElement>(null);
  const mirror = useRef({ text: "", caret: 0 });
  const [missing, setMissing] = useState(0);
  const sync = () => {
    const el = field.current!;
    const m = mirror.current;
    const v = el.value;
    if (v !== m.text) {
      // Ctrl/Alt/Super latched: what was typed is a shortcut, not text - sent, and taken back out of the field.
      if (shortcutLatched() && v.length > m.text.length && v.startsWith(m.text.slice(0, m.caret))) {
        const added = v.slice(m.caret, m.caret + v.length - m.text.length);
        send(typeText(added).reports);
        el.value = m.text;
        el.setSelectionRange(m.caret, m.caret);
        return;
      }
      const d = diff(m.text, v, m.caret);
      send(d.reports);
      if (d.missing) {
        setMissing(d.missing);
        window.setTimeout(() => setMissing(0), 2500);
      }
      m.text = v;
      m.caret = d.caret;
      // Enter: the line is done - a new one starts empty (the computer's caret is on its new line anyway).
      if (v.endsWith("\n") && el.selectionEnd === v.length) {
        window.setTimeout(() => {
          if (el.value !== v) return;
          el.value = "";
          mirror.current = { text: "", caret: 0 };
        }, 0);
        return;
      }
    }
    // The caret moved (the keyboard's cursor control, a tap in the text): the computer's goes with it.
    if (el.selectionStart === el.selectionEnd && el.selectionEnd !== m.caret) {
      const to = el.selectionEnd;
      send(to > m.caret ? repeat(KEY.right, to - m.caret) : repeat(KEY.left, m.caret - to));
      m.caret = to;
    }
  };
  useEffect(() => {
    const onSelection = () => document.activeElement === field.current && sync();
    document.addEventListener("selectionchange", onSelection);
    return () => document.removeEventListener("selectionchange", onSelection);
  }, []);
  return (
    <div class="remote-type tile">
      <button
        type="button"
        class="remote-kbd"
        {...keep}
        onClick={() => {
          const el = field.current!;
          if (document.activeElement === el) {
            el.blur();
            powos.keyboard.hide();
          } else {
            el.focus();
            powos.keyboard.show();
          }
        }}
      >
        <Icon name="keyboardOutline" size={22} />
      </button>
      <textarea
        ref={field}
        rows={1}
        class="remote-field"
        placeholder={missing ? `${missing} character${missing > 1 ? "s" : ""} not on this layout` : "type here - it types there"}
        autocapitalize="none"
        spellcheck={false}
        onInput={sync}
        onKeyDown={(e) => {
          const el = e.currentTarget;
          // Nothing before the caret to delete: no input comes, but the computer may have more - the key goes.
          if ((e.key === "Backspace" || e.keyCode === 8) && el.selectionStart === 0 && el.selectionEnd === 0) send(press(KEY.backspace));
        }}
        onFocus={() => powos.keyboard.show()}
      />
      <select class="remote-layout" value={layout.value} onChange={(e) => setLayout((e.currentTarget as HTMLSelectElement).value)}>
        {Object.entries(LAYOUTS).map(([k, v]) => (
          <option key={k} value={k}>
            {v.name}
          </option>
        ))}
      </select>
    </div>
  );
}

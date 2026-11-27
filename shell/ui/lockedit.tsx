/**
 * The lock face's edit (iOS's "customize"): the clock's font, weight and colour (theme tokens), the lock's own backdrop
 * (apart from home's), which glance items show (alarm, event, weather, now playing) and the two corner shortcuts (torch,
 * camera, focus, recorder, any app). Every pick is on the face at once and kept after (lockstyle.ts setLockFace:
 * optimistic, rolled back if the store refuses it).
 *
 * Two ways in, one editor: a long press on the face once the phone is unlocked with the face still up (a biometric, a
 * trusted device: lock.locked false; locked, the face says how - lock.tsx), and Settings > lock screen (screens.tsx).
 */
import { useEffect, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { App } from "../types.ts";
import {
  BUILTIN_CORNERS,
  CLOCK_COLORS,
  FONTS,
  GLANCE_ITEMS,
  WALLS,
  WEIGHTS,
  lockFace,
  setLockFace,
  type LockCorner,
  type LockFaceStyle,
} from "./lockstyle.ts";

const WALL_LABEL: Record<string, string> = { tint: "wallpaper", dim: "darker", plain: "theme", black: "black" };
const GLANCE_LABEL: Record<string, string> = { alarm: "alarm", event: "next event", weather: "weather", media: "now playing" };

/** One chip: filled when picked. */
function Chip({ on, label, onPick, swatch, k }: { on: boolean; label: string; onPick: () => void; swatch?: string; k: string }) {
  return (
    <button type="button" class={`lock-edit-chip${on ? " on" : ""}`} data-pick={k} aria-pressed={on} onClick={onPick}>
      {swatch && <i class="lock-edit-swatch" style={{ "--swatch": swatch }} />}
      {label}
    </button>
  );
}

function Row({ label, children }: { label: string; children: preact.ComponentChildren }) {
  return (
    <div class="lock-edit-row">
      <div class="lock-edit-label">{label}</div>
      {children}
    </div>
  );
}

/** A corner's picks: none, the built-ins, the app it has (if any) and "app…" opening the installed ones. */
function CornerRow({ side, f, set, apps }: { side: 0 | 1; f: LockFaceStyle; set: (f: LockFaceStyle) => void; apps: App[] }) {
  const [picking, setPicking] = useState(false);
  const cur = f.corners[side];
  const put = (c: LockCorner) => {
    const corners: [LockCorner, LockCorner] = [...f.corners];
    corners[side] = c;
    set({ ...f, corners });
    setPicking(false);
  };
  const app = cur?.startsWith("app:") ? apps.find((a) => a.key === cur.slice(4)) : undefined;
  return (
    <Row label={side ? "right shortcut" : "left shortcut"}>
      <Chip k={`corner${side}:none`} on={cur === null} label="none" onPick={() => put(null)} />
      {BUILTIN_CORNERS.map((c) => (
        <Chip key={c} k={`corner${side}:${c}`} on={cur === c} label={c} onPick={() => put(c)} />
      ))}
      {cur?.startsWith("app:") && <Chip k={`corner${side}:app`} on label={(app?.label ?? "app").toLowerCase()} onPick={() => setPicking(!picking)} />}
      <Chip k={`corner${side}:pick`} on={picking} label="app…" onPick={() => setPicking(!picking)} />
      {picking && (
        <div class="lock-edit-apps">
          {apps.map((a) => (
            <Chip key={a.key} k={`corner${side}:app:${a.key}`} on={cur === `app:${a.key}`} label={a.label.toLowerCase()} onPick={() => put(`app:${a.key}`)} />
          ))}
        </div>
      )}
    </Row>
  );
}

/** The editor's rows; [onDone] shows a "done" (the face's edit), the settings screen has its own back. */
export function LockEditor({ onDone }: { onDone?: () => void }) {
  const f = lockFace.value;
  const [apps, setApps] = useState<App[]>([]);
  useEffect(() => void powos.apps.list().then((a) => setApps([...a].sort((x, y) => x.label.localeCompare(y.label))), () => {}), []);
  const set = setLockFace;
  const clock = (c: Partial<LockFaceStyle["clock"]>) => set({ ...f, clock: { ...f.clock, ...c } });
  return (
    <div class="lock-edit" onPointerDown={(e) => e.stopPropagation()}>
      {onDone && (
        <div class="lock-edit-head">
          <span>customize the lock screen</span>
          <Chip k="done" on label="done" onPick={onDone} />
        </div>
      )}
      <Row label="clock font">
        {(Object.keys(FONTS) as (keyof typeof FONTS)[]).map((k) => (
          <Chip key={k} k={`font:${k}`} on={f.clock.font === k} label={k} onPick={() => clock({ font: k })} />
        ))}
      </Row>
      <Row label="clock weight">
        {(Object.keys(WEIGHTS) as (keyof typeof WEIGHTS)[]).map((k) => (
          <Chip key={k} k={`weight:${k}`} on={f.clock.weight === k} label={k} onPick={() => clock({ weight: k })} />
        ))}
      </Row>
      <Row label="clock colour">
        {CLOCK_COLORS.map((k) => (
          <Chip key={k} k={`color:${k}`} on={f.clock.color === k} label={k === "foreground" ? "text" : k} swatch={`var(--color-${k})`} onPick={() => clock({ color: k })} />
        ))}
      </Row>
      <Row label="background">
        {WALLS.map((k) => (
          <Chip key={k} k={`wall:${k}`} on={f.wall === k} label={WALL_LABEL[k]} onPick={() => set({ ...f, wall: k })} />
        ))}
      </Row>
      <Row label="at a glance">
        {GLANCE_ITEMS.map((k) => (
          <Chip key={k} k={`glance:${k}`} on={f.glance[k]} label={GLANCE_LABEL[k]} onPick={() => set({ ...f, glance: { ...f.glance, [k]: !f.glance[k] } })} />
        ))}
      </Row>
      <CornerRow side={0} f={f} set={set} apps={apps} />
      <CornerRow side={1} f={f} set={set} apps={apps} />
    </div>
  );
}

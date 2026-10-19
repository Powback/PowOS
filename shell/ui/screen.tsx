/**
 * A widget's screen: what its onTap's screen() opens, full size over home (WidgetTile.kt's WidgetScreenPanel). A
 * terminal's is edge to edge, without a title - every column counts - its terminal taking the keyboard (its extra keys
 * docked above it, the terminal giving up its bottom to them: terminal.tsx). Others are a titled panel. Back closes
 * either (state.ts); a terminal's shell keeps running, back in its tile.
 */
import { OwlWidget } from "./owl.tsx";
import { screen } from "../state.ts";
import { powos } from "../bridge.ts";

/** Its touches are its own: nothing under it (home's swipes, tiles) sees them. */
const own = {
  onTouchStart: (e: TouchEvent) => e.stopPropagation(),
  onTouchMove: (e: TouchEvent) => e.stopPropagation(),
  onPointerDown: (e: PointerEvent) => e.stopPropagation(),
};

export function ScreenPanel() {
  const s = screen.value;
  if (!s.key) return null;
  if (s.terminal) {
    return (
      <div class="screen-panel terminal" {...own}>
        <OwlWidget widget={s.key} screen />
      </div>
    );
  }
  return (
    <div class="screen-scrim" {...own} onClick={(e) => e.target === e.currentTarget && powos.widgets.closeScreen()}>
      <div class="screen-panel tile">
        <div class="screen-head">
          <span>{s.title}</span>
          <button type="button" class="screen-close" onClick={() => powos.widgets.closeScreen()}>
            ✕
          </button>
        </div>
        <div class="screen-body">
          <OwlWidget widget={s.key} screen />
        </div>
      </div>
    </div>
  );
}

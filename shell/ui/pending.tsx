/**
 * The shared "something is being made, or something is in flight" building block (the user: "whenever a change is
 * happening or supposed to begin happening, have some kind of indication of it" - a rule of thumb, not a one-off:
 * a user-triggered change that shows nothing for more than ~100ms is a bug). Two halves:
 *
 *   - the pending/progress model, for something that can't be shown before it exists (a new app's build, a new
 *     widget's first data): PendingState + PendingStep, ProgressRing/ProgressBar/StepList/LogTail to draw them,
 *     PendingIconBadge (an icon with a ring over it) and SkeletonWidgetTile (a home placeholder at the real size)
 *     for the moment something APPEARS, PendingDetailSheet (apps/sheet.ts's popover) for tapping it open;
 *   - `optimistic()`, for everything else: a toggle, a move, a rename, an install - the UI applies the change at
 *     once, as if it already worked, and only a failure rolls it back in place with a reason and Retry.
 *
 * The model itself (PendingState/PendingStep, stepsProgress, ProgressRing, StepList, optimistic) lives in
 * ./shared/pending.tsx and is re-exported below unchanged - that's `@powos/shared/pending` to a PowOS app's own UI
 * (apps/build.sh mounts shell/ui/shared read-only and aliases it; friction f179, fixed here, was apps/app-api
 * forking a subset of this file because apps build in isolation and couldn't import across the folder boundary).
 * What's left in this file needs more than that module: ProgressBar, LogTail, and the badge/skeleton/building/sheet
 * views, the last of which anchors to apps/sheet.ts's popover - shell-only, not something an app's own UI has.
 *
 * Fed live: app creation from PowOS AI's chat steps (ui/appbuild.tsx), widget creation from powos-registry's
 * `creation`/`creation_step`/`creation_log` tables (apps/registry.ts useCreations, written by lib/apps/powos-compose
 * as it runs - docs/COMPOSER.md). Design: shell/theme.css tokens only (--color-accent, --soft-fill, --color-muted);
 * no borders, no raw colors (docs/DESIGN-LANGUAGE.md). Motion is calm and bounded to the time something is actually
 * building - never a forever animation on a settled tile (the app-icon "loading" pulse already caps itself for the
 * same reason: a spinning compositor layer costs battery on an otherwise idle home).
 */
import type { ComponentChildren } from "preact";
import { DetailSheet } from "../apps/sheet.ts";
import { ProgressRing, StepList, stepsProgress, type PendingState } from "./shared/pending.tsx";

export { stepsProgress, ProgressRing, StepList, optimistic } from "./shared/pending.tsx";
export type { StepState, PendingStep, PendingState } from "./shared/pending.tsx";

/** A failed state always reads as "full and stopped" (a filled ring/bar), never as more progress hiding the error. */
const shown = (state: PendingState, progress: number | null) => (state.status === "failed" ? 1 : progress);

export function ProgressBar({ progress }: { progress: number | null }) {
  return (
    <div class={`pending-bar ${progress == null ? "indeterminate" : ""}`}>
      <div class="pending-bar-fill" style={progress == null ? undefined : { width: `${Math.round(progress * 100)}%` }} />
    </div>
  );
}

export function LogTail({ lines, max = 4 }: { lines: string[]; max?: number }) {
  if (!lines.length) return null;
  return (
    <div class="pending-log muted">
      {lines.slice(-max).map((l, i) => (
        <div key={i} class="pending-log-line">
          {l}
        </div>
      ))}
    </div>
  );
}

/** An app icon (or a generic glyph) with a progress ring over it - the drawer's placeholder, at creation start. */
export function PendingIconBadge({ children, state }: { children: ComponentChildren; state: PendingState }) {
  const progress = shown(state, stepsProgress(state.steps));
  return (
    <div class={`pending-badge ${state.status}`}>
      {children}
      <span class="pending-badge-ring">
        <ProgressRing progress={progress} />
      </span>
    </div>
  );
}

/** A home widget's placeholder, at its eventual size and spot: skeleton rows, a spinner and a progress bar. */
export function SkeletonWidgetTile({ state }: { state: PendingState }) {
  const progress = shown(state, stepsProgress(state.steps));
  const active = state.steps.find((s) => s.state === "active");
  return (
    <div class={`tile pending-widget ${state.status}`}>
      <div class="pending-skel-rows" aria-hidden="true">
        <div class="pending-skel-row" style={{ width: "72%" }} />
        <div class="pending-skel-row" style={{ width: "46%" }} />
        <div class="pending-skel-row" style={{ width: "60%" }} />
      </div>
      <div class="pending-widget-foot">
        <ProgressRing progress={progress} size={15} />
        <span class="pending-widget-step muted">{state.status === "failed" ? "couldn't make it - tap to retry" : active?.label ?? "starting…"}</span>
      </div>
      <ProgressBar progress={progress} />
    </div>
  );
}

/** The being-built view: progress, the step list, a few log lines, an optional live preview, retry/discard on failure. */
export function BuildingView({
  state,
  preview,
  onRetry,
  onDiscard,
}: {
  state: PendingState;
  preview?: ComponentChildren;
  onRetry?: () => void;
  onDiscard?: () => void;
}) {
  const progress = shown(state, stepsProgress(state.steps));
  return (
    <div class="pending-build">
      <ProgressBar progress={progress} />
      <StepList steps={state.steps} />
      {preview && <div class="pending-preview">{preview}</div>}
      <LogTail lines={state.log ?? []} />
      {state.status === "failed" && (
        <div class="pending-failed">
          <div class="pending-error">{state.error || "something went wrong"}</div>
          <div class="pending-actions">
            {onRetry && (
              <button type="button" class="sheet-item" onClick={onRetry}>
                retry
              </button>
            )}
            {onDiscard && (
              <button type="button" class="sheet-item" onClick={onDiscard}>
                discard
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

/** BuildingView anchored to the tile that was tapped (apps/sheet.ts's one popover: tap outside/swipe down/Back closes it). */
export function PendingDetailSheet({
  anchor,
  state,
  onClose,
  preview,
  onRetry,
  onDiscard,
}: {
  anchor: Element | DOMRect | null;
  state: PendingState;
  onClose: () => void;
  preview?: ComponentChildren;
  onRetry?: () => void;
  onDiscard?: () => void;
}) {
  return (
    <DetailSheet anchor={anchor} title={state.title} onClose={onClose}>
      <BuildingView state={state} preview={preview} onRetry={onRetry} onDiscard={onDiscard} />
    </DetailSheet>
  );
}

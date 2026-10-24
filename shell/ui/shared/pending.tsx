/**
 * The cross-app "something is being made, or something is in flight" building block: the pending/progress model
 * (PendingStep/PendingState, stepsProgress, ProgressRing, StepList) and `optimistic()`. Framework-neutral Preact +
 * theme.css tokens only (--color-accent, --soft-fill, --color-muted, --color-red) - no raw colors, no app-specific
 * styling (docs/DESIGN-LANGUAGE.md).
 *
 * This is `@powos/shared/pending`: apps/build.sh mounts shell/ui/shared read-only at /shared and aliases
 * `@powos/shared` to it, so a PowOS app's own UI can import it directly instead of forking it (friction f179 -
 * before this, apps/build.sh's esbuild step only mounted the app's own folder, so an import reaching into shell/
 * couldn't resolve, and apps/app-api/ui/lib/pending.tsx was a hand-kept copy of a subset of this).
 *
 * The shell's own shell/ui/pending.tsx re-exports these and adds the shell-only pieces that need more than this
 * module (LogTail, PendingIconBadge, SkeletonWidgetTile, BuildingView, PendingDetailSheet - the last anchors to
 * apps/sheet.ts's popover, which an app's own UI doesn't have).
 */

export type StepState = "pending" | "active" | "done" | "failed";

export interface PendingStep {
  label: string;
  state: StepState;
}

export interface PendingState {
  id: string;
  /** What this placeholder is for; the shell uses it ("app" | "widget"), an app's own UI can leave it out. */
  kind?: "app" | "widget" | string;
  /** What the user asked for; also what Retry re-sends. */
  title: string;
  status: "running" | "done" | "failed";
  steps: PendingStep[];
  /** The latest few lines, oldest first (shell's LogTail shows the tail); an app's own UI can leave it out. */
  log?: string[];
  error?: string | null;
  /** The real thing's id, once known (an app id, or "<app>/<widget>" key); shell-only. */
  resultId?: string | null;
}

/** Steps done (+half credit for the active one) over the total; null (indeterminate) only with no steps at all. */
export function stepsProgress(steps: PendingStep[]): number | null {
  if (!steps.length) return null;
  const done = steps.filter((s) => s.state === "done").length;
  const active = steps.some((s) => s.state === "active") ? 0.5 : 0;
  return Math.min(1, (done + active) / steps.length);
}

/** progress == null spins (indeterminate); a number draws the ring filled to there, accent on muted track. */
export function ProgressRing({ progress, size = 20 }: { progress: number | null; size?: number }) {
  const r = (size - 3) / 2;
  const c = 2 * Math.PI * r;
  return (
    <svg class={`pending-ring ${progress == null ? "spin" : ""}`} width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden="true">
      <circle cx={size / 2} cy={size / 2} r={r} class="pending-ring-track" fill="none" stroke-width="2.5" />
      <circle
        cx={size / 2}
        cy={size / 2}
        r={r}
        class="pending-ring-fill"
        fill="none"
        stroke-width="2.5"
        stroke-linecap="round"
        stroke-dasharray={c}
        stroke-dashoffset={c * (1 - (progress ?? 0.22))}
        transform={`rotate(-90 ${size / 2} ${size / 2})`}
      />
    </svg>
  );
}

const MARK: Record<StepState, string> = { done: "✓", failed: "✗", active: "", pending: "" };

export function StepList({ steps }: { steps: PendingStep[] }) {
  return (
    <div class="pending-steps">
      {steps.map((s, i) => (
        <div key={i} class={`pending-step ${s.state}`}>
          <span class="pending-step-mark">{MARK[s.state]}</span>
          <span>{s.label}</span>
        </div>
      ))}
    </div>
  );
}

/**
 * Optimistic action: [apply] runs now - the UI already shows the result, as if it had already succeeded (a toggle
 * flipped, an item added/moved/removed, a name changed). [commit] does the real work in the background; its
 * rejection calls [rollback] (undo in place, a short reason) and still propagates, so a caller that wants to know
 * can await it. For anything reversible and fully knowable right away. Something that doesn't exist yet until the
 * real work finishes (a new app, a new widget's first data) gets a placeholder (PendingState above) instead, not
 * an optimistic guess at content that isn't there.
 */
export async function optimistic<T>(apply: () => void, commit: () => Promise<T>, rollback: (err: unknown) => void): Promise<T> {
  apply();
  try {
    return await commit();
  } catch (err) {
    rollback(err);
    throw err;
  }
}

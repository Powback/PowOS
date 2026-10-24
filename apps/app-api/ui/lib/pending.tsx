/**
 * A small, self-contained port of shell/ui/pending.tsx's building block for App API's own UI: the pending/progress
 * model (PendingStep/PendingState, ProgressRing, StepList, stepsProgress) and `optimistic()`, same shapes and same
 * API as that module. Not imported directly: apps build in isolation (apps/build.sh's esbuild step mounts only the
 * app's own folder - apps/app-api here - so an import reaching outside it into shell/ can't resolve). Styled with
 * this app's own inline-style convention (lib/ui.tsx's S / CSS vars) instead of shell/theme.css's .pending-* classes,
 * for the same reason.
 *
 * Used by "+ add app" -> "From an installed app" (lib/add.tsx): tapping an installed app adds a placeholder draft
 * card at once, with its real progress, while the runtime builds the draft - then it turns into the draft in place.
 */
import { Muted } from "./ui";

export type StepState = "pending" | "active" | "done" | "failed";

export interface PendingStep {
  label: string;
  state: StepState;
}

export interface PendingState {
  id: string;
  /** What's being added (the installed app's name): also the placeholder card's title. */
  title: string;
  status: "running" | "done" | "failed";
  steps: PendingStep[];
  error?: string | null;
}

/** Steps done (+half credit for the active one) over the total; null (indeterminate) only with no steps at all. */
export function stepsProgress(steps: PendingStep[]): number | null {
  if (!steps.length) return null;
  const done = steps.filter((s) => s.state === "done").length;
  const active = steps.some((s) => s.state === "active") ? 0.5 : 0;
  return Math.min(1, (done + active) / steps.length);
}

/** progress == null draws an indeterminate ring; a number fills it to there - accent on a muted track. */
export function ProgressRing({ progress, size = 20 }: { progress: number | null; size?: number }) {
  const r = (size - 3) / 2;
  const c = 2 * Math.PI * r;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden="true">
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="var(--soft-fill)" stroke-width="2.5" />
      <circle
        cx={size / 2}
        cy={size / 2}
        r={r}
        fill="none"
        stroke="var(--color-accent)"
        stroke-width="2.5"
        stroke-linecap="round"
        stroke-dasharray={c}
        stroke-dashoffset={c * (1 - (progress ?? 0.22))}
        transform={`rotate(-90 ${size / 2} ${size / 2})`}
      />
    </svg>
  );
}

const MARK: Record<StepState, string> = { done: "✓", failed: "✗", active: "…", pending: "" };

export function StepList({ steps }: { steps: PendingStep[] }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: "2px" }}>
      {steps.map((s, i) => (
        <Muted key={i}>{`${MARK[s.state] ? `${MARK[s.state]} ` : ""}${s.label}`}</Muted>
      ))}
    </div>
  );
}

/**
 * Optimistic action: [apply] runs now - the UI already shows the result, as if it had already succeeded. [commit]
 * does the real work in the background; its rejection calls [rollback] (undo in place, a short reason) and still
 * propagates, so a caller that wants to know can await it.
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

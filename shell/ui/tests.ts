/**
 * The phone checks as a control in the shade's Tools (control.tsx): the verify runner's state (VerifyRun.kt, its
 * heartbeat on the phone) - running, waiting for the user to put the phone down, or paused - and one tap to stop them
 * or resume them. Stop is the test pill's x (bridge verify.stop: the runner kills the running check and pauses the
 * queue); resume is the AI page's (verifyGo "all"). Only while there are checks to stop or resume, and only on a host
 * that can stop them.
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { QuickTile, VerifyState } from "../types.ts";

export const TESTS_ID = "powos.tests";

const runner = signal<VerifyState | null>(null);
powos.on("verify.state", (s: VerifyState) => (runner.value = s));

/** No beat for this long (powai.tsx STALE_S): the runner is gone, a running or waiting check with it. */
const STALE_S = 45;

/** The host has verify.stop: asked once dry (nothing stopped); older hosts reject "no such call". */
const canStop = signal(false);
let probed = false;

/** Asks for the runner's state (and once, whether this host can stop it): while the shade shows. */
export function askTests() {
  if (!probed) {
    probed = true;
    powos.ai.verifyStop?.(true).then(
      () => (canStop.value = true),
      () => {},
    );
  }
  powos.ai.verifyState?.().catch(() => {});
}

type Phase = "running" | "waiting" | "paused";

function phase(s: VerifyState | null): Phase | null {
  if (!s || s.age < 0) return null;
  if (s.state === "paused") return "paused";
  if (s.age > STALE_S) return null;
  return s.state === "running" || s.state === "waiting" ? s.state : null;
}

const WORD: Record<Phase, string> = { running: "testing", waiting: "tests wait", paused: "tests paused" };

/** A tap's answer, shown until the runner has had time to see the flag (it looks every 5 s), over its older beats. */
const tapped = signal<{ p: Phase; until: number } | null>(null);
const HOLD_MS = 8000;

function now(): Phase | null {
  const t = tapped.value;
  return t && Date.now() < t.until ? t.p : phase(runner.value);
}

/** The control, or null with nothing to stop or resume: on while checks run or wait, off while paused. */
export function testsTile(): QuickTile | null {
  const p = canStop.value ? now() : null;
  if (!p) return null;
  return { id: TESTS_ID, label: WORD[p], on: p !== "paused", detail: p === "paused" ? "tap to resume" : "tap to stop" };
}

/** Stop or resume; the control says so at once. */
export function toggleTests() {
  const paused = now() === "paused";
  tapped.value = { p: paused ? "waiting" : "paused", until: Date.now() + HOLD_MS };
  (paused ? powos.ai.verifyGo?.("all") : powos.ai.verifyStop?.())?.catch((e) => {
    tapped.value = null;
    console.warn("tests:", e);
  });
}

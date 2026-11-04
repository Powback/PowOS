/**
 * The parts of PowOS a phone without root adds later (targets/android/rootfs-packs.conf; the host's Packs.java):
 * gaming, apps, dev tools, languages. Settings > Storage lists them; the library offers "add gaming" while that one
 * is missing. A tap shows its result at once (pending until the host's first progress comes), then the host's live
 * download/unpack progress (ShellScreens.kt storage()), and "cancel" while it downloads or unpacks (Packs.cancel: what
 * landed so far is deleted).
 */
import { signal } from "@preact/signals";
import { act, useScreen } from "../screens.ts";

export type PackJob = { phase: "downloading"; done: number; total: number } | { phase: "installing"; done: number; total: number } | { phase: "removing" } | { phase: "failed"; message: string } | null;
export interface Pack {
  name: string;
  download: number;
  unpacked: number;
  installed: boolean;
  job: PackJob;
}
export interface StorageState {
  packs: Pack[];
}

/** What each pack is, in plain words. */
export const PACK_INFO: Record<string, [string, string]> = {
  gaming: ["gaming", "Steam, Windows games (Proton), x86 apps (FEX, box64)"],
  apps: ["more apps", "Brave, office, media, printing, databases and the rest of PowOS's apps"],
  dev: ["developer tools", "compilers, build tools, debuggers"],
  languages: ["languages", "translations and fonts beyond English"],
};

/** Taps waiting for the host's first answer: name -> "add" | "remove" | "cancel". */
const pending = signal<Record<string, "add" | "remove" | "cancel">>({});

export function packAction(name: string, what: "add" | "remove" | "cancel" | "dismiss") {
  if (what !== "dismiss") pending.value = { ...pending.value, [name]: what };
  void act("storage", what, name);
}

const mb = (b: number) => (b >= 2 ** 30 ? `${(b / 2 ** 30).toFixed(1)} GB` : `${Math.max(1, Math.round(b / 2 ** 20))} MB`);
export const packSize = (p: Pack) => `${mb(p.download)} download · ${mb(p.unpacked)} on the phone`;
export const packDownload = (p: Pack) => mb(p.download);
export const packFrees = (p: Pack) => mb(p.unpacked);

/** The live progress bar (a sliver while the share is unknown). */
export function PackBar({ progress }: { progress: number | null }) {
  return (
    <div class="scr-bar">
      <i style={{ width: `${Math.round((progress ?? 0.03) * 100)}%` }} />
    </div>
  );
}

export type PackStatus = { busy: boolean; text: string; progress: number | null; failed: boolean };
const status = (text: string, busy = false, progress: number | null = null, failed = false): PackStatus => ({ busy, text, progress, failed });
const share = (j: { done: number; total: number }) => (j.total ? j.done / j.total : null);

/** What a host job reads as. */
const JOB: { [K in NonNullable<PackJob>["phase"]]: (j: Extract<NonNullable<PackJob>, { phase: K }>) => PackStatus } = {
  downloading: (j) => status(`downloading ${mb(j.done)}${j.total ? ` of ${mb(j.total)}` : ""}`, true, share(j)),
  installing: (j) => status("installing…", true, share(j)),
  removing: () => status("removing…", true),
  failed: (j) => status(`didn't finish: ${j.message}`, false, null, true),
};

/** Whether the host has answered the tap waiting on [p]: a job of its own, or the pack already where the tap wanted (a cancel: no job left). */
const answered = (p: Pack, wait: "add" | "remove" | "cancel") =>
  wait === "cancel" ? p.job == null || p.job.phase === "failed" : (p.job != null && p.job.phase !== "failed") || (p.job == null && (wait === "add") === p.installed);

/** Whether [p]'s install can be cancelled now: downloading or unpacking (or the add tap still waiting for the host). */
export const packCancellable = (p: Pack) => {
  const wait = pending.value[p.name];
  if (wait === "cancel") return false;
  if (wait === "add" && !answered(p, wait)) return true;
  return p.job?.phase === "downloading" || p.job?.phase === "installing";
};

/** What a tap reads as until the host answers it. */
const WAITING = { add: "starting…", remove: "removing…", cancel: "cancelling…" } as const;

/** The pack as the page shows it now: the tap still waiting for the host, else the host's job, else installed or not. */
export function packStatus(p: Pack): PackStatus {
  const wait = pending.value[p.name];
  if (wait && !answered(p, wait)) return status(WAITING[wait], true);
  if (wait) {
    const { [p.name]: _, ...rest } = pending.value;
    queueMicrotask(() => (pending.value = rest));
  }
  const j = p.job;
  if (!j) return status(p.installed ? "installed" : "not installed");
  return (JOB[j.phase] as (j: NonNullable<PackJob>) => PackStatus)(j);
}

/** The host's pack list while the caller shows (empty on a full rootfs). */
export const usePacks = () => useScreen<StorageState>("storage")?.packs ?? null;

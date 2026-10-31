/**
 * host.notifications - PowOS apps' view of the phone's notifications (the What needs me app, apps/needs-me): the
 * notifications the official apps already posted on this phone, as the shade lists them (bridge notifications.*:
 * Notifications.kt through MediaListener's access), and each notification's OWN actions - its RemoteInput reply,
 * its mark-as-read, its tap (contentIntent), its dismissal.
 *
 * Scoped by the manifest: an app sees and acts on only the packages its powos-app.json "permissions" names as
 * "notifications:<package>" ("notifications:com.discord"); a key from any other package is refused. Nothing here
 * talks to any service: every call is one press of one notification's own action, made when the app calls it - and an
 * app calls it from a tap (apps/needs-me never acts on its own).
 *
 *   const n = host.notifications.useList(app);                   // { available, items } live, null until read
 *   await host.notifications.action(app, key, index, "on my way"); // one press of action [index], text typed into it
 *   <host.notifications.ReplyField value=... onInput=... onSend=... />  // the bar's pill: field, mic, send
 */
import type { ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { NotificationList, PhoneNotification } from "../types.ts";
import type { MicTarget } from "../ui/dictation.ts";
import { installedApps } from "./pages.ts";

const PREFIX = "notifications:";

/** The packages [app]'s manifest lets it read ("notifications:<package>" in permissions); none: an empty list. */
export function allowedPackages(app: string): string[] {
  const row = installedApps.value.find((a) => a.id === app);
  if (!row) return [];
  try {
    const perms: unknown = JSON.parse(row.manifest || "{}").permissions;
    return Array.isArray(perms) ? perms.filter((p): p is string => typeof p === "string" && p.startsWith(PREFIX)).map((p) => p.slice(PREFIX.length)) : [];
  } catch {
    return [];
  }
}

const scoped = (app: string, l: NotificationList): NotificationList => {
  const pkgs = new Set(allowedPackages(app));
  return { available: l.available, items: l.items.filter((n) => !!n.pkg && pkgs.has(n.pkg)) };
};

async function list(app: string): Promise<NotificationList> {
  return scoped(app, await powos.notifications.list());
}

/** [key], if it's one of [app]'s packages' notifications now; else it throws (gone, or not the app's to touch). */
async function own(app: string, key: string): Promise<PhoneNotification> {
  const n = (await list(app)).items.find((i) => i.key === key);
  if (!n) throw new Error("that notification is gone, or isn't one this app may use");
  return n;
}

/** The scoped list, live ("notifications.changed"); null until the first read. */
function useList(app: string): NotificationList | null {
  const [l, setL] = useState<NotificationList | null>(null);
  useEffect(() => {
    let live = true;
    const set = (v: NotificationList) => live && setL(scoped(app, v));
    void powos.notifications.list().then(set, () => live && setL({ available: false, items: [] }));
    const off = powos.on("notifications.changed", set);
    return () => {
      live = false;
      off?.();
    };
  }, [app]);
  return l;
}

/** The bar's module (ui/bar.tsx), loaded on first use - imported statically it would tie apps/stdb.ts to the bar. */
let bar: typeof import("../ui/bar.tsx") | null = null;

export interface ReplyFieldProps {
  value: string;
  onInput(v: string): void;
  /** The send button (or Enter) - the only way a reply leaves: dictation fills the field and never sends. */
  onSend(): void;
  placeholder?: string;
  sending?: boolean;
  children?: ComponentChildren;
}

/**
 * The bar's pill (ui/bar.tsx Pill: the growing field, the mic, send) as a reply field. The mic dictates into the field
 * - a held mic (the bar's talk-then-send) puts its words in the field too: only the send button or Enter sends.
 */
function ReplyField({ value, onInput, onSend, placeholder, sending }: ReplyFieldProps) {
  const [mod, setMod] = useState(bar);
  const now = useRef({ value, onInput });
  now.current = { value, onInput };
  const target = useRef<MicTarget>({
    typed: () => now.current.value,
    heard: (full) => now.current.onInput(full),
  }).current;
  useEffect(() => {
    if (!mod) void import("../ui/bar.tsx").then((m) => setMod((bar = m)));
  }, []);
  if (!mod) return null;
  const Pill = mod.Pill;
  return (
    <form
      class="reply-field"
      onPointerDown={(e) => e.stopPropagation()}
      onSubmit={(e) => {
        e.preventDefault();
        if (value.trim() && !sending) onSend();
      }}
    >
      <Pill target={target} value={value} onInput={onInput} send sending={sending} placeholder={placeholder ?? "Reply"} aria-label="reply" />
    </form>
  );
}

export interface AppNotifications {
  list(app: string): Promise<NotificationList>;
  useList(app: string): NotificationList | null;
  /** One press of [key]'s action [index]; [text] typed into it when it takes a reply. Refused for another package's. */
  action(app: string, key: string, index: number, text?: string): Promise<void>;
  /** Its tap action (contentIntent): the app opens on the conversation. */
  open(app: string, key: string): Promise<void>;
  dismiss(app: string, key: string): Promise<void>;
  /** The setting that grants PowOS notification access. */
  access(): Promise<void>;
  ReplyField: (p: ReplyFieldProps) => ComponentChildren;
}

export const notifications: AppNotifications = {
  list,
  useList,
  async action(app, key, index, text) {
    const n = await own(app, key);
    if (!n.actions?.[index]) throw new Error("that notification has no such action");
    await powos.notifications.action(key, index, text);
  },
  async open(app, key) {
    await own(app, key);
    await powos.notifications.open(key);
  },
  async dismiss(app, key) {
    await own(app, key);
    await powos.notifications.dismiss(key);
  },
  access: () => powos.notifications.access(),
  ReplyField,
};

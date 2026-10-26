/**
 * The glasses' default screen (a glasses app: glasses/api.ts): the time, the newest notification, and PowOS AI's last
 * reply - three views a tap apart.
 *
 * - tap: the next view (home -> notifications -> PowOS AI -> home)
 * - double tap: talk to PowOS AI (the G2's microphone and its own speech recognition; what it hears is sent as a
 *   message, the reply shows here)
 * - scroll up / down: through the view (in the G2's text mode the glasses scroll the text themselves and say when
 *   they hit an end: then the previous / next view)
 *
 * Laid out as lines of the view's grid, so text mode and image mode show the same thing. The clock ticks each minute
 * except in the G2's text mode, where each change re-sends the whole text (~2.5 s of radio): there the time is the
 * time of the last change, and the glasses' own dashboard has the live one.
 */
import { useEffect, useMemo, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { Chat, ChatItem, NotificationList, PhoneNotification } from "../types.ts";
import { type GlassesApi, wrap } from "./api.ts";

type View = "home" | "notes" | "ai";
const VIEWS: View[] = ["home", "notes", "ai"];

function useClock(tick: boolean) {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    if (!tick) return;
    let timer = 0;
    const next = () => {
      const d = new Date();
      setNow(d);
      timer = window.setTimeout(next, 60_000 - (d.getSeconds() * 1000 + d.getMilliseconds()) + 50);
    };
    next();
    return () => clearTimeout(timer);
  }, [tick]);
  return now;
}

function useNotifications() {
  const [list, setList] = useState<PhoneNotification[]>([]);
  useEffect(() => {
    const set = (n: NotificationList | null) => setList(n?.items ?? []);
    powos.notifications.list().then(set, () => {});
    return powos.on("notifications.changed", set);
  }, []);
  // Newest first; ongoing ones (music, the glasses' own connection) after the ones that came and wait to be read.
  return useMemo(() => [...list].sort((a, b) => Number(b.clearable) - Number(a.clearable) || b.time - a.time), [list]);
}

function useChat() {
  const [chat, setChat] = useState<Chat | null>(null);
  useEffect(() => {
    powos.ai.chat().then(setChat, () => {});
    return powos.on("ai.changed", setChat);
  }, []);
  return chat;
}

const lastReply = (items: ChatItem[]) => {
  for (let i = items.length - 1; i >= 0; i--) {
    const it = items[i];
    if (it.kind === "assistant") return it.text;
  }
  return "";
};

export default function Hud({ glasses }: { glasses: GlassesApi }) {
  const v = glasses.view;
  const g2Text = v.mode === "text" && v.bits === 4;
  const now = useClock(!g2Text);
  const notes = useNotifications();
  const chat = useChat();
  const [view, setView] = useState<View>("home");
  const [top, setTop] = useState(0);
  const [listening, setListening] = useState(false);
  const [heard, setHeard] = useState("");

  // What the glasses' microphone heard (the G2's recognition): sent to PowOS AI once it's final.
  useEffect(
    () =>
      powos.on("glasses.transcript", ({ text, final }: { text: string; final: boolean }) => {
        if (!glasses.live) return;
        setHeard(text);
        if (!final) return;
        setListening(false);
        powos.glasses.mic(false).catch(() => {});
        if (text.trim()) {
          powos.ai.send(text.trim(), false).catch(() => {});
          setView("ai");
          setTop(0);
        }
      }),
    [],
  );

  const sep = v.bits === 1 ? "-".repeat(Math.min(v.cols, 12)) : "─".repeat(Math.min(v.cols, 12));
  const lines = useMemo(() => {
    const out: string[] = [];
    const add = (s: string) => out.push(...wrap(s, v.cols));
    if (view === "home") {
      const time = now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
      const day = now.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" });
      add(`${time}  ${day}`);
      const n = notes[0];
      if (n) {
        out.push(sep);
        add(`${n.app}: ${n.title}`);
        if (n.text) add(n.text);
        if (notes.length > 1) add(`+${notes.length - 1} more`);
      }
      const reply = chat ? lastReply(chat.items) : "";
      if (chat?.busy || reply) {
        out.push(sep);
        add(chat?.busy ? "PowOS AI: thinking…" : `AI: ${reply}`);
      }
    } else if (view === "notes") {
      if (!notes.length) add("No notifications");
      notes.forEach((n, i) => {
        if (i) out.push(sep);
        add(`${n.app}: ${n.title}`);
        if (n.text) add(n.text);
      });
    } else {
      if (listening) add(heard ? `> ${heard}` : "Listening…");
      else if (chat?.busy) add("PowOS AI: thinking…");
      const reply = chat ? lastReply(chat.items) : "";
      add(reply || "Double-tap to ask PowOS AI");
    }
    return out;
  }, [view, now, notes, chat, listening, heard, v.cols, sep]);

  // Text mode on the G2: all of it (the glasses scroll); otherwise a screenful from [top].
  const shown = g2Text ? lines : lines.slice(top, top + v.rows);

  glasses.useInput((input) => {
    const at = VIEWS.indexOf(view);
    const go = (d: number) => {
      setView(VIEWS[(at + d + VIEWS.length) % VIEWS.length]);
      setTop(0);
    };
    if (input === "click") go(1);
    else if (input === "double") {
      // The G1's microphone is LC3, not recognized here; the phone's preview leaves the microphone to the glasses.
      if (v.model !== "G2" || !glasses.live) return;
      const on = !listening;
      setListening(on);
      setHeard("");
      powos.glasses.mic(on).catch(() => setListening(false));
      if (on) {
        setView("ai");
        setTop(0);
      }
    } else if (input === "down") {
      if (g2Text || top + v.rows >= lines.length) go(1);
      else setTop(top + v.rows);
    } else if (input === "up") {
      if (g2Text || top === 0) go(-1);
      else setTop(Math.max(0, top - v.rows));
    }
  });

  const size = Math.floor((v.height / v.rows) * 0.78);
  return (
    <div class="glasses-hud" style={{ fontSize: `${size}px`, lineHeight: `${Math.floor(v.height / v.rows)}px`, padding: "0 6px" }}>
      {shown.map((l, i) => (
        <div key={i} class="glasses-line">
          {l || " "}
        </div>
      ))}
    </div>
  );
}

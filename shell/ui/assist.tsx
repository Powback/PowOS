/**
 * PowOS AI over another app (index.html?mode=assist; PowosAssistSession, the phone's digital assistant: holding the
 * power button). A panel at the bottom: the screen it was opened over (a thumbnail), the question - typed, or the mic
 * (hold to talk and send, tap to dictate) - and PowOS AI's answer as it comes. What's asked goes with the screen's text,
 * so "what's this?" means the screen. A tap above the panel puts it away.
 */
import { useEffect } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { Mic, hearing, type MicTarget } from "./bar.tsx";
import { Now } from "./powai.tsx";
import type { AssistScreen } from "../types.ts";

const screen = signal<AssistScreen | null>(null);
const draft = signal("");
/** Asked something since it opened: the answer shows. */
const asked = signal(false);

powos.on("assist.context", (s: AssistScreen) => (screen.value = s));

/** The screen's text that goes along with a question, at most (the host caps it too). */
const SCREEN_TEXT = 4000;

function send() {
  const text = draft.value.trim();
  if (!text) return;
  draft.value = "";
  asked.value = true;
  const seen = screen.value?.text.trim();
  powos.ai.send(seen ? `${text}\n\n[What's on my screen right now:]\n${seen.slice(0, SCREEN_TEXT)}` : text);
}

const mic: MicTarget = {
  typed: () => draft.value,
  heard: (full, sendIt) => {
    draft.value = full;
    if (sendIt) send();
  },
};

export function Assist() {
  useEffect(() => {
    powos.assist.screen().then((s) => s && (screen.value = s));
  }, []);
  const s = screen.value;
  return (
    <div class="assist" onClick={(e) => e.target === e.currentTarget && powos.assist.close()}>
      <div class="assist-panel tile">
        <div class="assist-head">
          {s?.screenshot ? <img class="assist-shot" src={s.screenshot} alt="" /> : <span class="assist-shot blank" />}
          <span class="assist-title">PowOS AI</span>
          <span class="muted assist-sub">{s?.text ? "sees your screen" : "…"}</span>
          <button type="button" class="assist-open" onClick={() => (powos.ai.open(), powos.assist.close())}>
            open ↗
          </button>
        </div>
        {asked.value && <Now />}
        <form
          class="assist-ask"
          onSubmit={(e) => {
            e.preventDefault();
            send();
          }}
        >
          <input
            value={hearing(mic) ?? draft.value}
            onInput={(e) => (draft.value = (e.currentTarget as HTMLInputElement).value)}
            onFocus={() => powos.keyboard.show()}
            placeholder="ask about this screen"
            enterKeyHint="send"
            autocomplete="off"
          />
          <Mic target={mic} />
        </form>
      </div>
    </div>
  );
}

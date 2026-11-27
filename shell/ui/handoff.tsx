/**
 * Handoff, the sending side (docs/DEVICES.md "Handoff"): a switcher card's "Continue on..." lists the account's other
 * devices and hands the card's page or app to the one picked (devices/Handoff.kt, a sealed drop); that device offers
 * "Continue <title> from <this one>". The receiving page's side is apps/pages.ts ("handoff.open").
 */
import { useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { Handoff, HandoffTarget } from "../types.ts";
import { appView, PREFIX } from "../apps/pages.ts";

/** What a card or window hands off: its launcher key (a web app's goes as its page now, host side), a PowOS app's route. */
export function handoffOf(t: { key: string | null; label: string }): Handoff | null {
  if (!t.key) return null;
  const v = appView.value;
  const route = v && PREFIX + v.id === t.key ? v.route : undefined;
  return { app: t.key, title: t.label, ...(route ? { route } : {}) };
}

type State = HandoffTarget[] | "loading" | { said: string } | null;

/**
 * A menu's "Continue on..." (a switcher card's, a web window's tile menu): a tap lists the devices in place, a device
 * sends it, the item says how that went and then [done] closes the menu with those words.
 */
export function ContinueItem({ t, done, cls }: { t: { key: string | null; label: string }; done: (said: string) => void; cls?: string }) {
  const [state, setState] = useState<State>(null);
  const what = handoffOf(t);
  const dev = powos.devices;
  if (!what || !dev?.handoff || !dev.handoffTargets) return null;
  const say = (said: string) => {
    setState({ said });
    setTimeout(() => done(said), 1200);
  };
  if (state === null || state === "loading") {
    const list = () => {
      setState("loading");
      dev.handoffTargets!().then(
        (l) => (l.length ? setState(l) : say("No other devices in your account")),
        () => say("PowStation isn't reachable"),
      );
    };
    return (
      <button type="button" class={cls} disabled={state === "loading"} onClick={(e) => (e.stopPropagation(), list())}>
        {state === "loading" ? "Finding devices..." : "Continue on..."}
      </button>
    );
  }
  if (!Array.isArray(state)) return <button type="button" class={cls} disabled>{state.said}</button>;
  const send = (d: HandoffTarget) => {
    setState({ said: `Sending to ${d.name}...` });
    dev.handoff!(d.id, what).then(
      (r) => say(r.ok ? `Sent - continue on ${d.name}` : (r.why ?? "Couldn't send")),
      () => say("Couldn't send"),
    );
  };
  return (
    <>
      {state.map((d) => (
        <button type="button" class={cls} key={d.id} onClick={(e) => (e.stopPropagation(), send(d))}>
          Continue on {d.name}
        </button>
      ))}
    </>
  );
}

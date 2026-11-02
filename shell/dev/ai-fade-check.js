// The AI page's chat and lists fade out at their foot into the bar / pane edge (the user, 11-02: "the AI pages don't
// have the fade-out"), only while content continues below: in the page, every scroller of the AI page that overflows -
// the Friction list, the status column, the chat (column-reverse: its end is scrollTop 0) - carries a mask, a foot fade
// (--ai-fade > 0) scrolled away from its end, and none (0) at its end, so the last row is never faded.
const frames = (n) => window.__gw.frames(n);

/** [el]'s foot fade in px right now. */
const fade = (el) => parseFloat(getComputedStyle(el).getPropertyValue("--ai-fade")) || 0;

/** The AI page's scrollers on screen that have more than a screen of content. */
const scrollers = () =>
  [...document.querySelectorAll(".ai-screen :is(.ai-scroll, .ag-scroll)")].filter((e) => e.offsetParent && e.getClientRects().length && e.scrollHeight > e.clientHeight + 48 && !e.closest(".ai-aside, [inert]"));

/** [el]'s name for a failure line. */
const named = (el) => `.${[...el.classList].join(".")}`;

/** One scroller: fade away from its end, none at its end. */
async function oneFails(el) {
  const rev = getComputedStyle(el).flexDirection === "column-reverse";
  const max = el.scrollHeight - el.clientHeight;
  const was = el.scrollTop;
  const fails = [];
  const mask = getComputedStyle(el).maskImage || getComputedStyle(el).webkitMaskImage;
  if (!mask || mask === "none") fails.push(`${named(el)} has no mask at its foot`);
  // Away from the end: the top of a list, the middle of the chat (older messages above).
  el.scrollTop = rev ? -max / 2 : 0;
  await frames(4);
  const away = fade(el);
  el.scrollTop = rev ? 0 : max;
  await frames(4);
  const end = fade(el);
  el.scrollTop = was;
  await frames(2);
  if (away < 16) fails.push(`${named(el)}: no foot fade while content continues below (--ai-fade ${away}px, want >= 16)`);
  if (end > 0.5) fails.push(`${named(el)}: the foot still fades at the end (--ai-fade ${end}px): the last row is faded`);
  return { fails, facts: `${named(el)} away ${away} end ${end}` };
}

/** Every overflowing AI scroller on screen; [want] names the ones that must be among them. */
export async function aiFadeFails(label, want) {
  if (!CSS.supports("animation-timeline: scroll()")) return { fails: [], facts: ["no scroll timelines: skipped"] };
  await frames(10);
  const els = scrollers();
  const fails = want.filter((sel) => !els.some((e) => e.matches(sel))).map((sel) => `${label}: no overflowing ${sel} to check`);
  const facts = [];
  for (const el of els) {
    const r = await oneFails(el);
    fails.push(...r.fails.map((f) => `${label}: ${f}`));
    facts.push(r.facts);
  }
  return { fails, facts };
}

/** The chat, long enough to scroll: N exchanges. */
export async function aiFadeChat() {
  const S = await window.__gw.mod("./state.ts");
  const items = [];
  for (let i = 0; i < 14; i++) items.push({ kind: "user", text: `question ${i}: how is the dock going` }, { kind: "assistant", text: `Answer ${i}: three agents are on it - the dock size, the window raise and the page dots. Two land tonight, the third waits on you.` });
  S.chat.value = { busy: false, items };
  S.aiScreen.value = "chat";
  await frames(20);
}

/**
 * A text field that grows with what's in it: one row, up to [rows] as the text wraps (a dictated sentence), then it
 * scrolls inside. Enter submits (the form's onSubmit), Shift+Enter is a new line. Back to one row when the text is
 * sent or cleared - it follows its value, so dictation filling it grows it too. Its height animates (shell.css
 * .grow); it grows upward from where it sits, laying nothing else out again (its container keeps its own height).
 */
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import type { Ref } from "preact";

interface Props {
  value: string;
  onInput: (v: string) => void;
  rows?: number;
  inputRef?: Ref<HTMLTextAreaElement>;
  [attr: string]: any;
}

/**
 * What the field itself last reported (onInput), and whether the keyboard is composing a word in it (Gboard composes
 * the word under the cursor until a space or a commit). Cleared from outside (a send: the user, 2026-10-30 23:08, "the
 * input is not clear"): the DOM value follows at once, and a word the keyboard was still composing is dropped with it -
 * the send button keeps the field focused (bar.tsx Send's pointerdown), so the IME's composing buffer outlived the
 * clear and was committed back into the field. A blur and focus in the same task restarts the IME's input (its buffer
 * empty); the keyboard stays up.
 */
function useClearDropsComposition(own: { current: HTMLTextAreaElement | null }, value: string) {
  const reported = useRef(value);
  const composing = useRef(false);
  useLayoutEffect(() => {
    const t = own.current;
    const was = reported.current;
    reported.current = value;
    if (!t || value !== "" || was === "") return;
    if (t.value !== "") t.value = "";
    if (!composing.current || document.activeElement !== t) return;
    composing.current = false;
    t.blur();
    t.focus({ preventScroll: true });
  }, [value]);
  return {
    reported,
    /** The textarea's composition handlers. */
    ime: {
      onCompositionStart: () => void (composing.current = true),
      onCompositionEnd: () => void (composing.current = false),
    },
  };
}

export function GrowField({ value, onInput, rows = 3, inputRef, ...rest }: Props) {
  const own = useRef<HTMLTextAreaElement>(null);
  const el = () => own.current;
  // The height its text needs, between one row and [rows]: measured with the height let go for a moment. Empty, it is
  // one row whatever its width - its placeholder never wraps it taller (2026-10-22: the search widget, measured before
  // its tile had a width, wrapped "search" a letter a line and stayed three rows tall: a pill two grid rows high).
  const fit = () => {
    const t = el();
    if (!t) return;
    const cs = getComputedStyle(t);
    const line = parseFloat(cs.lineHeight) || 20;
    const pad = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
    const was = t.style.height;
    t.style.transition = "none";
    t.style.height = "0px";
    const need = t.value ? t.scrollHeight : line + pad;
    t.style.height = was;
    void t.offsetHeight;
    t.style.transition = "";
    const h = Math.min(Math.max(need, line + pad), line * rows + pad);
    t.style.height = `${h}px`;
    t.classList.toggle("scrolls", need > line * rows + pad + 1);
    // Past its rows, the newest words in view (dictation adds at the end).
    if (need > h && document.activeElement !== t) t.scrollTop = t.scrollHeight;
  };
  useLayoutEffect(fit, [value, rows]);
  const { reported, ime } = useClearDropsComposition(own, value);
  // Its width changing (laid out late, a fold, a widget resized) wraps its text again: measured again then.
  useEffect(() => {
    const t = el();
    if (!t) return;
    let w = t.clientWidth;
    const ro = new ResizeObserver(() => {
      if (t.clientWidth === w) return;
      w = t.clientWidth;
      fit();
    });
    ro.observe(t);
    return () => ro.disconnect();
  }, [rows]);
  return (
    <textarea
      {...rest}
      {...ime}
      ref={(n) => {
        own.current = n;
        if (typeof inputRef === "function") inputRef(n);
        else if (inputRef) (inputRef as { current: HTMLTextAreaElement | null }).current = n;
      }}
      class={`grow ${rest.class ?? ""}`}
      rows={1}
      value={value}
      onInput={(e) => onInput((reported.current = (e.currentTarget as HTMLTextAreaElement).value))}
      onKeyDown={(e) => {
        if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
          e.preventDefault();
          (e.currentTarget as HTMLTextAreaElement).form?.requestSubmit();
        }
        rest.onKeyDown?.(e);
      }}
    />
  );
}

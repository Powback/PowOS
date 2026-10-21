/**
 * A text field that grows with what's in it: one row, up to [rows] as the text wraps (a dictated sentence), then it
 * scrolls inside. Enter submits (the form's onSubmit), Shift+Enter is a new line. Back to one row when the text is
 * sent or cleared - it follows its value, so dictation filling it grows it too. Its height animates (shell.css
 * .grow); it grows upward from where it sits, laying nothing else out again (its container keeps its own height).
 */
import { useLayoutEffect, useRef } from "preact/hooks";
import type { Ref } from "preact";

interface Props {
  value: string;
  onInput: (v: string) => void;
  rows?: number;
  inputRef?: Ref<HTMLTextAreaElement>;
  [attr: string]: any;
}

export function GrowField({ value, onInput, rows = 3, inputRef, ...rest }: Props) {
  const own = useRef<HTMLTextAreaElement>(null);
  const el = () => own.current;
  // The height its text needs, between one row and [rows]: measured with the height let go for a moment.
  useLayoutEffect(() => {
    const t = el();
    if (!t) return;
    const cs = getComputedStyle(t);
    const line = parseFloat(cs.lineHeight) || 20;
    const pad = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
    const was = t.style.height;
    t.style.transition = "none";
    t.style.height = "0px";
    const need = t.scrollHeight;
    t.style.height = was;
    void t.offsetHeight;
    t.style.transition = "";
    const h = Math.min(Math.max(need, line + pad), line * rows + pad);
    t.style.height = `${h}px`;
    t.classList.toggle("scrolls", need > line * rows + pad + 1);
    // Past its rows, the newest words in view (dictation adds at the end).
    if (need > h && document.activeElement !== t) t.scrollTop = t.scrollHeight;
  }, [value, rows]);
  return (
    <textarea
      {...rest}
      ref={(n) => {
        own.current = n;
        if (typeof inputRef === "function") inputRef(n);
        else if (inputRef) (inputRef as { current: HTMLTextAreaElement | null }).current = n;
      }}
      class={`grow ${rest.class ?? ""}`}
      rows={1}
      value={value}
      onInput={(e) => onInput((e.currentTarget as HTMLTextAreaElement).value)}
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

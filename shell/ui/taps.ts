/**
 * Taps something took - a widget's onTap, a terminal's focus: handlers further out leave them. Marked rather than
 * stopped, so the home tile still sees its press end (a stopped pointerup left its long-press timer running, and the
 * tile lifted after the tap).
 */
const taken = new WeakSet<Event>();

export const takeTap = (e: Event) => void taken.add(e);
export const tapTaken = (e: Event) => taken.has(e);

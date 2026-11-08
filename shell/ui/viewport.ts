/**
 * The viewport's size, read once per resize. innerWidth / innerHeight / devicePixelRatio bring the page's style and
 * layout up to date when read: read in a swipe's move, a rAF or a timer right after a transform write, each one was a
 * forced layout. The user's trace perf-1794158824368 (11-08 18:27, swiping home's pages) had them as self time of
 * homeDotsAt (710 ms, each touchmove 16-53 ms forced), renderoverlay's draw (760 ms) and home's region walk; 2026-10-22
 * nativeglass's format the same (28 ms a second of a drawer drag).
 * Stale after a "resize" (any listener, whatever its order): the next read takes the new size, once.
 */
let size: { w: number; h: number; dpr: number } | null = null;
addEventListener("resize", () => (size = null));

export function viewport(): { w: number; h: number; dpr: number } {
  return (size ??= { w: innerWidth, h: innerHeight, dpr: devicePixelRatio });
}

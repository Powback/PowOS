/**
 * A spring as a CSS easing: a damped spring's step response sampled into `linear(...)` (CSS Easing 2), with the time
 * it takes to settle - so CSS transitions and WAAPI animations move as springs (Quickstep's SpringAnimation feel)
 * without a per-frame script. Where `linear()` isn't supported, a close cubic-bezier.
 */

/** [damping] ratio (< 1 overshoots a little), [stiffness] (1/s²), as Android's SpringForce (mass 1). */
function make(damping: number, stiffness: number) {
  const w0 = Math.sqrt(stiffness);
  const wd = w0 * Math.sqrt(1 - damping * damping);
  const x = (t: number) => 1 - Math.exp(-damping * w0 * t) * (Math.cos(wd * t) + ((damping * w0) / wd) * Math.sin(wd * t));
  // Settled: within 0.1% of its place, and staying there.
  let end = 0.05;
  while (end < 2 && Math.exp(-damping * w0 * end) * 1.2 > 0.001) end += 0.01;
  const steps = 48;
  const points = Array.from({ length: steps + 1 }, (_, i) => x((end * i) / steps).toFixed(4));
  points[steps] = "1";
  const linear = `linear(${points.join(", ")})`;
  const supported = typeof CSS !== "undefined" && CSS.supports("transition-timing-function", "linear(0, 1)");
  return { easing: supported ? linear : "cubic-bezier(0.2, 0.9, 0.25, 1.05)", ms: Math.round(end * 1000) };
}

/** The switcher's spring: brisk, a hint of overshoot (SpringForce DAMPING_RATIO ~0.85, STIFFNESS ~MEDIUM). */
export const spring = make(0.85, 420);

if (typeof document !== "undefined") {
  const root = document.documentElement.style;
  root.setProperty("--spring", spring.easing);
  root.setProperty("--spring-ms", `${spring.ms}ms`);
}

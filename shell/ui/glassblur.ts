/** The theme's compositor blur radius: one reading for every surface of home's glass (a leaf: no imports). */

/**
 * The radius (CSS px) the compositor blurs home's widgets by (ui/nativeglass.ts) and a web window's bar
 * (ui/webwindows.tsx -> WebWindowChrome): the compositor's radius, not a Gaussian's sigma - its blur is ~0.15-0.3 of
 * what it's given (measured on the phone, 2026-10-21), so the theme says it on its own (--glass-blur-native); without
 * it, --glass-blur.
 */
export function themeBlur(): number {
  const css = getComputedStyle(document.documentElement);
  return parseFloat(css.getPropertyValue("--glass-blur-native")) || parseFloat(css.getPropertyValue("--glass-blur")) || 28;
}

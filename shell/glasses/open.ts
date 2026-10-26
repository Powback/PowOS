/** The phone's glasses screen (ui/glasses.tsx) open: its own module, so state.ts's Back and the control center's tile need nothing else of it. */
import { signal } from "@preact/signals";

export const glassesOpen = signal(false);
export const openGlasses = () => (glassesOpen.value = true);
export const closeGlasses = () => (glassesOpen.value = false);

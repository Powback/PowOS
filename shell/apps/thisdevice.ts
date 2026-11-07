/**
 * This phone itself, for the Devices app: whether its other devices may lock it without root (devices/LockAccess.kt -
 * Android's lock-only device admin, which the person turns on from the app and off there or in Settings). Every call
 * rejects on an APK without it (feature-detect: catch it and show nothing); onLock follows every change.
 */
import { powos } from "../bridge.ts";
import type { LockAccess } from "../types.ts";

export interface ThisDevice {
  lock(): Promise<LockAccess>;
  /** Android's own consent screen; the answer arrives through onLock (and lock() once the page is back). */
  allowLock(): Promise<LockAccess>;
  stopLock(): Promise<LockAccess>;
  onLock(on: (s: LockAccess) => void): () => void;
}

const none = () => Promise.reject(new Error("this PowOS app can't do that yet"));

export const thisDevice: ThisDevice = {
  lock: () => powos.devices?.lock() ?? none(),
  allowLock: () => powos.devices?.allowLock() ?? none(),
  stopLock: () => powos.devices?.stopLock() ?? none(),
  onLock: (on) => powos.on("devices.lock", (s) => on(s as LockAccess)),
};

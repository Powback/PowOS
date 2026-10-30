/**
 * The launcher's dock (LD1, the user 2026-10-30, the third report: "the dock is still hiding in the launcher in unfolded
 * mode"). Runs in the page (index.html?mode=pull): gate.mjs's launcher-dock-* cases and shots.mjs's pull-dock-* scenes.
 */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Whether rect [r] sits on screen as home's dock does at [at]: a column at that edge, or a row at the foot. */
function placedAt(r, at) {
  const tall = r.height > r.width;
  const inside = Math.min(r.width, r.height) >= 30 && Math.min(r.top, r.left) >= 0 && r.bottom <= innerHeight + 1 && r.right <= innerWidth + 1;
  const edge = { right: tall && r.right >= innerWidth - 40, left: tall && r.left <= 40, bottom: !tall };
  return inside && edge[at];
}

/** Why the launcher's dock isn't shown in home's placement (pull.tsx dockShown, shell.css .pull-screen > .dock), or "". */
export function launcherDockWrong() {
  const dock = document.querySelector(".pull-screen > .dock:not(.dock-tray)");
  if (!dock) return "no dock in the launcher";
  const op = Number(getComputedStyle(dock).opacity);
  if (op < 0.95) return `launcher dock invisible: opacity ${op}, --p ${dock.style.getPropertyValue("--p")}`;
  const r = dock.getBoundingClientRect();
  const at = /dock-(bottom|left|right)/.exec(document.querySelector(".pull-screen").className)?.[1];
  if (placedAt(r, at)) return "";
  return `launcher dock not on screen ${at}: ${Math.round(r.left)}..${Math.round(r.right)} x ${Math.round(r.top)}..${Math.round(r.bottom)}`;
}

/**
 * Opened for apps after PowOS AI's pull (the side button), as the host does it: the dock mounts during the drag
 * (pull.tsx dockShown: not for "ai") and must still follow it open (gesture.ts followOpenness). [position]: home's dock
 * placement; [keyboard]: the keyboard up as it opens. The failures, empty when the dock is there.
 */
export async function launcherDockOpens(position, keyboard) {
  const S = await importShim("./state.ts");
  const E = window.__mockEvents;
  S.dockTry.value = position;
  // The mock's pinned dock is empty: a few apps, as the phone's (an empty pinned dock unfolded at the foot is none).
  if (!S.dock.value.length) S.dock.value = S.recent.value.slice(0, 4);
  E.emit("pull.begin", { kind: "ai" });
  E.emit("pull.end", { open: true });
  await sleep(400);
  E.emit("pull.end", { open: false });
  await sleep(500);
  E.emit("system.insets", { top: 45, bottom: 16, left: 0, right: 0, keyboard: keyboard ? 330 : 0 });
  E.emit("pull.begin", { kind: "apps" });
  await sleep(50);
  E.emit("pull.drag", { p: 0.6 });
  await sleep(50);
  E.emit("pull.end", { open: true });
  await sleep(400);
  const wrong = launcherDockWrong();
  return wrong ? [`${position}${keyboard ? " +keyboard" : ""}: ${wrong}`] : [];
}

/**
 * The test-only page (index.html?mode=gate-test): the one to break when testing the shell's safety net - the pre-push
 * gate (shell/dev/gate.sh boots it with every other mode), the host's boot watchdog, the rollback and the manager's
 * report - so a test never breaks a page the user is looking at. Only app.tsx's gate-test branch imports it (no live
 * page loads it); on the phone the app loads it in a window-less WebView of its own when this file is pushed
 * (GateTest.kt), and its errors reach the manager marked "[test]" at low priority, read again after 2 min.
 *
 * A test: add a top-level `throw new Error("...")` here (outside the tree you commit), then
 *   shell/push.sh --note "..." test/gate-test.tsx             - the gate refuses it;
 *   shell/push.sh --force --test --note "..." test/gate-test.tsx  - the app rolls it back within seconds.
 */
export function GateTest() {
  return <div style={{ padding: "16px", fontFamily: "sans-serif" }}>PowOS shell gate test page</div>;
}

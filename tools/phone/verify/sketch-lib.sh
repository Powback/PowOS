# tools/phone/verify/sketch-lib.sh (sourced by sketch-*.sh, after js/sql/state): a FRESH test drawing that is none of
# the user's, its cleanup, and a stop when the page goes away mid-check. Sets $known (the user's drawing keys) and $key.
# Why: 2026-10-23 the gallery clicks ran (sleep-timed) before Sketch had mounted, so the check drew on and moved the
# user's own drawing and its cleanup found nothing to delete.
#   . "$(dirname "$0")/sketch-lib.sh"; sketch_fresh || exit 1; ...; drop
# Sketch open (waiting for it to mount), gallery, "new drawing", then wait until the page is on a drawing none of the
# user's: one eval, the waits run on the phone.
q_js='const t = (ms) => new Promise((r) => setTimeout(r, ms)), q = (s) => document.querySelector(s);
  const until = async (f, n) => { for (let i = 0; i < n; i++) { const v = f(); if (v) return v; await t(250); } return f(); };'
fresh() {
  js "(async () => { $q_js const known = new Set($known.map((r) => r[0]));
    if (!(await until(() => q('[aria-label=drawings]'), 40))) return 'Sketch did not open (no gallery button)';
    q('[aria-label=drawings]').click();
    if (!(await until(() => q('[aria-label=\"new drawing\"]'), 20))) return 'no new-drawing button';
    q('[aria-label=\"new drawing\"]').click();
    const s = await until(() => { const s = window.__sketch; return s && s.key && !known.has(s.key) && s.strokes === 0 && s; }, 20);
    return s ? 'fresh' : 'still on ' + JSON.stringify(window.__sketch && [window.__sketch.key, window.__sketch.strokes]); })()"
}
# The test drawing deleted from the gallery (its view with it), never one of the user's.
drop() {
  [ -n "${key:-}" ] || { echo "no test drawing"; return 1; }
  case "$known" in *"\"$key\""*) echo "not deleting $key: it is one of the user's"; return 1 ;; esac
  js "(async () => { $q_js
    if (!q('[aria-label=drawings]')) (window.__powosApps.openApp('local.sketch'), await until(() => q('[aria-label=drawings]'), 40));
    q('[aria-label=drawings]').click();
    const x = await until(() => q('[data-drawing=\"$key\"] [aria-label^=delete]'), 12); if (!x) return 'test drawing not in the gallery';
    x.click(); return (await until(() => !q('[data-drawing=\"$key\"]'), 12)) ? 'deleted' : 'still there'; })()"
}
# The page gone mid-check (a shell push or an install reloads every page: 2026-10-23 00:59) is no verdict: clean up and
# let the queue run it again next window.
alive() { [ -n "$1" ] && [ "$1" != null ] && return 0
  echo "ABORT: Sketch's page went away at '$2' (the shell reloaded?): $(drop) - again next window"; exit 3; }
# Home, Sketch open, a fresh drawing: $key. Prints FAIL and returns 1 (nothing drawn) when that can't be made sure of.
sketch_fresh() {
  known=$(sql "SELECT key FROM drawing")
  case "$known" in \[*) ;; *) echo "FAIL open: can't read the user's drawings ($known): not drawing anything"; return 1 ;; esac
  "$A" shell input keyevent KEYCODE_HOME; sleep 1.5
  js '(window.__powosApps.openApp("local.sketch"), "open")' >/dev/null
  local f s; f=$(fresh); s=$(state); echo "fresh: $f $s" >> "$OUT/states.txt"
  [ "$f" = fresh ] || { echo "FAIL open: no fresh test drawing ($f): not drawing anything"; return 1; }
  key=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["key"])' "$s" 2>/dev/null)
  [ -n "$key" ] || { echo "FAIL open: no key ($s)"; return 1; }
}

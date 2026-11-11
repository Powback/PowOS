#!/bin/bash
# test-widget-fit-check.sh - the Progress widget's device fit check (shell/dev/preview/fit.js homeWidgetFit, run in the
# phone's live page by tools/phone/verify/shell-check.sh): inlined the way shell-check.sh inlines it (its own
# shell_check, sourced, against a fake cdp.sh that evaluates the page expression in node over a stubbed home), it SKIPs
# with the reason when no Progress widget is placed (empty home, another app's island) or none is rendered on this
# screen, never touching home's items; and the gate's sheet.tsx takes the same tileFit. No phone.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; fail=1; }
command -v node >/dev/null || { echo "skip: no node"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# shell-check.sh in a tree of its own: the real script and check file, a fake cdp.sh and adb.sh beside it.
mkdir -p "$W/tools/phone/verify" "$W/shell/dev/preview"
cp "$REPO/tools/phone/verify/shell-check.sh" "$W/tools/phone/verify/"
cp "$REPO/shell/dev/preview/fit.js" "$W/shell/dev/preview/"
cat >"$W/tools/phone/adb.sh" <<'A'
#!/bin/bash
echo "mCommittedState=DeviceState{identifier=0, name='CLOSED'}"
A
# Fake cdp.sh eval <page> <expr>: the expression in node; window.__gw.mod("./state.ts") is a home holding $FAKE_ITEMS;
# no tile is in the DOM. Writes to home's items would show as a changed FAKE_ITEMS on stderr.
cat >"$W/tools/phone/cdp.sh" <<'C'
#!/bin/bash
[ "$1" = eval ] || exit 2
EXPR=$3 node -e '
  const items = JSON.parse(process.env.FAKE_ITEMS);
  const before = JSON.stringify(items);
  const S = { home: { value: { items } } };
  globalThis.window = { __gw: { mod: async () => S, until: async (f) => !!(await f()), steady: async () => true, sleep: async () => {}, frames: async () => {} } };
  globalThis.document = { querySelector: () => null };
  globalThis.CSS = { escape: (s) => s };
  Promise.resolve(eval(process.env.EXPR)).then((r) => {
    if (JSON.stringify(S.home.value.items) !== before) console.error("HOME CHANGED");
    console.log(JSON.stringify(r));
  });'
C
chmod +x "$W/tools/phone/adb.sh" "$W/tools/phone/cdp.sh"
# Sourced, it sets its own T and ROOT (its tree): this test keeps REPO and W.
SHELL_CHECK_LIB=1 . "$W/tools/phone/verify/shell-check.sh"

run() { FAKE_ITEMS=$1 shell_check home preview/fit.js homeWidgetFit @fold 2>"$W/err"; }

r=$(run '[]')
case $r in '["SKIP: no local.powos-progress widget placed on home (folded)'*) ok "empty home: SKIP, says so ($r)" ;; *) bad "empty home" "$r" ;; esac
r=$(run '[{"key":"panel:x","kind":"panel","name":"app:local.lights/main","page":0,"cell":{"x":0,"y":0,"w":2,"h":2}},{"key":"w1","kind":"widget","name":"local.powos-progress","page":0,"cell":null}]')
case $r in '["SKIP: no local.powos-progress widget placed'*) ok "only other widgets: SKIP" ;; *) bad "other widgets" "$r" ;; esac
r=$(run '[{"key":"panel:p","kind":"panel","name":"app:local.powos-progress/main","page":2,"cell":{"x":0,"y":0,"w":4,"h":2}}]')
case $r in '["SKIP: 1 local.powos-progress widget(s) placed, none rendered'*) ok "placed but not on this screen: SKIP" ;; *) bad "unrendered" "$r" ;; esac
grep -q "HOME CHANGED" "$W/err" && bad "the check changed home's items" "$(cat "$W/err")" || ok "home's items untouched"
# shell-check.sh maps a first entry "SKIP: ..." to exit 5 - the same prefix it tests.
grep -q "'\[\"SKIP:'\*) .*exit 5" "$REPO/tools/phone/verify/shell-check.sh" && ok "shell-check.sh: SKIP answer -> exit 5" || bad "shell-check.sh SKIP mapping changed"
# One assertion: the gate's widget sweep measures through the same tileFit.
grep -q 'import { tileFit } from "./fit.js"' "$REPO/shell/dev/preview/sheet.tsx" && grep -q 'tileFit(face' "$REPO/shell/dev/preview/sheet.tsx" \
  && ok "sheet.tsx check() uses fit.js tileFit" || bad "sheet.tsx no longer measures with fit.js tileFit"
exit $fail

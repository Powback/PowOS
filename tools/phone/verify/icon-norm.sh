#!/bin/bash
# lanes: emu phone
# Uniform app icons (board "Uniform app icons", ui/iconshape.ts) on the phone, in a free window (queue.sh, LOCK_HELD=1):
# screencaps of the dock (home) and the drawer (opened with a swipe, Back closes it) onto the board task, labelled
# before/after by whether the phone serves ui/iconshape.ts yet, plus a read-only count of the icons it placed and plated.
# Old shell still served: "before" images posted, exit 3 (re-queued for the window after the ship). New: "after", PASS
# when every icon on screen was measured (none left unplaced). Nothing persistent changes.
set -u
cd "$(dirname "$0")/../../.." || exit 1
p=tools/phone
TASK=${TASK:-uniform-app-icons-min-size-one-squircle-radius-e}
[ -n "${LOCK_HELD:-}" ] || { echo "icon-norm: run it through tools/phone/verify/queue.sh add"; exit 3; }
fg=$($p/adb.sh shell "dumpsys activity activities | grep -m1 topResumedActivity")
[[ "$fg" == *HomeShell* ]] || { echo "icon-norm: home isn't in front"; exit 3; }
# "after" = the shape (iconshape.ts) and the neutral frost plate (theme.css; the first plate was the brown surface tint).
served=$($p/cdp.sh eval home 'Promise.all(["ui/iconshape.ts","theme.css"].map(u=>fetch(u).then(r=>r.ok?r.text():""))).then(([a,b])=>a.includes("placement")&&b.includes("--icon-plate: color-mix(in oklab, var(--frost-base)"))' | tr -d '"')
[ "$served" = true ] && when=after || when=before
probe='JSON.stringify({icons:document.querySelectorAll(".app-icon:not(.initials)").length,placed:document.querySelectorAll(".app-icon-face.placed").length,plate:document.querySelectorAll(".app-icon-face.plate").length})'
OUT=$HOME/.cache/icon-norm-check; mkdir -p "$OUT"
dock=$OUT/icons-dock-$when.png; drawer=$OUT/icons-drawer-$when.png
$p/shot.sh "$dock" >/dev/null 2>&1 || dock=
home=$($p/cdp.sh eval home "$probe" | tr -d '\\')
read -r W H < <($p/cdp.sh eval home 'Math.round(innerWidth*devicePixelRatio)+" "+Math.round(innerHeight*devicePixelRatio)' | tr -d '"')
$p/adb.sh shell input swipe $((W * 3 / 4)) $((H * 85 / 100)) $((W * 3 / 4)) $((H * 30 / 100)) 300
sleep 1.5
$p/shot.sh "$drawer" >/dev/null 2>&1 || drawer=
open=$($p/cdp.sh eval home "$probe" | tr -d '\\')
$p/adb.sh shell input keyevent 4
imgs=()
for f in $dock $drawer; do
  $p/review-image.sh "$f" >/dev/null 2>&1 && imgs+=(--image "/home/powos/design-qa/$(basename "$f")")
done
[ ${#imgs[@]} -gt 0 ] && python3 lib/ai/agents/powos-agents-cli task set "$TASK" "${imgs[@]}" >/dev/null 2>&1
echo "icon-norm ($when): home=$home drawer=$open dock=${dock:-none} drawer=${drawer:-none}"
if [ "$when" = before ]; then
  echo "icon-norm: before images posted; the new icons aren't on the phone yet - again after the ship"
  exit 3
fi
n=$(sed -nE 's/.*"icons":([0-9]+).*/\1/p' <<<"$open"); k=$(sed -nE 's/.*"placed":([0-9]+).*/\1/p' <<<"$open")
if [ -n "$n" ] && [ "${n:-0}" -gt 0 ] && [ "$k" = "$n" ] && [ -n "$drawer" ]; then
  echo "PASS icon-norm: every drawer icon placed in the one squircle ($open)"
else
  echo "FAIL icon-norm: drawer=$open (icons placed should equal icons shown)"
fi

#!/bin/bash
# lanes: phone
# tools/phone/verify/steam-dialogs/answer.sh <appid> <name>: (Mac side, queue it: queue.sh add <task>
# tools/phone/verify/steam-dialogs/answer.sh <appid> <name>) a Steam game whose launch waits on a one-time Steam
# notice (no EULA: ABZU's controller notice, Desk Job's Steam Input explainer - both read first by look.sh, its
# companion): press Enter on the "Steam Dialog" (its default button: OK / Next) until it's gone, check the game
# starts, then close what this started.
# f88: this lived only in ~/.cache/powos-verify/steam-dialogs - gone the moment that cache is cleared, invisible to
# `git log`/review, and only ever reachable by its full absolute path baked into a queued job. Moved into the repo.
set -u
here=$(cd "$(dirname "$0")" && pwd); T=$here/../..
app=$1; name=$2; O=$HOME/.cache/powos-verify/steam-dialogs; mkdir -p "$O"
cat > "$O/a-$app.sh" <<SH
P=\$(pgrep -x plasmashell | head -1); while IFS= read -r -d '' kv; do export "\$kv"; done < /proc/\$P/environ
( POWOS_NO_LAUNCH_RECORD=1 setsid timeout 280 powos-open-task --app-id $app -- steam steam://rungameid/$app >/tmp/ans-$app.out 2>&1 </dev/null & )
pressed=0
for i in \$(seq 1 90); do
  w=\$(xdotool search --name '^Steam Dialog\$' 2>/dev/null | tail -1)
  if [ -n "\$w" ] && [ \$pressed -lt 4 ]; then sleep 2; xdotool windowactivate --sync "\$w" key --clearmodifiers Return 2>/dev/null; pressed=\$((pressed+1)); echo "pressed Enter on Steam Dialog \$w (\$pressed)"; sleep 3; continue; fi
  pgrep -f "reaper SteamLaunch AppId=$app" >/dev/null && { echo "game launch started after \$((i*2)) s (Enter pressed \$pressed x)"; break; }
  sleep 2
done
pgrep -f "reaper SteamLaunch AppId=$app" >/dev/null && echo LAUNCHED || echo "NO LAUNCH (dialog still: \$(xdotool search --name '^Steam Dialog\$' 2>/dev/null | wc -l))"
SH
out=$("$T/user.sh" "$O/a-$app.sh" 2>&1 | grep -v 'file pushed'); echo "$out" | tail -8
sleep 20; "$T/shot.sh" "$O/$app-$name-answered.png" >/dev/null 2>&1
printf '%s\n' "powos game $app stop >/dev/null 2>&1 || true" > "$O/s-$app.sh"; "$T/user.sh" "$O/s-$app.sh" >/dev/null 2>&1
echo "$out" | grep -q LAUNCHED && echo "PASS: $name's Steam notice answered, the game launched ($O/$app-$name-answered.png); closed again" || { echo "FAIL: $name didn't launch after answering"; exit 1; }

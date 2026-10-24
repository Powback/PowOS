#!/bin/bash
# lanes: phone
# tools/phone/verify/steam-dialogs/look.sh <appid> <name>: (Mac side, queue it) look only - launch a Steam game
# whose launch waits on a Steam dialog (EULA/notice), screenshot it, click nothing (the dialog is left up for
# answer.sh, its companion, as the next step).
set -u
here=$(cd "$(dirname "$0")" && pwd); T=$here/../..
app=$1; name=$2; O=$HOME/.cache/powos-verify/steam-dialogs; mkdir -p "$O"
cat > "$O/u-$app.sh" <<SH
P=\$(pgrep -x plasmashell | head -1); while IFS= read -r -d '' kv; do export "\$kv"; done < /proc/\$P/environ
( POWOS_NO_LAUNCH_RECORD=1 setsid timeout 240 powos-open-task --app-id $app -- steam steam://rungameid/$app >/tmp/dlg-$app.out 2>&1 </dev/null & )
for i in \$(seq 1 60); do xwininfo -root -tree 2>/dev/null | grep -q '"Steam Dialog"' && { echo "dialog after \$((i*2)) s"; break; }; sleep 2; done
xwininfo -root -tree 2>/dev/null | grep '"Steam Dialog"' | head -2
grep -E 'ShowInterstitials|EULA|eula' ~/.local/share/Steam/logs/console_log.txt 2>/dev/null | tail -3
SH
"$T/user.sh" "$O/u-$app.sh" 2>&1 | grep -v 'file pushed' | tail -8
sleep 3; "$T/shot.sh" "$O/$app-$name.png"
echo "PASS: looked at $name's Steam dialog ($O/$app-$name.png) - nothing clicked"

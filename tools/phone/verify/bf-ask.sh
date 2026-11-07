# lanes: phone
# bf-ask.sh: (in the PowOS session as powos; APP=<appid>) is Steam holding a launch of APP that waits on the user?
# Prints "ask <ActionID> <time> <what>" when the newest GameAction of APP in console_log ended on "LaunchApp waiting
# for user response to <what>" more than 5 s ago (Steam auto-continues ShowInterstitials/CreatingProcess within the
# same second), else "ask none". Such an action is never dropped: every later steam://rungameid/APP joins it and
# nothing starts until it is answered - ABZU 11-07 15:44 SynchronizingCloud "syncfailed" (cloud sync failed), then
# four verify launches 15:59-16:07 "no game window in 116 s" while gameprocess_log stayed silent. Its dialog is a
# nameless steamwebhelper window (no "Steam Dialog" caption), so powos-open-task never brings it forward.
L=$HOME/.local/share/Steam/logs/console_log.txt
line=$(tail -c 4194304 "$L" 2>/dev/null | grep -a "GameAction \[AppID ${APP:-274190}, ActionID " | tail -1)
case $line in *"LaunchApp waiting for user response to "*) ;; *) echo "ask none"; exit 0 ;; esac
t=$(printf '%s\n' "$line" | sed -nE 's/^\[([0-9-]+ [0-9:]+)\].*/\1/p')
id=$(printf '%s\n' "$line" | sed -nE 's/.*ActionID ([0-9]+)\].*/\1/p')
what=$(printf '%s\n' "$line" | sed -E 's/.*waiting for user response to //' | tr -d '\r' | cut -c1-80)
age=$(( $(date +%s) - $(date -d "$t" +%s 2>/dev/null || date +%s) ))
[ "$age" -gt 5 ] || { echo "ask none"; exit 0; }
echo "ask $id ${t#* } ${what}"

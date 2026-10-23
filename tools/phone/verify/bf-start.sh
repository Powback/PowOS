# bf-start.sh: (in the PowOS session as powos) keep Steam awake for the test and start Steam + the game (APP, default 274190) the
# way the drawer does - powos-open-task, so the game's window is shown as its own Android task in front. A bare
# `steam steam://rungameid/...` left the game's window as no task in front: bf-pacing measured PowOS's home
# ("in front: HomeShell", 2026-10-23). Without powos-open-task: Steam alone, as before.
mkdir -p /tmp/bflog
powos sleep never steam 2>&1 | tail -2
cd /home/powos
if command -v powos-open-task >/dev/null; then
  setsid -f powos-open-task --app-id steam_app_${APP:-274190} -- steam steam://rungameid/${APP:-274190} >/tmp/bflog/steam-start.out 2>&1 < /dev/null
else
  setsid -f steam steam://rungameid/${APP:-274190} >/tmp/bflog/steam-start.out 2>&1 < /dev/null
fi
echo started

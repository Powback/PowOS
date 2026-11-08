# lanes: phone
# bf-stop.sh [--steam]: (in the PowOS session as powos) close Broforce (APP=<appid>: that game) within ~3 s, and with --steam Steam too within
# ~10 s, and drop the never-sleep entry. Steam stays resident by default: out of sight it is frozen (unified sleep), so
# the next launch skips Steam's cold start; --steam only for cold-start checks.
# `powos game 274190 stop [--steam]` (lib/game.sh): the game's launch chains TERMed, KILLed after 2 s (also one a dead
# Steam left, ppid 1, and the prefix's wineserver); Steam thawed + asked to -shutdown, KILLed after 6 s. It never waits
# on a frozen or dying client (the old 40 s wait on -shutdown: "stuck closing Steam", 2026-10-23).
# Graceful: TERMed first, never KILLed while Steam's log shows its cloud sync; Steam's exit steps for it are awaited
# (<=20 s) before Steam is shut down - a stop mid-sync left a sync-conflict question that SKIPped every game check
# (11-08 03:20). A sync still running then: the game is left to Steam ("left to Steam", exit 4).
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
timeout 35 powos game "${APP:-274190}" stop ${1:+"$1"} 2>&1 | tail -2
timeout 5 powos sleep never --remove steam 2>&1 | tail -1
echo stopped

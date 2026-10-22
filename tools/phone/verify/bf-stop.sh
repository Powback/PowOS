# bf-stop.sh [--steam]: (in the PowOS session as powos) close Broforce within ~3 s, and with --steam Steam too within
# ~10 s, and drop the never-sleep entry. Steam stays resident by default: out of sight it is frozen (unified sleep), so
# the next launch skips Steam's cold start; --steam only for cold-start checks.
# `powos game 274190 stop [--steam]` (lib/game.sh): the game's launch chains TERMed, KILLed after 2 s (also one a dead
# Steam left, ppid 1, and the prefix's wineserver); Steam thawed + asked to -shutdown, KILLed after 6 s. It never waits
# on a frozen or dying client (the old 40 s wait on -shutdown: "stuck closing Steam", 2026-10-23).
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
timeout 20 powos game 274190 stop ${1:+"$1"} 2>&1 | tail -2
timeout 5 powos sleep never --remove steam 2>&1 | tail -1
echo stopped

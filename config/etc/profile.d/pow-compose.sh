# Interactive-shell wrapper so `docker compose up` transparently runs the
# pow-compose pre-flight collision check without users having to remember
# a second command name.
#
# HOW IT WORKS
# When you type `docker compose up`, bash checks for a function named `docker`
# before looking up the binary on PATH. This function catches the
# `compose up/start/restart/run` case and re-dispatches through pow-compose;
# every other docker command (ps, exec, inspect, image, logs, …) falls
# through unchanged. Non-interactive shells and scripts do not source
# /etc/profile.d, so automation still hits the raw docker binary — and
# pihole-sync's post-hoc auto-stop is the safety net there.
#
# LOOP AVOIDANCE
# pow-compose delegates to `docker compose` at the end. Because bash does not
# export function definitions to subshells by default, the child process
# that pow-compose forks sees the real /usr/bin/docker (or whatever's on
# PATH) — no infinite recursion.

# Only bother in interactive shells — this file gets sourced from login
# shells and non-interactive rc as well, and we do not want to silently
# wrap docker in cron/systemd/etc.
case $- in
    *i*) ;;
    *) return 0 ;;
esac

# Bail out if pow-compose is missing (e.g. mid-upgrade). Fall back to the
# raw docker CLI so the shell stays usable.
command -v pow-compose >/dev/null 2>&1 || return 0

docker() {
    if [ "$1" = "compose" ]; then
        shift  # drop the leading "compose"
        case "${1:-}" in
            up|start|restart|run)
                pow-compose "$@"
                return
                ;;
        esac
        command docker compose "$@"
    else
        command docker "$@"
    fi
}

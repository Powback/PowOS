#!/usr/bin/env bash
# progress.sh — a two-line progress footer pinned to the bottom of the console.
#
# WHY A SCROLL REGION AND NOT whiptail --gauge
# A gauge box clears the screen and owns it, which hides the installer's own
# output. The output is the thing you need when an install goes wrong, so the
# footer has to coexist with scrolling text rather than replace it. Setting the
# terminal's scroll region (DECSTBM) to everything-but-the-last-two-lines makes
# the kernel VT do exactly that: text scrolls above, the last two lines are
# ours and never move.
#
# WHAT THE TWO LINES SAY
#   line 1  the CURRENT step, with a live elapsed counter
#   line 2  OVERALL progress, as a bar plus a literal "step N/M"
#
# The elapsed counter is not decoration. The failure this is meant to answer is
# "is it frozen or is it working" — a Deck install sat on one step for minutes
# with a static screen, and there was no way to tell. A number that ticks says
# the machine is alive even when nothing else changes.
#
# WHY THERE IS NO PERCENTAGE
# There is no honest denominator. The whole-disk path — the common one — runs
# exactly ONE run_step: `bootc install`, which IS the install. A "step 1/9" bar
# would sit still for the entire run and lie about progress. The alongside path
# has more steps but they are wildly uneven (a mkfs is a second, bootc is
# minutes), so proportion-of-steps still does not mean proportion-of-time.
#
# So pass a total only if one genuinely exists. With total 0 the second line
# becomes an INDETERMINATE activity marker plus a plain step counter — it shows
# the machine is working without inventing a fraction. bootc draws its own
# byte-level bar in the scrolling area above, and that one has real numbers.
#
# The footer is written to /dev/tty, NOT stdout: the installer tees stdout to
# /tmp/powos-install.log, and escape sequences in a log file make it unreadable
# precisely when someone needs to read it.

PG_ACTIVE=0
PG_TOTAL=0
PG_CURRENT=0
PG_LABEL=""
PG_START=0
PG_TICK_PID=""
PG_TTY="${PG_TTY:-/dev/tty}"
# The ticker runs in a FORKED SUBSHELL, so it cannot see later assignments to
# PG_LABEL/PG_CURRENT — it would happily repaint the state as it was when it
# forked, i.e. "starting  step 0/N", straight over the live line once a second.
# (Observed: the footer flipped back to step 0 while step 4 was running.) So the
# state lives in a file that both sides read.
PG_STATE=""

# Usable only on a real terminal, and only when not explicitly disabled.
pg_available() {
    [[ "${POWOS_NO_PROGRESS:-0}" == "1" ]] && return 1
    [[ -w "$PG_TTY" ]] || return 1
    [[ -t 1 || -e "$PG_TTY" ]] || return 1
    command -v tput >/dev/null 2>&1 || return 1
    local r; r=$(pg__rows) || return 1
    (( r >= 8 ))                       # too short to spare two lines
}

pg__rows() { tput lines 2>/dev/null || stty size 2>/dev/null | cut -d' ' -f1; }
pg__cols() { tput cols  2>/dev/null || stty size 2>/dev/null | cut -d' ' -f2; }
pg__now()  { local s; read -r s _ < /proc/uptime 2>/dev/null && echo "${s%.*}" || echo 0; }

pg__bar() {   # $1=done $2=total $3=width -> "[####----]"
    local done=$1 total=$2 width=$3 filled
    (( total > 0 )) || total=1
    (( done < 0 )) && done=0
    (( done > total )) && done=$total
    filled=$(( done * width / total ))
    # `printf '#%.0s' $(seq 1 0)` prints ONE '#', because printf always walks
    # its format at least once even with no arguments. That put a filled block
    # in the bar at zero progress and made a full bar one char too wide, so
    # both empty cases are handled explicitly.
    local f="" e="" empty=$(( width - filled ))
    (( filled > 0 )) && f=$(printf '#%.0s' $(seq 1 "$filled"))
    (( empty  > 0 )) && e=$(printf '.%.0s' $(seq 1 "$empty"))
    printf '[%s%s]' "$f" "$e"
}

pg__state_save() {
    [[ -n "$PG_STATE" ]] || return 0
    printf '%s\t%s\t%s\t%s\n' "$PG_CURRENT" "$PG_TOTAL" "$PG_START" "$PG_LABEL" \
        > "$PG_STATE" 2>/dev/null || true
}
pg__state_load() {
    [[ -r "$PG_STATE" ]] || return 0
    local c t st lb
    IFS=$'\t' read -r c t st lb < "$PG_STATE" 2>/dev/null || return 0
    [[ "$c"  =~ ^[0-9]+$ ]] && PG_CURRENT=$c
    [[ "$t"  =~ ^[0-9]+$ ]] && PG_TOTAL=$t
    [[ "$st" =~ ^[0-9]+$ ]] && PG_START=$st
    PG_LABEL="$lb"
}

# An indeterminate marker: one cell sweeping back and forth. Conveys "alive",
# claims no proportion.
pg__marker() {
    local width=$1 t=$2 span pos i out=""
    (( width < 4 )) && width=4
    span=$(( width - 1 )); (( span < 1 )) && span=1
    pos=$(( t % (span * 2) )); (( pos >= span )) && pos=$(( span * 2 - pos ))
    for (( i = 0; i < width; i++ )); do
        if (( i == pos )); then out="$out#"; else out="$out."; fi
    done
    printf '[%s]' "$out"
}

pg__draw() {
    (( PG_ACTIVE )) || return 0
    pg__state_load
    local rows cols elapsed bar1 bar2 line1 line2
    rows=$(pg__rows); cols=$(pg__cols); [[ -n "$cols" ]] || cols=80
    elapsed=$(( $(pg__now) - PG_START )); (( elapsed < 0 )) && elapsed=0

    # Current step: an elapsed counter, because the question being answered is
    # "is this alive", which a percentage cannot answer for a single step.
    line1=$(printf '  %-*s %4ds' $(( cols - 12 )) "${PG_LABEL:0:$(( cols - 14 ))}" "$elapsed")

    local width=$(( cols > 40 ? cols - 24 : 16 ))
    if (( PG_TOTAL > 0 )); then
        # A real denominator exists: clamp below full until pg_finish.
        local shown=$PG_CURRENT
        (( shown >= PG_TOTAL && PG_ACTIVE == 1 )) && shown=$(( PG_TOTAL - 1 ))
        bar2=$(pg__bar "$shown" "$PG_TOTAL" "$width")
        line2=$(printf '  %s step %d/%d' "$bar2" "$PG_CURRENT" "$PG_TOTAL")
    else
        # No denominator: an activity marker that moves with elapsed time, so it
        # is visibly alive without claiming a fraction it cannot know.
        bar2=$(pg__marker "$width" "$elapsed")
        line2=$(printf '  %s step %d  %s' "$bar2" "$PG_CURRENT" "working")
    fi

    {   printf '\0337'                                  # save cursor (DECSC)
        printf '\033[%d;1H\033[2K%s' $(( rows - 1 )) "$line1"
        printf '\033[%d;1H\033[2K%s' "$rows"           "$line2"
        printf '\0338'                                  # restore cursor (DECRC)
    } > "$PG_TTY" 2>/dev/null || true
}

# Redraw once a second so the elapsed counter ticks during a long step.
pg__tick_start() {
    pg__tick_stop
    ( while :; do sleep 1; pg__draw; done ) >/dev/null 2>&1 &
    PG_TICK_PID=$!
}
pg__tick_stop() {
    [[ -n "$PG_TICK_PID" ]] || return 0
    kill "$PG_TICK_PID" 2>/dev/null || true
    wait "$PG_TICK_PID" 2>/dev/null || true
    PG_TICK_PID=""
}

pg_begin() {   # $1 = estimated total steps
    PG_TOTAL="${1:-0}"; PG_CURRENT=0; PG_LABEL="starting"; PG_START=$(pg__now)
    pg_available || { PG_ACTIVE=0; return 0; }
    PG_STATE=$(mktemp 2>/dev/null) || PG_STATE=""
    pg__state_save
    local rows; rows=$(pg__rows)
    printf '\n\n' > "$PG_TTY" 2>/dev/null || true     # room for the footer
    printf '\0337\033[1;%dr\0338' $(( rows - 2 )) > "$PG_TTY" 2>/dev/null || true
    PG_ACTIVE=1
    pg__draw
    pg__tick_start
}

pg_step() {    # $1 = label
    PG_LABEL="${1:-}"
    PG_CURRENT=$(( PG_CURRENT + 1 ))
    PG_START=$(pg__now)
    pg__state_save
    pg__draw
}

pg_finish() {  # release the bottom lines and restore full-screen scrolling
    pg__tick_stop
    (( PG_ACTIVE )) || { PG_ACTIVE=0; return 0; }
    PG_ACTIVE=2                                    # allow the bar to reach full
    PG_CURRENT=$PG_TOTAL; PG_LABEL="done"
    pg__state_save
    pg__draw
    local rows; rows=$(pg__rows)
    {   printf '\0337\033[r\0338'                  # reset scroll region
        printf '\033[%d;1H\033[2K' $(( rows - 1 ))
        printf '\033[%d;1H\033[2K' "$rows"
        printf '\033[%d;1H' $(( rows - 2 ))
    } > "$PG_TTY" 2>/dev/null || true
    [[ -n "$PG_STATE" ]] && rm -f "$PG_STATE" 2>/dev/null
    PG_STATE=""
    PG_ACTIVE=0
}

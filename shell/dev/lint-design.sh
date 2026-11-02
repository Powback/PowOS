#!/bin/bash
# The design language's static check (docs/DESIGN-LANGUAGE.md §2-§6): prints what breaks a rule, per file. Four rules
# BLOCK (design wave 1 made them hold: exit 1 on any hit) - monospace, radius, easing, status - and design wave 2 (home)
# added three more: page dots, haptics, home motion; design wave 3 (launcher) launcher motion; the rest report only.
# Outside theme.css:
#   - monospace: a rule naming var(--font) (theme.css's monospace) - UI text is --font-ui; code/terminals excepted
#     (terminal.*, a selector with term/code/pre/kbd/log/id in it);
#   - blur: a literal blur(Npx) / backdrop-filter radius - surfaces read --backdrop-blur-native / --glass-blur;
#   - radius: a border-radius off the scale (8px, var(--radius) 12px, 20px, 999px, 50%, inherit, 0, --icon-radius);
#   - easing: a transition/animation with its own cubic-bezier()/ease, or a local spring (--ais-spring, --aip-spring),
#     instead of the spring set (--spring-fast / --spring / --spring-slow, ui/spring.ts; loops on --ambient);
#   - status: a status colour of its own (the old --aip-blue / --aip-amber, their hex) instead of theme.css --status-*;
#   - page dots: a page indicator of its own (dots with an "on" state: `<i class={... ? "on"`, a `.x-dots i.on` rule)
#     instead of ui/pagedots.tsx PageDots - home had two rows at its foot, the dock's and its own (§1: one row);
#   - haptics: navigator.vibrate() outside ui/haptics.ts - the host's tick()/confirm() are the one feel (§7; the
#     WebView's vibrate is silent on the phone, home's long presses had no haptic at all);
#   - home motion: a transition with a literal duration (120ms...) in a rule for home's pieces (.dock, .app, .home,
#     .page, .home-tile, .page-dots, .app-icon) instead of the spring set's --spring*-ms (§6);
#   - launcher motion (design wave 3): the same for the launcher's pieces (.launcher*, .drawer*, .letter-bar, .az,
#     .scr-*, .search-group*) - its letter bar's colour (160ms) and A-Z grid's background (120ms) were literal.
#
#   shell/dev/lint-design.sh [DIR]   DIR: the shell (default: this one). Exit 1: a blocking rule broken.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
S=${1:-$here/..}
cd "$S" || exit 0
css=$(ls ui/*.css 2>/dev/null)
code=$(ls ui/*.css ui/*.tsx ui/*.ts 2>/dev/null)
# Lines that are prose (comments) are skipped.
strip() { grep -vE '^[^:]+:[0-9]+:[[:space:]]*(/\*|\*|//)'; }
report() { # kind, hits
  local kind=$1 hits=$2 n
  n=$(printf '%s' "$hits" | grep -c . || true)
  echo "     design-lint $kind: $n"
  [ "$n" = 0 ] || printf '%s\n' "$hits" | awk -F: '{c[$1]++} END {for (f in c) printf "       %4d %s\n", c[f], f}' | sort -rn | head -12
}
mono=$(grep -nE 'var\(--font\)|monospace' $css 2>/dev/null | strip | grep -vE '^ui/terminal|term|code|pre[ ,{.]|kbd|\.log|-id[ ,{]|font-ui' || true)
blur=$(grep -nE '(backdrop-filter|filter)[^;]*blur\([0-9.]+px\)' $code 2>/dev/null | strip | grep -v '^ui/pet' || true)
radius=$(grep -noE 'border-radius: *[^;"}]+' $css 2>/dev/null | grep -vE 'border-radius: *(0|8px|12px|20px|999px|50%|inherit|var\(--radius\)|var\(--icon-radius\)|var\(--card-radius\))( |$)' || true)
easing=$( { grep -nE '(transition|animation)[^;]*(cubic-bezier\(|[0-9]m?s +ease)' $css 2>/dev/null | strip | grep -v -- '--spring'
  grep -nE -- '--ai[sp]-spring' $code 2>/dev/null | strip; } || true)
status=$(grep -niE -- '--aip-(blue|amber|on-amber)|#5aa7e8|#e3a03c|#1a1206' $code 2>/dev/null | strip || true)
dots=$( { grep -nE '<i class=\{[^}]*\? *"on"' ui/*.tsx 2>/dev/null; grep -nE -- '-dots +i\.on' $css 2>/dev/null | grep -v '\.page-dots'; } | strip || true)
vibrate=$(grep -nE 'navigator\.vibrate' ui/*.ts ui/*.tsx *.ts *.tsx 2>/dev/null | grep -vE '^(ui/haptics|bridge)\.ts:' | strip || true)
# literal_motion <selector regex>: shell.css lines in a rule whose selector matches it with a transition/animation
# taking a literal duration (not var(--spring*), not a loop on --ambient, not a 0s switch such as visibility's). Any
# literal in the declaration counts:
# "transform var(--spring-fast-ms) var(--spring-fast), color 160ms" breaks it with its color.
literal_motion() {
  awk -v want="$1" '
  /\{/ { sel = $0; sub(/\{.*/, "", sel); if (sel ~ /^[ \t]*$/) sel = last }
  { d = $0; gsub(/var\(--[a-z-]+\)/, "", d); gsub(/ 0m?s/, "", d)
    if ($0 !~ /^[ \t]*(\/\*|\*)/ && d ~ /(transition|animation)(-duration)?:[^;]*[^a-z-][0-9.]+m?s([ ,;]|$)/ && $0 !~ /infinite|var\(--ambient\)/ && sel ~ want) printf "%s:%d:%s\n", FILENAME, FNR, $0 }
  /\}/ { last = sel = "" }
  { if ($0 ~ /\{/ && $0 !~ /\}/) last = sel }
  ' ui/shell.css 2>/dev/null || true
}
homemotion=$(literal_motion '\\.(dock|app|home|page|home-tile|page-dots|app-icon)([^a-z-]|$)')
# The launcher's pieces (design wave 3): the drawer, its A-Z grid and letter bar, the search results, the folders page.
launchermotion=$(literal_motion '\\.(launcher|launcher-[a-z]+|drawer|drawer-[a-z]+|letter-bar|letter-bubble|az|scr-[a-z]+|search-group|search-group-[a-z]+|launcher-search-results)([^a-z-]|$)')
count() { printf '%s' "$1" | grep -c . || true; }
bad=$(( $(count "$mono") + $(count "$radius") + $(count "$easing") + $(count "$status") + $(count "$dots") + $(count "$vibrate") + $(count "$homemotion") + $(count "$launchermotion") ))
if [ "$bad" = 0 ]; then echo "ok   design lint (docs/DESIGN-LANGUAGE.md)"; else echo "FAIL design lint: $bad blocking (docs/DESIGN-LANGUAGE.md)"; fi
report "monospace in UI" "$mono"
report "radius off the scale" "$radius"
report "easing not the shared spring" "$easing"
report "status colour not a --status-* token" "$status"
report "page dots not ui/pagedots.tsx" "$dots"
report "haptic not ui/haptics.ts" "$vibrate"
report "home motion with a literal duration" "$homemotion"
report "launcher motion with a literal duration" "$launchermotion"
report "hard-coded blur (report-only)" "$blur"
[ "$bad" = 0 ]

#!/bin/bash
# The design language's static report (docs/DESIGN-LANGUAGE.md §2-§6), REPORT-ONLY for now: prints what breaks a rule,
# per file, and always exits 0 (the manager turns it into a failure once the gaps are fixed). Outside theme.css:
#   - monospace: a rule naming var(--font) (theme.css's monospace) - UI text is --font-ui; code/terminals excepted
#     (terminal.*, a selector with term/code/pre/kbd/log/id in it);
#   - blur: a literal blur(Npx) / backdrop-filter radius - surfaces read --backdrop-blur-native / --glass-blur;
#   - radius: a border-radius off the scale (8px, var(--radius) 12px, 20px, 999px, 50%, inherit, 0, --icon-radius);
#   - easing: a transition/animation with its own cubic-bezier()/ease instead of var(--spring) (ui/spring.ts).
#
#   shell/dev/lint-design.sh [DIR]   DIR: the shell (default: this one). Always exit 0.
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
easing=$(grep -nE '(transition|animation)[^;]*(cubic-bezier\(|[0-9]m?s +ease)' $css 2>/dev/null | strip | grep -v -- '--spring' || true)
echo "ok   design lint (report-only: docs/DESIGN-LANGUAGE.md)"
report "monospace in UI" "$mono"
report "hard-coded blur" "$blur"
report "radius off the scale" "$radius"
report "easing not the shared spring" "$easing"
exit 0

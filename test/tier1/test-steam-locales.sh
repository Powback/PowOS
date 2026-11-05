#!/bin/bash
# test-steam-locales.sh - Tier-1 tests for /usr/bin/steam's steam_locales (targets/android/pkgs/steam/steam): the session's
# locales compiled once into a kept LOCPATH, so pressure-vessel's pv-locale-gen has nothing to generate at a game launch
# (3.6 s of localedef under FEX every x86 Proton launch, 2026-11-05). Fake localedef + i18n tree.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ST="$SCRIPT_DIR/../../targets/android/pkgs/steam/steam"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }
echo "== test-steam-locales.sh =="

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/i18n"
for l in en_US de_CH de_DE fr_CH pt_PT pt_BR ga_IE; do : > "$T/i18n/$l"; done
# localedef stub: logs its -i, writes <out>/LC_CTYPE; "bad" sources exit 4 with nothing written (as the real one).
cat > "$T/bin/localedef" <<'S'
#!/bin/bash
i=; for a; do [ "$p" = -i ] && i=$a; p=$a; done; out=${!#}
echo "$i" >> "$LOG"
[ "$i" = de_DE ] && exit 4
mkdir -p "$out" && : > "$out/LC_CTYPE"; exit 1
S
cat > "$T/bin/getconf" <<'S'
#!/bin/sh
echo "glibc 2.43"
S
chmod +x "$T/bin/localedef" "$T/bin/getconf"
sed -n '/^steam_locales() {/,/^if \[ "\${POWOS_STEAM_LOCALES/p' "$ST" | sed '$d' > "$T/fn.sh"
check "the functions are in /usr/bin/steam" "grep -q '^steam_locale()' '$T/fn.sh'"

run() { env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" LOG="$T/log" POWOS_I18N_LOCALES="$T/i18n" "$@" \
  bash -c ". '$T/fn.sh'; steam_locales; echo \"\${LOCPATH:-none}\""; }
D=$T/home/.cache/powos/steam-locales/glibc2.43
out=$(run LANG=en_CH.UTF-8 LC_TIME=fr_CH.UTF-8 LC_NUMERIC=C)
check "LOCPATH is the kept dir, per glibc" "[ '$out' = '$D' ]"
check "en_US.UTF-8 compiled (pv-locale-gen always wants it)" "[ -f '$D/en_US.UTF-8/LC_CTYPE' ]"
check "a locale glibc has no source for (en_CH) points at its language's" "[ \"\$(readlink '$D/en_CH.UTF-8')\" = en_US.UTF-8 ]"
check "LC_* values are compiled too" "[ -f '$D/fr_CH.UTF-8/LC_CTYPE' ]"
check "C / C.UTF-8 are skipped (glibc's own)" "! grep -qx C '$T/log' && [ ! -e '$D/C' ]"
check "no temp dirs left" "[ -z \"\$(ls -A '$D' | grep '^\\.new')\" ]"
: > "$T/log"; run LANG=en_CH.UTF-8 LC_TIME=fr_CH.UTF-8 >/dev/null
check "second start compiles nothing" "[ ! -s '$T/log' ]"
run LANG=pt_XX.UTF-8 LC_TIME=ga_XX.UTF-8 >/dev/null
check "unknown territory -> the language's own (pt -> pt_PT)" "[ \"\$(readlink '$D/pt_XX.UTF-8')\" = pt_PT.UTF-8 ]"
check "no language's own -> its first (ga -> ga_IE)" "[ \"\$(readlink '$D/ga_XX.UTF-8')\" = ga_IE.UTF-8 ]"
run LANG=de_AT.UTF-8 >/dev/null
check "a failed localedef keeps nothing (no symlink to a missing dir)" "[ ! -e '$D/de_DE.UTF-8' ] && [ ! -L '$D/de_AT.UTF-8' ]"
run LANG=ja_JP.EUC-JP >/dev/null
check "non-UTF-8 locales are left to pressure-vessel" "[ ! -e '$D/ja_JP.EUC-JP' ]"
rm -rf "$T/home"; out=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" LOG="$T/log" POWOS_I18N_LOCALES="$T/empty" LANG=en_US.UTF-8 \
  bash -c ". '$T/fn.sh'; steam_locales; echo \"\${LOCPATH:-none}\"")
check "no i18n sources: no LOCPATH (pressure-vessel as before)" "[ '$out' = none ]"
check "the call is guarded (POWOS_STEAM_LOCALES=0, a LOCPATH set, no localedef)" \
  "grep -q 'POWOS_STEAM_LOCALES:-1}\" != 0 \\] && \\[ -z \"\${LOCPATH:-}\" \\] && command -v localedef' '$ST'"
echo "steam-locales: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

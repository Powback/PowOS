#!/usr/bin/env bash
# The image trim must stay honest about what it removes and what it must not.
#
# It takes ~530 MB off the DEPLOYED system by deleting base-image bulk PowOS
# never adds. It does NOT shrink the download: the build runs --layers with no
# squash, so a delete is a whiteout in a new layer while the bytes stay in the
# base layer and are still fetched. Anyone re-measuring the ~7 GB first pull
# and finding it unchanged is seeing correct behaviour, not a broken trim.
#
# Three things must survive, and each is a separate tree that is easy to fold
# in by accident:
#   /usr/share/licenses  separate from /usr/share/doc; license texts must stay
#   /usr/share/locale    pruning to English would drop nb_NO with it
#   /usr/share/fonts     mostly Noto CJK, which renders JP/CN Steam titles
set -uo pipefail
PASS=0; FAIL=0
check() { if ( eval "$2" ) >/dev/null 2>&1; then echo "  ok   - $1"; PASS=$((PASS+1));
          else echo "  FAIL - $1"; FAIL=$((FAIL+1)); fi }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF="$HERE/../../Containerfile"
TRIM=$(sed -n '/^RUN set -eu; \\$/,/^    echo "trim:/p' "$CF")

echo "== image trim =="
check "the Containerfile has a trim block"       '[[ -n "$TRIM" ]]'
check "it removes /usr/share/doc"                'grep -q "rm -rf /usr/share/doc" <<< "$TRIM"'
check "it removes man and help"                  'grep -q "/usr/share/man /usr/share/help" <<< "$TRIM"'

# The must-survive set.
check "it does NOT delete /usr/share/licenses"   '! grep -qE "rm -rf[^;]*licenses" <<< "$TRIM"'
check "it ASSERTS licenses survived"             'grep -q "licenses was removed" <<< "$TRIM"'
check "it does NOT touch /usr/share/locale"      '! grep -qE "rm -rf[^;]*locale" <<< "$TRIM"'
check "it does NOT touch /usr/share/fonts"       '! grep -qE "rm -rf[^;]*fonts" <<< "$TRIM"'

# Wallpapers: trimmed to the referenced set, never emptied wholesale.
check "the wallpaper keep-list is DERIVED, not hardcoded" \
      'grep -q "look-and-feel" <<< "$TRIM"'
check "an empty keep-list fails the build instead of deleting everything" \
      'grep -q "keep-list is EMPTY" <<< "$TRIM"'
check "it never rm -rf's the whole wallpapers tree" \
      '! grep -qE "rm -rf[[:space:]]+/usr/share/wallpapers([[:space:]]|$)" <<< "$TRIM"'
check "it only walks DIRECTORIES, leaving loose branding files alone" \
      'grep -q "wallpapers/\*/" <<< "$TRIM"'

# A broken continuation would make the RUN silently do the wrong thing, so the
# body must parse. Separately, it must still be MULTI-LINE: an edit once
# collapsed the whole block onto a single unreadable line (a Python
# line-continuation ate the backslash-newlines) and stayed valid shell, so
# parsing alone would not have noticed.
check "the trim block is still multi-line, not collapsed" \
      '[[ $(grep -c . <<< "$TRIM") -gt 8 ]]'
check "the trim body is valid shell" \
      'printf "%s" "$TRIM" | sed "1s/^RUN //" | perl -0777 -pe "s/\\\\\\\\\n\s*/ /g" | bash -n'

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]

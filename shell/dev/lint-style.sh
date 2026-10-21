#!/bin/bash
# The design language's style lint (docs/DESIGN-LANGUAGE.md §2, §4): in the shell's CSS and TSX, outside the token
# file (theme.css), it fails
#   - a raw colour: #hex, rgb()/rgba(), hsl()/hsla() - colours come from the theme's tokens;
#   - a border or an outline drawn in a colour (a width and a colour other than transparent / --line): no hard lines;
#   - a box-shadow that isn't the tokens (--lift*, none) or a ring in a theme colour (0 0 0 Npx var(--color-*)).
# Justified exceptions are listed in dev/style-allow.txt: "<file> <text on the line>  # why" - the line matches when
# it contains that text, so an exception survives the file moving around it.
#
#   shell/dev/lint-style.sh [DIR]     DIR: the shell to check (default: this one). Exit 0 clean, 1 with findings.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
S=${1:-$here/..}
allow=$here/style-allow.txt
cd "$S" || exit 2
files=$(ls ui/*.css ui/*.tsx ui/*.ts app.tsx apps/*.ts 2>/dev/null)
found=0
check() { # kind regex
  local kind=$1 re=$2
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    f=${hit%%:*}; rest=${hit#*:}; n=${rest%%:*}; line=${rest#*:}
    # Comments are prose.
    case "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" in /\**|\**|//*) continue ;; esac
    ok=0
    if [ -f "$allow" ]; then
      while IFS= read -r a; do
        a=${a%%  #*}; [ -n "$a" ] || continue; case "$a" in \#*) continue ;; esac
        af=${a%% *}; at=${a#* }
        [ "$af" = "$f" ] && [[ "$line" == *"$at"* ]] && { ok=1; break; }
      done < "$allow"
    fi
    [ $ok = 1 ] && continue
    echo "FAIL style: $f:$n: $kind: $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-140)"
    found=1
  done < <(grep -nE "$re" $files /dev/null 2>/dev/null)
}
check "raw colour" '#[0-9a-fA-F]{3,8}([^0-9a-zA-Z_-]|$)|rgba?\(|hsla?\('
check "a line (border/outline)" '(border(-(top|right|bottom|left))?|outline)[[:space:]]*:[[:space:]]*[^;]*[1-9][0-9.]*px[^;]*(solid|dashed|dotted)[^;]*(var\(--color|#|rgb|hsl|currentColor)'
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  f=${hit%%:*}; rest=${hit#*:}; n=${rest%%:*}; line=${rest#*:}
  v=$(printf '%s' "$line" | sed -E 's/.*box-shadow[[:space:]]*:[[:space:]]*//; s/[;}].*//; s/ *!important//')
  # Strip the allowed parts; whatever's left is a shadow of its own.
  left=$(printf '%s' "$v" | sed -E 's/var\(--lift[a-z-]*\)//g; s/none//g; s/(inset )?0 0 0 [0-9.]+px var\(--color-[a-z]+\)//g; s/(inset )?0 0 0 var\(--frame\) var\(--color-[a-z]+\)//g; s/[ ,]//g')
  [ -z "$left" ] && continue
  case "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" in /\**|\**|//*) continue ;; esac
  ok=0
  if [ -f "$allow" ]; then
    while IFS= read -r a; do
      a=${a%%  #*}; [ -n "$a" ] || continue; case "$a" in \#*) continue ;; esac
      af=${a%% *}; at=${a#* }
      [ "$af" = "$f" ] && [[ "$line" == *"$at"* ]] && { ok=1; break; }
    done < "$allow"
  fi
  [ $ok = 1 ] && continue
  echo "FAIL style: $f:$n: box-shadow outside the tokens: $v"
  found=1
done < <(grep -nE 'box-shadow[[:space:]]*:|boxShadow:' $files /dev/null 2>/dev/null | sed -E 's/boxShadow:[[:space:]]*"([^"]*)"/box-shadow: \1;/')
[ $found = 0 ] && echo "ok   style lint" || true
exit $found

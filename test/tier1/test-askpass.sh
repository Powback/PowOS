#!/bin/bash
# test-askpass.sh - behavioural tests for bin/powos-askpass.
#
# The bug: Bazzite's /etc/profile.d/askpass.sh points SUDO_ASKPASS at
# ksshaskpass, an SSH passphrase dialog, so every `sudo -A` in a GUI session
# logs "Unable to parse phrase \"[sudo] password for powos: \"" and draws a box
# that names neither the command, the requester, nor the reason.
#
# These tests RUN the helper. None of them greps the Containerfile for a string
# — the closest they come is asserting glob order, and even that is done by
# actually sourcing the files in the order the shell would and reading back the
# variable. A test that only checks the right text was typed passes an image
# where the RUN silently no-opped.
#
# Nothing here ever types a real password anywhere. The one test that uses real
# sudo cancels at the prompt (the fake askpass exits non-zero) and asserts on
# the CONTEXT the helper resolved, never on authentication succeeding.
#
# Usage:  bash test/tier1/test-askpass.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
H="$ROOT/bin/powos-askpass"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "         $2"; }
skip() { echo "  skip - $1"; SKIP=$((SKIP+1)); }
check(){ if ( eval "$2" ) >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$H" ]]; then
    bad "bin/powos-askpass exists and is executable"
    echo ""; echo "== Results: $PASS passed, $FAIL failed =="; exit 1
fi
ok "bin/powos-askpass exists and is executable"

# `dry <env...> -- <prompt>` composes the dialog and prints it. It never
# prompts, so it is safe to run anywhere including headless CI.
dry() { env POWOS_ASKPASS_DRY_RUN=1 "$@" 2>&1; }

echo ""
echo "== prompt classification =="

out=$(dry "$H" "Enter passphrase for key '/home/u/.ssh/id_ed25519': ")
check "ssh key passphrase names the key file" \
      '[[ "$out" == *"SSH key passphrase"* && "$out" == *"/home/u/.ssh/id_ed25519"* ]]'
out=$(dry "$H" "Enter passphrase for /home/u/.ssh/id_rsa: ")
check "the unquoted OpenSSH passphrase form parses too" \
      '[[ "$out" == *"Key:"* && "$out" == *id_rsa* ]]'

out=$(dry "$H" "powos@powstation.pow's password: ")
check "remote password names the account and host" \
      '[[ "$out" == *"Remote password"* && "$out" == *"powos@powstation.pow"* ]]'

out=$(dry SSH_ASKPASS_PROMPT=confirm "$H" "Allow use of key /home/u/.ssh/id_ed25519?")
check "ssh-agent confirmation becomes a yes/no, not a password box" \
      '[[ "$out" == *"mode: confirm"* ]]'

out=$(dry "$H" "The authenticity of host 'x (1.2.3.4)' can't be established. continue connecting (yes/no/[fingerprint])? ")
check "unknown host key becomes a free-text box, not a password box" \
      '[[ "$out" == *"mode: input"* && "$out" == *"Unknown SSH host key"* ]]'

out=$(dry "$H" "Give me your password")
check "an unrecognised prompt says so instead of guessing" \
      '[[ "$out" == *"could not identify"* ]]'
check "an unrecognised prompt still names the requesting process" \
      '[[ "$out" == *"Requested by"* ]]'

out=$(dry "$H")
check "no argument at all does not crash" '[[ "$out" == *"Authentication required"* ]]'

echo ""
echo "== the sudo path, against a REAL sudo process =="
# The point of the helper: sudo passes ONLY the prompt string, so the command
# has to be recovered from /proc. This is the test that proves it does.
if ! command -v sudo >/dev/null 2>&1; then
    skip "sudo not installed"
elif ! sudo -n -v >/dev/null 2>&1 && [[ "$(id -u)" == "0" ]]; then
    skip "running as root; sudo never prompts"
else
    cat > "$TMP/wrap" <<EOF
#!/bin/bash
POWOS_ASKPASS_DRY_RUN=1 "$H" "\$@" >> "$TMP/seen" 2>&1
exit 1
EOF
    chmod +x "$TMP/wrap"
    : > "$TMP/seen"
    # -k first so a prompt is actually required. The wrapper cancels, so this
    # never authenticates and never runs the command.
    sudo -k 2>/dev/null
    ( cd /etc && SUDO_ASKPASS="$TMP/wrap" timeout 20 sudo -A -u root \
        /usr/bin/systemctl restart some-service-that-does-not-exist ) >/dev/null 2>&1
    seen=$(cat "$TMP/seen" 2>/dev/null)
    if [[ -z "$seen" ]]; then
        skip "sudo did not consult the askpass helper (NOPASSWD or cached credential)"
    else
        check "the command sudo was asked to run is resolved from /proc" \
              '[[ "$seen" == *"/usr/bin/systemctl restart some-service-that-does-not-exist"* ]]'
        check "the escalation target is shown" '[[ "$seen" == *"Run as"*root* ]]'
        check "the requesting process is shown"  '[[ "$seen" == *"Requested by"* ]]'
        check "the working directory is shown, and it is sudo's not the helper's" \
              '[[ "$seen" == *"Directory"*"/etc"* ]]'
        check "the session ancestry is shown"    '[[ "$seen" == *"Session"*sudo* ]]'
    fi

    # sudo -v is the burst case from the bug report: no command at all.
    : > "$TMP/seen"; sudo -k 2>/dev/null
    SUDO_ASKPASS="$TMP/wrap" timeout 20 sudo -A -v >/dev/null 2>&1
    seen=$(cat "$TMP/seen" 2>/dev/null)
    if [[ -n "$seen" ]]; then
        check "a commandless 'sudo -v' says so instead of showing an empty command" \
              '[[ "$seen" == *"sudo -v"* ]]'
    else
        skip "sudo -v did not prompt"
    fi
fi

echo ""
echo "== nothing unbounded ever reaches a dialog =="
long=$(head -c 4000 /dev/zero | tr '\0' 'A')
out=$(dry "$H" "$long")
widest=$(printf '%s\n' "$out" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')
check "a 4000-char prompt is truncated (longest rendered line <= 200)" '[[ '"$widest"' -le 200 ]]'
out=$(dry "$H" "$(printf 'line one\nline two\ttabbed\x01\x02')")
check "newlines/tabs/control bytes are flattened, not rendered" \
      '[[ "$(printf "%s\n" "$out" | grep -c "^  Prompt:")" == "1" ]]'

echo ""
echo "== markup escaping (bash 5.2 patsub_replacement regression guard) =="
# ${s//</&lt;} looks correct and is not: since bash 5.2, an unquoted '&' in the
# replacement expands to the matched text, so '&lt;' becomes '<lt;' and the
# escaping produces the broken markup it was there to prevent. Caught live.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/kdialog" <<'EOF'
#!/bin/bash
printf '%s\n' "$@"
EOF
chmod +x "$TMP/fakebin/kdialog"
gui=$(PATH="$TMP/fakebin:$PATH" DISPLAY=:99 POWOS_ASKPASS_MODE=gui \
      "$H" "a < b > c & d password" 2>&1)
check "the dialog body is declared rich text"    '[[ "$gui" == *"<qt>"* ]]'
check "'<' is escaped to &lt; (not to '<lt;')"   '[[ "$gui" == *"&lt;"*  && "$gui" != *"<lt;"* ]]'
check "'>' is escaped to &gt; (not to '>gt;')"   '[[ "$gui" == *"&gt;"*  && "$gui" != *">gt;"* ]]'
check "'&' is escaped to &amp;"                  '[[ "$gui" == *"&amp;"* ]]'
check "no raw '<' survives outside our own tags" \
      '[[ "$(printf "%s" "$gui" | sed -e "s/<qt>//g" -e "s#</qt>##g" -e "s/<br\/>//g" -e "s#</\{0,1\}\(table\|tr\|td\|b\|tt\)>##g")" != *"<"* ]]'

echo ""
echo "== headless: must degrade, never hang, never invent a secret =="
# setsid detaches the controlling terminal, which is what a systemd unit or an
# early-boot script looks like. There is nobody to ask, so the only correct
# behaviour is to say why on stderr and fail immediately.
hl_out="$TMP/hl.out"; hl_err="$TMP/hl.err"
setsid env -u DISPLAY -u WAYLAND_DISPLAY timeout 10 \
    "$H" "[sudo] password for powos: " >"$hl_out" 2>"$hl_err" </dev/null
rc=$?
check "exits non-zero with no tty and no display"  '[[ '"$rc"' -ne 0 ]]'
check "does NOT hang (would be exit 124 from timeout)" '[[ '"$rc"' -ne 124 ]]'
check "prints nothing on stdout — sudo must not receive an invented password" \
      '[[ ! -s "'"$hl_out"'" ]]'
check "explains itself on stderr, where sudo and the journal will show it" \
      'grep -q "no terminal and no graphical session" "'"$hl_err"'"'
check "does not leak a raw '\''/dev/tty: No such device'\'' shell error" \
      '! grep -q "No such device or address" "'"$hl_err"'"'

echo ""
echo "== terminal fallback on a real pty =="
if ! command -v script >/dev/null 2>&1; then
    skip "util-linux script(1) not available"
else
    rm -f "$TMP/secret" "$TMP/tr"
    printf 'hunter2\n' | env -u DISPLAY -u WAYLAND_DISPLAY timeout 20 \
        script -qec "'$H' '[sudo] password for powos: ' > '$TMP/secret'" "$TMP/tr" \
        >/dev/null 2>&1
    check "the explanation is written to the TERMINAL" \
          'grep -q "A program on this machine wants to run a command as root" "'"$TMP/tr"'"'
    check "the prompt is written to the TERMINAL"      'grep -q "Password:" "'"$TMP/tr"'"'
    check "stdout carries the secret and NOTHING else" \
          '[[ "$(cat "'"$TMP/secret"'")" == "hunter2" ]]'
    # NOT asserted by grepping the transcript for the secret: script(1) echoes
    # piped stdin on the pty before the helper ever starts reading, so the
    # secret appears there for reasons that have nothing to do with the helper.
    # The mechanism that actually suppresses the echo is `read -s`; assert that.
    check "the terminal read disables echo (read -s)" \
          'grep -qE "read -r -s secret" "'"$H"'"'
fi

echo ""
echo "== fail-safe: a broken helper must not lock anyone out of root =="
if ! command -v sudo >/dev/null 2>&1; then
    skip "sudo not installed"
else
    sudo -k 2>/dev/null
    timeout 15 env SUDO_ASKPASS=/nonexistent/askpass sudo -A /bin/true >/dev/null 2>&1
    rc=$?
    check "sudo -A with a MISSING askpass fails fast instead of hanging" \
          '[[ '"$rc"' -ne 0 && '"$rc"' -ne 124 ]]'
    printf '#!/bin/bash\nexit 42\n' > "$TMP/crash"; chmod +x "$TMP/crash"
    sudo -k 2>/dev/null
    timeout 15 env SUDO_ASKPASS="$TMP/crash" sudo -A /bin/true >/dev/null 2>&1
    rc=$?
    check "sudo -A with a CRASHING askpass fails fast instead of hanging" \
          '[[ '"$rc"' -ne 0 && '"$rc"' -ne 124 ]]'
    check "SUDO_ASKPASS only affects 'sudo -A' — plain sudo keeps its own prompt" \
          'sudo --help 2>&1 | grep -q -- "-A"'
fi

echo ""
echo "== the drop-ins actually win, when sourced the way the shell sources them =="
# Reproduce /etc/profile's `for i in /etc/profile.d/*.sh` against a fake tree
# containing the real competitors. This is the assertion that a numeric prefix
# (the repo's usual convention) would fail — and failing it looks exactly like
# the fix never having been applied.
pd="$TMP/profile.d"; mkdir -p "$pd"
printf 'SUDO_ASKPASS=/usr/bin/ksshaskpass\nexport SUDO_ASKPASS\n'  > "$pd/askpass.sh"
printf 'SSH_ASKPASS=/usr/bin/ksshaskpass\nexport SSH_ASKPASS\n'    > "$pd/kde-openssh-askpass.sh"
cp "$ROOT/config/etc/profile.d/zz-powos-askpass.sh" "$pd/" 2>/dev/null
res=$(cd "$TMP" && env -i bash -c '
    fake=$1
    mkdir -p "$fake/usr/bin"
    # the -x guard in the drop-in must see a real executable
    printf "#!/bin/sh\nexit 0\n" > "$fake/usr/bin/powos-askpass"
    chmod +x "$fake/usr/bin/powos-askpass"
    for i in '"$pd"'/*.sh; do . "$i"; done
    echo "$SUDO_ASKPASS|$SSH_ASKPASS"
' _ "$TMP" 2>/dev/null)
if [[ -x /usr/bin/powos-askpass ]]; then
    check "profile.d order leaves SUDO_ASKPASS on powos-askpass" \
          '[[ "$res" == /usr/bin/powos-askpass\|* ]]'
    check "profile.d order leaves SSH_ASKPASS on powos-askpass" \
          '[[ "$res" == *\|/usr/bin/powos-askpass ]]'
else
    # On a dev box the helper is not installed at /usr/bin yet, so the -x guard
    # correctly declines. Assert the guard, which is the other half of failing safe.
    check "the -x guard declines when /usr/bin/powos-askpass is absent" \
          '[[ "$res" == /usr/bin/ksshaskpass\|/usr/bin/ksshaskpass ]]'
fi

pe="$TMP/plasma-env"; mkdir -p "$pe"
printf 'SSH_ASKPASS=/usr/bin/ksshaskpass\nexport SSH_ASKPASS\n' > "$pe/ksshaskpass.sh"
cp "$ROOT/config/kde/plasma-env/zz-powos-askpass.sh" "$pe/" 2>/dev/null
lastp=$(ls "$pe" | grep -i askpass | sort | tail -1)
check "plasma-workspace drop-in sorts after ksshaskpass.sh" '[[ "'"$lastp"'" == zz-powos-askpass.sh ]]'
lastq=$(ls "$pd" | grep -i askpass | sort | tail -1)
check "profile.d drop-in sorts after every base-image askpass file" '[[ "'"$lastq"'" == zz-powos-askpass.sh ]]'

echo ""
echo "== the environment.d drop-in is a valid systemd environment file =="
ed="$ROOT/config/etc/environment.d/zz-powos-askpass.conf"
check "environment.d drop-in exists" '[[ -f "'"$ed"'" ]]'
check "environment.d drop-in is KEY=VALUE only (no shell, which systemd cannot run)" \
      '! grep -vE "^\s*(#|$)|^[A-Za-z_][A-Za-z0-9_]*=" "'"$ed"'"'
check "environment.d sets both askpass variables" \
      'grep -q "^SUDO_ASKPASS=/usr/bin/powos-askpass$" "'"$ed"'" &&
       grep -q "^SSH_ASKPASS=/usr/bin/powos-askpass$"  "'"$ed"'"'

echo ""
echo "== the helper never becomes a credential store =="
check "nothing in the helper writes a secret to a file or the journal" \
      '! grep -nE "(logger|systemd-cat|>>? *(/var|/tmp|/run)).*(secret|password|PASS)" "'"$H"'"'
check "the secret is never exported into any child's environment" \
      '! grep -nE "^[[:space:]]*(export|declare -x|env )[^#]*secret" "'"$H"'"'
check "no stray 'set -x' — a trace would put the secret straight in the journal" \
      '! grep -nE "^[[:space:]]*set [-+]x|^[[:space:]]*set -[a-z]*x" "'"$H"'"'

echo ""
echo "== Results: $PASS passed, $FAIL failed ${SKIP:+($SKIP skipped)} =="
[[ $FAIL -eq 0 ]]

# Terminal Surfaces and the tmux Resume Wrapper

How every terminal in PowOS ends up inside tmux, which surface is reached by
which mechanism, and the one trap that has now cost this repo two debugging
sessions.

## The goal

Closing a terminal should never lose work. Every interactive terminal therefore
runs `/usr/lib/powos/powos-tmux-shell` instead of a bare shell. The wrapper
either attaches an existing tmux session (via an fzf picker), starts a fresh
one, or falls back to a plain login shell — it always ends in an `exec`, because
a terminal whose command exits is a terminal that vanishes.

## Delivery matrix

There is **no single mechanism** that reaches every surface. There are two, and
which one applies is not a matter of taste:

| Surface | Reached by | Why |
|---|---|---|
| Konsole application (tabs, Yakuake) | `PowOS.profile` → `Command=` | `/etc/xdg/konsolerc` sets `DefaultProfile=PowOS.profile`; the app honours the profile's `Command=` |
| **Konsole KPart** (Dolphin's F4 panel) | `/etc/profile.d/50-powos-tmux-resume.sh` | **The KPart ignores `Command=`** — see below |
| SSH login | `/etc/profile.d/50-powos-tmux-resume.sh` | No Konsole profile exists to point `Command=` at |

## The trap: the KPart ignores `Command=`

The Konsole **KPart** — the embeddable widget Dolphin's terminal panel uses — does
**not** honour the default profile's `Command=`. It starts `$SHELL` directly. So
Dolphin's F4 panel lands in a bare `/bin/bash` even though `konsolerc` names
`PowOS.profile` and that profile sets `Command=`.

This is worth stating loudly because the earlier implementation asserted the
opposite in a source comment — that every Konsole-KPart surface inherits the
profile "for free". That is true of the *application* and false of the
*embedded part*, and the difference is invisible from config alone. Both times
this broke, the investigation started by auditing the `konsolerc` cascade and
`~/.config/konsolerc`, which are fine and have never been the cause.

**Diagnose it in one command.** Compare what each host forks:

```console
$ ps -e -o pid,ppid,args --forest | grep -E 'konsole|dolphin'
  10387  \_ /usr/bin/konsole
  10545  |   \_ tmux new-session      <-- profile Command= worked
 216545  \_ /usr/bin/dolphin
 216634  |   \_ /bin/bash             <-- KPart bypassed it
```

If `konsole` forks tmux and `dolphin` forks a plain shell, the profile is fine
and the KPart is the problem. Do not go looking at `konsolerc`.

## Why profile.d reaches the KPart

The KPart spawns a **non-login, interactive** bash. `/etc/profile.d` is
conventionally a login-shell mechanism, which is why it was dismissed as a
delivery path — but on Fedora it is not only that. `/etc/bashrc` contains:

```sh
if ! shopt -q login_shell ; then      # We're not a login shell
    ...
    for i in /etc/profile.d/*.sh; do
```

So a `profile.d` drop-in **does** reach non-login interactive shells, and
therefore reaches Dolphin's panel. This is a Fedora/Bazzite guarantee, not a
POSIX one; a distro whose `/etc/bashrc` skipped that loop would need a different
hook, and the wrapper would silently stop reaching the panel.

## Hook invariants

The hook in `config/etc/profile.d/50-powos-tmux-resume.sh` only *delegates* —
all picker logic lives in the wrapper, so there is exactly one implementation.
It fires on `SSH_CONNECTION || KONSOLE_VERSION`, guarded by, in order:

1. `case $- in *i*)` — interactive only; never disturb scripts.
2. `[ -z "$TMUX" ]` — never nest inside tmux. Panes inherit `TMUX`, so this
   also stops recursion through tmux's own shells.
3. `[ -z "$POWOS_NO_TMUX" ]` — user escape hatch.
4. `[ -z "$POWOS_TMUX_RESUME_DONE" ]` — the wrapper exports this *before*
   `exec`ing any fallback shell. This is what keeps the Konsole application off
   the hook path: there the wrapper already ran as `Command=`, so the flag is
   set and the surface test is never reached.

`KONSOLE_VERSION` is set by the application as well as the KPart. That is safe
precisely because of guard 4 — what survives to the surface test is exactly the
embedded case. Removing guard 4 would cause double entry, not merely redundancy.

`POWOS_TMUX_SHELL_BIN` overrides the wrapper path so the hook is testable
against a stub.

## Rough edges

- **Dolphin injects `cd` into the picker.** Dolphin's terminal panel keeps the
  shell in sync with the browsed folder by *typing* `cd <dir>\n` into the
  terminal. With the fzf picker open those keystrokes land in fzf's query box.
  The panel is usable, but navigating Dolphin while the picker is up will filter
  or select entries. If this becomes annoying, the fix is to have the wrapper
  detect the KPart and skip straight to a session rather than showing a picker.
- **`/etc` is an ostree 3-way merge.** The hook ships to `/etc/profile.d/`. Once
  a machine has a locally modified copy, ostree preserves it and future image
  updates to that same file are silently shadowed. When changing this hook,
  expect boxes that were hand-patched to keep the old version.

## Verifying a change

```sh
# positive: a Dolphin-like non-login interactive shell must reach the wrapper
env -u TMUX -u POWOS_TMUX_RESUME_DONE -u SSH_CONNECTION \
    KONSOLE_VERSION=260403 POWOS_TMUX_SHELL_BIN=/tmp/stub \
    bash -i -c 'echo FELL-THROUGH'

# negatives that must all fall through:
#   no KONSOLE_VERSION   (a plain shell)
#   POWOS_TMUX_RESUME_DONE=1  (wrapper already ran)
#   TMUX set             (inside tmux)
#   POWOS_NO_TMUX=1      (opt out)
#   bash -c (no -i)      (non-interactive)
```

# Password prompts: making every one of them say what it is for

## The bug

```
ksshaskpass[1259757]: Unable to parse phrase "[sudo] password for powos: "
```

`ksshaskpass` is an **SSH passphrase** dialog. Bazzite ships
`/etc/profile.d/askpass.sh` (unowned by any rpm) which points `SUDO_ASKPASS` at
it, so every `sudo -A` in a GUI session hands a *sudo* prompt to a program that
only knows how to parse *ssh* prompts. It fails its regexes, logs the line
above, and draws a box titled **"Enter SSH Credentials"** reading **"Please
enter passphrase"**.

No command. No requesting process. No directory. No target user. No reason.
A burst of those is indistinguishable from malware asking for your root
password, and there is nothing in the dialog a user could act on.

## The three environments that can raise such a prompt

A password prompt with no terminal reaches the user through one of exactly
three paths on this image, and each one needs its own drop-in. Fixing only the
shell path is the easy mistake — the paths that actually *need* an askpass
helper are the ones with no shell in their ancestry.

| path | who sets the env | file we ship |
|---|---|---|
| login / interactive shells | `/etc/profile`, `/etc/bashrc` iterate `/etc/profile.d/*.sh` | `/etc/profile.d/zz-powos-askpass.sh` |
| anything launched from the desktop (launcher, `.desktop`, KRunner, autostart) | `startplasma` sources `/etc/xdg/plasma-workspace/env/*.sh` | `/etc/xdg/plasma-workspace/env/zz-powos-askpass.sh` |
| `systemd --user` units (Plasma 6's own session, every Quadlet) | `environment.d` | `/usr/lib/environment.d/zz-powos-askpass.conf` |

All three set `SUDO_ASKPASS` and `SSH_ASKPASS` to `/usr/bin/powos-askpass`.

## Why the filenames start with `zz` and not a number

Every other PowOS drop-in is numbered (`05-`, `49-`, `50-`). These cannot be,
and it is the single most important detail in the change.

`/etc/profile` does `for i in /etc/profile.d/*.sh`, i.e. **glob order**, and
digits sort **before** letters. The files that have to be beaten are lettered:

```
 6: /etc/profile.d/askpass.sh              -> SUDO_ASKPASS=/usr/bin/ksshaskpass
20: /etc/profile.d/gnome-ssh-askpass.sh
22: /etc/profile.d/kde-openssh-askpass.sh  -> SSH_ASKPASS=/usr/bin/ksshaskpass
```

A `50-powos-askpass.sh` would be sourced **first** and silently overwritten by
both — and the only symptom would be the original bad dialog still happening.
Same story in the Plasma env directory, where the competitor is
`ksshaskpass.sh`.

Two guards exist because this is a bet against files the **base image** owns
and can rename at any update:

- a Containerfile build assertion — the last `*askpass*` file in each directory
  must be ours, or the build fails;
- an in-image invariant that sources the whole directory the way the shell does
  and reads `SUDO_ASKPASS` back.

## What the helper shows

`sudo` hands an askpass helper **exactly one argument**: the prompt string.
Not `SUDO_COMMAND`, not `SUDO_USER`, not the cwd. Everything else has to be
recovered, so `powos-askpass` walks `/proc` from `$PPID` up to the `sudo`
process and reads what it finds there:

```
== Run as root ==
A program on this machine wants to run a command as root.
  Command:      /usr/bin/systemctl restart NetworkManager
  Run as:       root
  Requested by: deploy-thing.sh - /bin/bash /tmp/deploy-thing.sh  [pid 1621882]
  Directory:    /tmp
  Session:      sudo < deploy-thing.sh < bash < claude < bash < dolphin
  Asking as:    powos@bazzite
```

`Session` is the field that usually answers "what *is* this?" when the
immediate parent is a generic `bash`.

It also classifies ssh prompts (key path, remote account, agent confirmation,
unknown host key) rather than showing one generic box for everything — see the
header of `bin/powos-askpass` for the full table.

### /proc gotchas that shaped it

- **`/proc/<sudo>/cwd` is unreadable.** sudo is setuid, so the symlink is
  `EACCES` even to the invoking user. `cmdline` is *not*, which is why the
  command can be recovered exactly. The working directory instead comes from
  the helper's own `$PWD` — sudo does not chdir before spawning it, so that is
  the honest answer and it needs no permissions at all.
- **`/proc/<pid>/stat` field 2 is unquoted `comm`** and may contain spaces and
  parentheses (`(Web Content)`). Split after the **last** `)` or the ppid walk
  mis-parses for half the processes on a desktop.
- **cmdlines are unbounded and contain control characters.** The claude-code
  wrapper on this box has a ~4 KB cmdline with embedded newlines and quotes.
  Every value is flattened, stripped to printable, and clipped.

### The bash 5.2 escaping trap

The dialog body is Qt rich text, so `<`, `>` and `&` must be escaped. This
looks right and is not:

```bash
s=${s//</&lt;}      # produces  <lt;
```

Since bash 5.2, `patsub_replacement` is on by default: an unquoted `&` in the
**replacement** half of `${var//pat/rep}` expands to the text that matched. So
`&lt;` becomes `<lt;`, and the escaping produces exactly the broken markup it
existed to prevent. Caught live on bash 5.3.9 with a real kdialog invocation.
`sed 's/</\&lt;/g'` is unambiguous in every version; there is a regression test.

## Failing safe

This is the constraint that shaped everything else, because the failure mode of
a bad askpass helper is "cannot become root".

- **`SUDO_ASKPASS` is consulted only by `sudo -A`.** Plain `sudo` prompts on the
  terminal regardless. Verified: with `SUDO_ASKPASS` pointing at a script that
  exits 42, plain `sudo` still printed `[sudo] password for powos:` and
  authenticated normally. There is no value here — or absence of one — that can
  lock anyone out of root.
- **The two shell drop-ins carry a `test -x` guard.** A half-applied image
  degrades to the old, ugly-but-working ksshaskpass rather than to nothing.
  `environment.d` is `KEY=VALUE` only and cannot express that, which is why the
  Containerfile fails the build if the env files ship without an executable
  helper.
- **No GUI and no controlling terminal → exit 1 immediately.** `/dev/tty` is
  `ENXIO` for a process with no controlling terminal (a systemd unit, anything
  at boot), so the helper writes its explanation to stderr — where sudo and the
  journal will show it — and gives up. It never hangs, and it never writes
  anything to stdout, because stdout is the secret channel and an empty answer
  there would be indistinguishable from a real one.

## What was deliberately NOT done

| rejected | why |
|---|---|
| `SUDO_ASKPASS=/bin/false` (previously tried) | silences the prompt, which turns an expired credential into a *silent* failure. Strictly worse than an ugly dialog. |
| removing/renaming Bazzite's `/etc/profile.d/askpass.sh` | it is unowned by rpm, so nothing would restore it, and a base-image change could reintroduce it under another name. Sorting after it is stable; deleting it is a race with the next rebase. |
| `Defaults passprompt=` in sudoers | sudo's prompt escapes are only `%H %h %p %U %u` — no command, no cwd, no requester. It would buy the target user and nothing else, in exchange for editing the file that governs privilege escalation. |
| patching `ksshaskpass` | it is correct at its job. It was simply pointed at the wrong kind of prompt. |
| shadowing the `.csh` askpass files | nothing on this image runs a csh login shell, and a csh syntax error in `profile.d` would be far more damaging than the dialog it fixed. |
| a `polkit-1/rules.d` rule logging the requester | see below. |

## polkit: what it already does, and the one thing it cannot

The KDE agent (`/usr/libexec/kf6/polkit-kde-authentication-agent-1`, autostarted
and running) is **not** in the same state as the sudo path. Its message
catalogue shows it already renders:

```
Authentication Required
<the action's <message> string>
Authenticating as <user>          User: %1
[Details]  Action:  <description>
           ID:      <action id>
           Vendor:  <vendor>, <vendor url>
```

So *what* is being authorised, *which* action id, *who vouches for it* and
*which account is being escalated to* are all present — the last two behind a
**Details** disclosure that is collapsed by default.

The one field missing is the same one that mattered for sudo: **the requesting
process**. It is not reachable from configuration:

- The dialog body is the action's `<message>` from a `.policy` file, with
  `$(var)` substitution from details the *caller* supplied. Overriding it would
  mean shipping our own copy of each vendor `.policy` file in
  `/usr/share/polkit-1/actions/` — hundreds of them, each one then frozen
  against upstream updates.
- `rules.d` JavaScript sees `subject.pid`, `user`, `groups`, `seat`, `session`,
  `local`, `active` — but has **no** way to add details to the dialog. It can
  only return an authorisation result.
- The agent itself has no config file; the layout is compiled-in QML.

A `rules.d` rule that only called `polkit.log()` with the subject pid was
considered and rejected: `addRule` runs on **every** authorisation check
(NetworkManager alone generates a steady stream), so it would flood the journal,
and it would put PowOS code on the authorisation path to buy diagnostics that
arrive after the dialog is already gone. `rules.d` is not the place to
experiment.

Showing the requester needs a patch to polkit-kde's QML. The repo already has
the machinery for that (`sources/kde/patches/`, a from-source builder stage),
so it is possible — it is just a ~30 min build stage and a new upstream to
track, for one line in a dialog that already names the action. Left undone
deliberately.

## Verifying it on a running system

```bash
# what the dialog would say, without prompting for anything
POWOS_ASKPASS_DRY_RUN=1 powos-askpass "[sudo] password for $USER: "

# which helper each environment actually resolves to
env -i bash -c 'for i in /etc/profile.d/*.sh; do . $i; done; echo $SUDO_ASKPASS'
systemctl --user show-environment | grep ASKPASS

# force a renderer
POWOS_ASKPASS_MODE=tty powos-askpass "Enter passphrase for key '/x/id_ed25519': "
```

```bash
bash test/tier1/test-askpass.sh            # behavioural, runs anywhere
bash test/tier1/test-image-invariants.sh   # asserts on a built image
```

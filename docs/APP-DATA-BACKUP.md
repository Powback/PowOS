# The PowOS app's data: backed up, never wiped unbacked

**Rule: never `pm uninstall-system-updates com.powos.app` (nor `pm clear`, nor a downgrade) without the backup
step. The only sanctioned way is `sh /data/powos/powos-appdata.sh rebase <apk>` on the phone.**
`test/tier1/test-appdata-guard.sh` fails on any such command elsewhere in the tree.

## What happened (2026-10-20, 05:46)

A one-shot runner (`/data/local/tmp/powos-idle-sysupdate.sh`, armed by the manager) re-based the app on its
`/system/priv-app` copy while the user slept, so PackageManager would grant `BIND_APPWIDGET`:
`pm uninstall-system-updates com.powos.app`, then `pm install -r -g` of the current APK. Removing the updates made
Android **delete `/data/data/com.powos.app`** and make it anew. Lost, with no copy anywhere:

- the home layout (`shared_prefs/widget_grid.xml`, back to the defaults), drawer pins, panels, app usage;
- the hosted Android widgets (`shared_prefs/appwidgets.xml`: the bindings; the widget ids are gone with them);
- the installed PowOS app UIs (`files/apps`; the apps' SpacetimeDB modules and data live in PowOS's root and survived);
- PowOS AI's chat history and threads (`files/powos-ai/`), the agent mail store (`files/powos-ai/agent-mail.json`);
- the shell's store (`files/shell-data`), WebView localStorage (`app_webview/`), live widget/style edits.

Two knock-on effects, also fixed or handled now:

- **Magisk dropped the app's root grant.** The new copy's first `su` raised a prompt on a dozing screen; it timed
  out as a lasting deny (`magisk.db` `policies`: uid's `policy=1`), so the PowOS session could no longer start.
  Only the user re-grants it: Magisk > Superuser > PowOS > allow. `rebase` checks and notifies.
- **The running session kept binds onto the deleted directory** (`/data/powos/root/run/powos-app`,
  `~/.config/omalauncher/{widgets,style}`, `~/.local/share/powos/apps` showed `//deleted` sources in
  `/proc/1/mountinfo`), and `powos-session.sh` treated "something is mounted there" as done - the next session would
  have installed apps where the app never looks. It now replaces a bind whose source was deleted (`appbind`).

## What protects it now (`targets/android/rooted/powos-appdata.sh`, installed by `rooted.sh deploy`)

| Command (as root on the phone) | What |
|---|---|
| `powos-appdata.sh backup [tag]` | whole data dir -> `/data/powos/backup/app-data-<time>[-tag].tar` (owners + SELinux labels kept; cache/, code_cache/, WebView caches, `files/run`, `files/tmp` left out). Newest 5 kept. |
| `powos-appdata.sh restore <tar>` | app stopped; what's there now moved to `/data/powos/backup/replaced-<time>/` (not deleted); tar extracted; owner = the app's current uid; `restorecon -RF`, then checked against the data dir's own label. |
| `powos-appdata.sh rebase <apk>` | backup -> **refuses (exit 3) unless the backup is readable and holds `shared_prefs/widget_grid.xml`** -> `pm uninstall-system-updates` -> `pm install -r -g <apk>` -> restore -> root-grant check (notification if lost). |
| `powos-appdata.sh light` / `watch` | the precious small part (`shared_prefs`, `files/{shell-data,powos-ai,widgets,widget-state,style}`) -> `/data/powos/root/var/backups/powos-app/light-<time>.tar` when it changed; `watch` does it hourly (awake time) and is started by `powos-start.sh` at boot. Newest 48 kept. A wipe loses at most that hour. |
| `powos-appdata.sh list` | the backups, newest first. |

- `targets/android/rooted/powos-idle-sysupdate.sh` (the idle re-base runner, now in the tree) refuses to arm without
  `powos-appdata.sh` or when a test backup fails, and re-bases only through `rebase`.
- `targets/android/install-app.sh` (every APK install) takes a backup first (`...-install.tar`) and refuses the
  install if that fails; it never downgrades.

## Restoring by hand

```sh
su -c 'sh /data/powos/powos-appdata.sh list'
su -c 'sh /data/powos/powos-appdata.sh restore /data/powos/backup/app-data-<time>.tar'
# or only the layout/store from the hourly copy:
su -c 'sh /data/powos/powos-appdata.sh restore /data/powos/root/var/backups/powos-app/light-<time>.tar'
```

A restore replaces only the paths the backup holds (a light one: the layout and the store; the rest stays). Hosted Android widgets come back only if their widget ids
still exist (a full restore made right after a re-base keeps them; Android forgets ids of a deleted host over time).

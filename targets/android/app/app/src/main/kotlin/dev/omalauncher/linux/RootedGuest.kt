package dev.omalauncher.linux

import java.io.File

/**
 * PowOS on a rooted phone (andro.marchy.RootMode): the launcher's terminals run in the PowOS desktop session itself,
 * as the user powos, through /data/powos/powos-run.sh (targets/android/rooted) - the same system, home, tmux sessions
 * and dbus as the desktop's Konsole - instead of in Omalauncher's own proot system, which isn't installed then.
 */
object RootedGuest {
    val enabled get() = POWOS && andro.marchy.RootMode.enabled()

    /**
     * Where the launcher's Wayland server listens in rooted mode: inside the app's run dir, which the PowOS session
     * sees as /run/powos-app (powos-session.sh), in a directory of its own (the session clears the dir's own sockets).
     */
    fun runtimeDir(filesDir: File) = File(filesDir, "run/omalauncher")

    /**
     * Where what the launcher starts shows: the PowOS desktop's own display (KWin's socket in the session's
     * XDG_RUNTIME_DIR, /run/powos-app). Not the launcher's Wayland server: PowOS processes (SELinux magisk, s0) can't
     * hand their buffers to the app, so their windows never drew there (see ui/PtyTerminal).
     */
    private const val WAYLAND_DISPLAY = "wayland-0"

    /** The PowOS app's run dir (the session's XDG_RUNTIME_DIR), once the session is known to run; see [session]. */
    @Volatile var runDir: File? = null

    /**
     * Which PowOS session runs: when its start marker was made (each session start makes it anew). Long-lived processes
     * in the session (GuestShell) start again in a new one rather than staying in the old one's namespace.
     */
    fun session(): Long = runDir?.let { File(it, "desktop-ready").lastModified() } ?: 0L

    /** The terminal PowOS opens everywhere (Konsole's PowOS.profile): its tmux session picker, falling back to a shell. */
    const val TERMINAL_SHELL = "/usr/lib/powos/powos-tmux-shell"

    /** `bash -lc [command]` in the PowOS session, stderr merged into stdout unless not [mergeErrors]. */
    fun process(
        command: String,
        mergeErrors: Boolean = true,
    ): ProcessBuilder = ProcessBuilder("su", "-c", rootCommand(command)).redirectErrorStream(mergeErrors)

    /** What root runs (`su -c`) for `bash -lc [command]` in the PowOS session. */
    fun rootCommand(command: String): String {
        val env = "WAYLAND_DISPLAY=$WAYLAND_DISPLAY LANG=${shellQuote(locale())} TZ=${shellQuote(java.util.TimeZone.getDefault().id)}"
        return "$env sh /data/powos/powos-run.sh ${shellQuote(command)}"
    }

    /**
     * Like Proot.run: blocking, each output line to [onLine]; the exit code. A short command: through the app's one
     * root shell ([andro.marchy.RootShell] - a new `su` each time was a Magisk toast each time, and the panel held at 60
     * Hz under every one). Something that runs on (an app, a stream): [runOwn].
     */
    fun run(
        command: String,
        onLine: (String) -> Unit = {},
    ): Int = andro.marchy.RootShell.run(rootCommand(command)) { onLine(it) }

    /**
     * Like [run], in a root process of its own: for a command that runs a while (it'd hold the shared shell) and ends,
     * its output on the app's pipe. A program that runs on (an app, a game) is [launch]: never this pipe.
     */
    fun runOwn(
        command: String,
        onLine: (String) -> Unit = {},
    ): Int {
        val process = process(command).start()
        process.inputStream.bufferedReader().forEachLine(onLine)
        return process.waitFor()
    }

    /**
     * Starts [command] (a shell command line) as a program that runs on - an app, a game, a Steam client - with none of
     * the app's pipes: stdin from /dev/null, stdout and stderr appended to `$XDG_RUNTIME_DIR/launch/<name>.log`
     * (restarted past 4 MB). While it runs its new output is relayed to [onLine]; returns its exit code, like [runOwn].
     *
     * Never `runOwn("exec <program>")`: the program would hold the app's pipe; once the app restarts (an APK update)
     * that pipe has no reader - whatever the program, and every child it hands its fds to, writes next gets SIGPIPE.
     * Steam passed it on to every game it started: Broforce 2026-11-03 ended ~10 s after each launch (7decee44 fixed it
     * in powos-open-task; targets/android/docs/powos-window-tasks.md "Output" has the rule). Short commands whose
     * output the app reads, which finish, keep the pipe ([run], [runOwn]).
     */
    fun launch(
        name: String,
        command: String,
        onLine: (String) -> Unit = {},
    ): Int = runOwn(launchCommand(name, command), onLine)

    /** The shell line [launch] runs in the session: [command] off the caller's fds, its log relayed while it runs. */
    fun launchCommand(
        name: String,
        command: String,
    ): String {
        val log = "\"\${XDG_RUNTIME_DIR:-/tmp}/launch/${logName(name)}.log\""
        // Only the leaf (launch/): `mkdir -p` walks from / and, in the no-root image, the run dir is an Android path
        // (/data/user/0/<app>/files/run, passed through by fakechroot) whose parents aren't - "cannot create directory
        // '/data'", and the launch never started. XDG_RUNTIME_DIR itself always exists (the session's run dir).
        return "f=$log; [ -d \"\${f%/*}\" ] || mkdir \"\${f%/*}\"; " +
            "[ \"\$(stat -c %s \"\$f\" 2>/dev/null || echo 0)\" -gt $LAUNCH_LOG_KEEP ] && : >\"\$f\"; " +
            "s=\$(stat -c %s \"\$f\" 2>/dev/null || echo 0); " +
            "(exec $command) </dev/null >>\"\$f\" 2>&1 & p=\$!; " +
            "tail -c +\$((s + 1)) -s 0.25 --pid=\$p -f \"\$f\" 2>/dev/null; wait \$p"
    }

    /** A launch log's file name: [name]'s last path part, only [A-Za-z0-9._-], at most 64 characters. */
    fun logName(name: String): String =
        name.trim().substringBefore(' ').substringAfterLast('/').replace(Regex("[^A-Za-z0-9._-]"), "_").take(64)
            .ifEmpty { "command" }

    /** Bytes: a launch log past this is restarted at the program's next launch (it appends: O_APPEND, `>>`). */
    private const val LAUNCH_LOG_KEEP = 4 shl 20

    /**
     * Opens a PowOS app like a phone app: its window as its own Android task (session/powos-open-task - KWin exports
     * the window, docs/powos-window-tasks.md), the app's existing window if it has one. [showDesktop] runs when it
     * opens on the PowOS desktop instead (no window tasks yet, a window KWin doesn't export, or a PowOS without
     * powos-open-task - rooted.sh deploy installs it). Blocking for as long as the app writes output, like [run].
     */
    fun openAsTask(
        appId: String,
        wmClass: String?,
        exec: String,
        showDesktop: () -> Unit,
        onLine: (String) -> Unit = {},
    ): Int {
        return runOwn(openTaskCommand(appId, wmClass, exec)) { line ->
            if (line == OPEN_DESKTOP) showDesktop()
            onLine(line)
        }
    }

    /** The shell line [openAsTask] runs in the session (also the no-root [Guest]'s, in the PowOS image). */
    fun openTaskCommand(
        appId: String,
        wmClass: String?,
        exec: String,
    ): String {
        val ids = listOfNotNull(appId, wmClass).filter { it.isNotBlank() }.joinToString("") { " --app-id " + shellQuote(it) }
        return "if command -v powos-open-task >/dev/null; then exec powos-open-task$ids -- ${shellQuote(exec)}; " +
            "else echo '$OPEN_DESKTOP'; ${launchCommand(appId, exec)}; fi"
    }

    /** powos-open-task's status line: the app opens on the desktop, not as a task. */
    const val OPEN_DESKTOP = "powos-open-task: desktop"

    /** The session's LANG (SessionService.androidLocale; the session's first boot compiled that locale). */
    private fun locale() = java.util.Locale.getDefault().let { if (it.country.isEmpty()) "C.UTF-8" else "${it.language}_${it.country}.UTF-8" }
}

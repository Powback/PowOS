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

    /** Like [run], in a root process of its own: for what runs as long as an app does (it'd hold the shared shell). */
    fun runOwn(
        command: String,
        onLine: (String) -> Unit = {},
    ): Int {
        val process = process(command).start()
        process.inputStream.bufferedReader().forEachLine(onLine)
        return process.waitFor()
    }

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
        val ids = listOfNotNull(appId, wmClass).filter { it.isNotBlank() }.joinToString("") { " --app-id " + shellQuote(it) }
        val command =
            "if command -v powos-open-task >/dev/null; then exec powos-open-task$ids -- ${shellQuote(exec)}; " +
                "else echo '$OPEN_DESKTOP'; exec $exec; fi"
        return runOwn(command) { line ->
            if (line == OPEN_DESKTOP) showDesktop()
            onLine(line)
        }
    }

    /** powos-open-task's status line: the app opens on the desktop, not as a task. */
    private const val OPEN_DESKTOP = "powos-open-task: desktop"

    /** The session's LANG (SessionService.androidLocale; the session's first boot compiled that locale). */
    private fun locale() = java.util.Locale.getDefault().let { if (it.country.isEmpty()) "C.UTF-8" else "${it.language}_${it.country}.UTF-8" }
}

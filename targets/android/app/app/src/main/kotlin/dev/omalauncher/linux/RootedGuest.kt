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

    /** Like Proot.run: blocking, each output line to [onLine]; the exit code. */
    fun run(
        command: String,
        onLine: (String) -> Unit = {},
    ): Int {
        val process = process(command).start()
        process.inputStream.bufferedReader().forEachLine(onLine)
        return process.waitFor()
    }

    /** The session's LANG (SessionService.androidLocale; the session's first boot compiled that locale). */
    private fun locale() = java.util.Locale.getDefault().let { if (it.country.isEmpty()) "C.UTF-8" else "${it.language}_${it.country}.UTF-8" }
}

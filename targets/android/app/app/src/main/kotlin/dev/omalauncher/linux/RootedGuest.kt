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

    /** The launcher's Wayland socket, as PowOS sees it. */
    private const val WAYLAND_DISPLAY = "/run/powos-app/omalauncher/wayland-0"

    /** The terminal PowOS opens everywhere (Konsole's PowOS.profile): its tmux session picker, falling back to a shell. */
    const val TERMINAL_SHELL = "/usr/lib/powos/powos-tmux-shell"

    /** `bash -lc [command]` in the PowOS session, stderr merged into stdout. */
    fun process(command: String): ProcessBuilder {
        val env = "WAYLAND_DISPLAY=$WAYLAND_DISPLAY LANG=${shellQuote(locale())} TZ=${shellQuote(java.util.TimeZone.getDefault().id)}"
        return ProcessBuilder("su", "-c", "$env sh /data/powos/powos-run.sh ${shellQuote(command)}").redirectErrorStream(true)
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

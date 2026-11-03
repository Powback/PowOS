package dev.omalauncher.linux

import android.content.Context

/**
 * PowOS on a phone without root: the launcher's Linux is the PowOS image the engine installed and runs
 * (andro.marchy.SessionService: the rootfs in the app's files, entered through lotfix-run - no proot, no root). Widget
 * commands and streams run there, as the engine's session programs do. Omalauncher's own proot Arch ([Proot]) is never
 * installed under PowOS, so before this the unrooted launcher had no Linux at all: every widget with a command waited
 * forever for an Arch install that PowOS never starts (2026-11-03, "widgets etc. don't work" on a non-rooted phone).
 *
 * Rooted phones use [RootedGuest] (the PowOS session itself); the two never both apply.
 */
object EngineGuest {
    @Volatile private var context: Context? = null

    /** The app's context, once (Runtime's init); without it nothing runs here. */
    fun init(ctx: Context) {
        context = ctx.applicationContext
    }

    /** No root, and the PowOS image is installed: widgets' Linux is that image. */
    val enabled: Boolean
        get() {
            val ctx = context ?: return false
            return POWOS && !RootedGuest.enabled && andro.marchy.SessionService.rootfsReady(ctx)
        }

    /** `sh -c [command]` in the PowOS image, stderr merged into stdout unless not [mergeErrors]. */
    fun process(
        command: String,
        mergeErrors: Boolean = true,
    ): ProcessBuilder = andro.marchy.SessionService.guestProcess(context ?: error("EngineGuest not initialised"), command).redirectErrorStream(mergeErrors)
}

/**
 * Where a widget's guest command runs: the PowOS session (rooted), the PowOS image (no root, [EngineGuest]), else
 * Omalauncher's proot system. The one place GuestShell and Streams pick it, so they can't disagree.
 */
fun guestProcess(
    proot: Proot,
    shell: String,
    mergeErrors: Boolean,
): ProcessBuilder =
    when {
        RootedGuest.enabled -> RootedGuest.process(shell, mergeErrors)
        EngineGuest.enabled -> EngineGuest.process(shell, mergeErrors)
        // As before: Omalauncher's proot merges stderr (its own process()).
        else -> proot.process(shell)
    }

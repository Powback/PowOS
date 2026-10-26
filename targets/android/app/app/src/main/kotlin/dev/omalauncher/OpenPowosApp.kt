package dev.omalauncher

import android.app.Activity
import android.os.Bundle
import android.util.Log
import dev.omalauncher.linux.PowosShortcuts
import dev.omalauncher.linux.RootedGuest
import kotlin.concurrent.thread

/**
 * Opens a PowOS app from Android: its shortcut (PowosShortcuts) - the PowOS icon's long-press menu, Android's search,
 * or one pinned to the phone's home screen. Raises the PowOS desktop (starting its session if it isn't running) and
 * starts the app there, or a terminal app in a PowOS terminal; no window of its own.
 */
class OpenPowosApp : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val exec = intent.getStringExtra(PowosShortcuts.OPEN_EXEC)
        val name = intent.getStringExtra(PowosShortcuts.OPEN_NAME) ?: "PowOS"
        if (!exec.isNullOrBlank()) {
            if (intent.getBooleanExtra(PowosShortcuts.OPEN_TERMINAL, false)) {
                PowosTerminalActivity.open(this, exec, name)
            } else {
                andro.marchy.MainActivity.show(this)
                // Plasma itself (dev.omalauncher.linux.PLASMA_COMMAND): its desktop is all there is to open.
                if (exec == dev.omalauncher.linux.PLASMA_COMMAND) return finish()
                // powos-run waits for the session if the desktop is still starting it.
                thread(name = "powos-open", isDaemon = true) {
                    val code = runCatching { RootedGuest.runOwn("exec $exec") }.getOrElse { -1 }
                    Log.i("OpenPowosApp", "$name exited $code")
                }
            }
        }
        finish()
    }
}

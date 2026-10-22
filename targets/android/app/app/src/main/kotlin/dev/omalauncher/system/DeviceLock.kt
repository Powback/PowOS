package dev.omalauncher.system

import android.app.KeyguardManager
import android.content.Context
import dev.omalauncher.shell.PowosLockActivity

/**
 * Whether the phone is locked right now - asked live, never from a remembered SystemUI state bit: the lock screen
 * (Android's keyguard) or PowOS's lock face over it. With the lock face up SystemUI reports the keyguard as OCCLUDED,
 * not SHOWING, so a gesture or overlay checking only the SHOWING bit would open over the lock face. Nothing that shows
 * the user's controls, notifications or apps (the edge handles, Quick Tools, the shade, the pull-up panels) may come up
 * while this is true.
 */
object DeviceLock {
    fun locked(context: Context): Boolean =
        PowosLockActivity.current != null ||
            runCatching { context.getSystemService(KeyguardManager::class.java).isKeyguardLocked }.getOrDefault(true)
}

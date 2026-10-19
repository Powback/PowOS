package dev.omalauncher.shell

import android.app.Activity
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.view.ViewGroup
import android.view.WindowManager
import dev.omalauncher.App

/**
 * The lock screen's face (docs/NATIVE-SYSTEM-UI.md, "Lock screen: PowOS is the face, SystemUI keeps the lock"):
 * when the screen goes off (and so is there as it comes on, the phone locked), PowOS's lock screen shows over Android's (an activity shown when
 * locked: [PowosLockActivity]) - the shell's lock screen (shell/ui/lock.tsx), hot-reloaded as every PowOS screen.
 * Unlocking stays Android's: swiping up asks it (requestDismissKeyguard: its PIN pad, the fingerprint), and once the
 * phone is unlocked the face goes. Underneath it Android's own lock screen is always there - whatever happens to the
 * face, the phone stays locked and unlockable.
 */
object LockFace {
    private var registered = false

    fun start(context: Context) {
        if (registered) return
        registered = true
        val app = context.applicationContext
        app.registerReceiver(
            object : BroadcastReceiver() {
                override fun onReceive(
                    c: Context,
                    intent: Intent,
                ) {
                    when (intent.action) {
                        // Up as the screen goes off, so it's there the moment the screen comes on - started on screen-on,
                        // Android's own lock screen showed first, the face a moment later: two lock screens. Not locked
                        // by the time the screen is back on (a lock delay): the face goes by itself (onResume).
                        Intent.ACTION_SCREEN_OFF -> show(app)
                        // Still the fallback (the face was closed meanwhile, or the off broadcast came late).
                        Intent.ACTION_SCREEN_ON ->
                            if (app.getSystemService(KeyguardManager::class.java).isKeyguardLocked) show(app) else PowosLockActivity.current?.finish()
                        // Unlocked (by the face's handoff, the fingerprint, anything): the face goes.
                        Intent.ACTION_USER_PRESENT -> PowosLockActivity.current?.finish()
                    }
                }
            },
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_USER_PRESENT)
            },
        )
    }

    private fun show(app: Context) {
        if (PowosLockActivity.current != null) return
        app.startActivity(
            Intent(app, PowosLockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
        )
    }

    /** The lock screen's page, kept warm (as the assistant's, AssistWeb): the face is there as the screen comes on. */
    private var host: ShellHost? = null

    internal fun host(context: Context): ShellHost =
        host ?: run {
            val app = context.applicationContext as App
            ShellHost(app, null, app.runtime, "lock").also { host = it }
        }
}

/** The face itself: shown over Android's lock screen, never instead of it. */
class PowosLockActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = this
        setShowWhenLocked(true)
        window.setDecorFitsSystemWindows(false)
        window.addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)
        val h = LockFace.host(this)
        (h.web.parent as? ViewGroup)?.removeView(h.web)
        h.bridge.lock =
            object : LockSlot {
                override fun unlock() {
                    getSystemService(KeyguardManager::class.java).requestDismissKeyguard(
                        this@PowosLockActivity,
                        object : KeyguardManager.KeyguardDismissCallback() {
                            override fun onDismissSucceeded() = finish()
                        },
                    )
                }
            }
        h.bridge.emit("lock.shown", null)
        setContentView(h.web)
    }

    // Not locked with the screen on (the lock never followed the screen-off, or it was unlocked meanwhile): it goes.
    // Screen off, it stays: the lock may come a moment after the face.
    override fun onResume() {
        super.onResume()
        val on = getSystemService(android.os.PowerManager::class.java).isInteractive
        if (on && !getSystemService(KeyguardManager::class.java).isKeyguardLocked) finish()
    }

    // Back on a lock screen goes nowhere: the face stays until the phone is unlocked.
    @Deprecated("Back does nothing on a lock screen", ReplaceWith(""))
    override fun onBackPressed() {}

    override fun onDestroy() {
        if (current === this) current = null
        val h = LockFace.host(this)
        (h.web.parent as? ViewGroup)?.removeView(h.web)
        h.bridge.lock = null
        super.onDestroy()
    }

    companion object {
        var current: PowosLockActivity? = null
    }
}

/** What the lock screen's page reaches (lock.unlock). */
interface LockSlot {
    fun unlock()
}

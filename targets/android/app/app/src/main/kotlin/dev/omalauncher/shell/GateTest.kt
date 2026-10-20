package dev.omalauncher.shell

import android.content.Context
import android.os.Handler
import android.os.Looper
import dev.omalauncher.App

/**
 * The test-only page (shell/dev/gate-test.tsx, index.html?mode=gate-test): what a test of the shell's safety net
 * breaks instead of a page the user is looking at. No window shows it - when its file changes in the override folder
 * (`shell/push.sh --test ... dev/gate-test.tsx`), it's loaded in a WebView of its own, off screen, for [KEEP_MS]: the
 * same [ShellHost] as every page, so its boot watchdog, the report to the manager ([ShellErrors], marked "[test]") and
 * the rollback of the push all run as they would for home.
 */
object GateTest {
    const val MODE = "gate-test"

    /** The override folder's path of the page's module: a change to it loads the page again. */
    const val FILE = "dev/gate-test.tsx"

    /** Long enough for the watchdog (8 s at most), a rollback and the page's reload after it. */
    private const val KEEP_MS = 60_000L

    private val main = Handler(Looper.getMainLooper())
    private var host: ShellHost? = null
    private val done = Runnable { close() }

    /** Its module changed: the page loaded anew (a page already up from a test before goes first). */
    fun changed(context: Context) {
        close()
        val app = context.applicationContext as App
        host = ShellHost(app, null, app.runtime, MODE)
        main.postDelayed(done, KEEP_MS)
    }

    private fun close() {
        main.removeCallbacks(done)
        host?.destroy()
        host = null
    }
}

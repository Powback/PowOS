package dev.omalauncher.assist

import android.content.Context
import dev.omalauncher.App
import dev.omalauncher.shell.ShellHost

/**
 * The assistant's page, kept warm: made once (when PowOS AI becomes the assistant, or at the first summoning) and shown
 * by every session after, so holding the power button shows the panel at once - not a WebView started and the shell
 * loaded each time. On the app's context: it outlives each session's window, which only borrows it.
 */
object AssistWeb {
    private var host: ShellHost? = null

    fun get(context: Context): ShellHost =
        host ?: run {
            val app = context.applicationContext as App
            app.runtime.start()
            ShellHost(app, null, app.runtime, "assist").also { host = it }
        }
}

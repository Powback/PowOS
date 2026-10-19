package dev.omalauncher.system

import android.content.Context
import android.content.Intent
import dev.omalauncher.App
import dev.omalauncher.shell.ShellHost
import dev.omalauncher.shell.SwitcherActivity
import org.json.JSONObject

/**
 * PowOS's switcher (the recents screen): the web shell's switcher page (shell/ui/switcher.tsx, mode=switcher) in
 * [SwitcherActivity], the activity config_recentsComponentName names. The page is kept warm (made when SystemUI
 * connects, on the app's context; each showing of the activity only borrows it), so the overview button shows it at
 * once - as the assistant's page (AssistWeb).
 */
object Switcher {
    private var host: ShellHost? = null

    /** The task the switcher was opened over (null: home), for the page: Back and a second press go back to it. */
    var from: Int? = null
        private set

    /** The activity while it's resumed. */
    var showing: SwitcherActivity? = null

    fun page(context: Context): ShellHost =
        host ?: run {
            val app = context.applicationContext as App
            app.runtime.start()
            ShellHost(app, null, app.runtime, MODE).also { host = it }
        }

    /** The overview button: the switcher; pressed again while it shows, the page decides (it switches back). */
    fun toggle(context: Context) {
        if (showing != null) page(context).bridge.emit("switcher.toggle", null) else show(context)
    }

    /**
     * Shows the switcher over the app in front - or, from a swipe that already sent the app home (the recents animation),
     * over home with [over] as the app it came from.
     */
    fun show(
        context: Context,
        over: Int? = Tasks.visible(context),
    ) {
        if (showing != null) return
        from = over
        // Started by the recents provider: allowed from the background (BackgroundActivityStartController's "Recents
        // Component").
        context.startActivity(
            Intent(context, SwitcherActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
        )
    }

    fun hide() {
        showing?.finish()
    }

    /** What the page hears when the switcher comes up: refresh, and which task it came from. */
    fun shownEvent(): JSONObject = JSONObject().put("from", from ?: JSONObject.NULL)

    private const val MODE = "switcher"
}

/** What the switcher page reaches through the bridge (switcher.close, switcher.home). */
interface SwitcherSlot {
    /** Away: what's under it shows again (the app it was opened over, or home). */
    fun close()

    /** To home. */
    fun home()
}

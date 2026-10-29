package dev.omalauncher.system

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.omalauncher.shell.EXTRA_HOME_PANEL
import dev.omalauncher.shell.ShellActivity
import org.json.JSONObject

/**
 * One launcher (the user, 2026-10-29: "Why do we have two different launchers? Like when I swipe up in the home, it's
 * different from when I swap up on the bottom"): a bottom corner's swipe up ([dev.omalauncher.system.gesture.CornerPull])
 * drives home's own drawer - the same one home's swipe up, the pill and the edge gestures' "app drawer" open
 * (shell/ui/drawer.tsx in home's page, shell/ui/gesture.ts "pull.begin" / "pull.drag" / "pull.end"). Over an app home is
 * brought forward as the swipe starts, with no transition, and its launcher follows the finger from its first frame;
 * over floating windows it's lifted over them as from home (shell/PanelLift). There's no second launcher window.
 *
 * Opened over an app and shut again without opening anything, that app comes back (as the old over-apps window
 * went away and left it showing).
 */
object HomePull {
    private const val TAG = "PowosHomePull"

    /** How long after the launcher shut the app it was pulled over is brought back, if nothing else came up. */
    private const val BACK_MS = 450L

    private val main = Handler(Looper.getMainLooper())

    @Volatile private var appContext: Context? = null

    /** The app home was brought over by the pull now open (its task), else null. */
    @Volatile private var over: Int? = null

    private var kind = "apps"

    private fun emit(
        event: String,
        data: JSONObject,
    ) {
        Switcher.homePage?.emit(event, data)
    }

    /** A corner swipe started: the launcher ([kind] "apps" or "ai") comes up with the finger. */
    fun begin(
        context: Context,
        kind: String,
    ) {
        if (DeviceLock.locked(context)) return
        this.kind = kind
        appContext = context.applicationContext
        emit("pull.begin", JSONObject().put("kind", kind))
        if (Switcher.homeVisible) {
            over = null
            return
        }
        over = runCatching { Tasks.visible(context) }.getOrNull()
        runCatching {
            context.startActivity(
                Intent(context, ShellActivity::class.java)
                    .setAction(Intent.ACTION_MAIN)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
            )
        }.onFailure { Log.w(TAG, "home not brought forward", it) }
    }

    /** [p] 0..1: how far up the launcher is. */
    fun drag(p: Float) = emit("pull.drag", JSONObject().put("p", p.coerceIn(0f, 1f).toDouble()))

    fun end(
        context: Context,
        open: Boolean,
    ) {
        val page = Switcher.homePage
        if (page != null) {
            page.emit("pull.end", JSONObject().put("open", open))
        } else if (open) {
            // Home's page wasn't there to follow (its activity being made again): it opens with the launcher up.
            runCatching {
                context.startActivity(
                    Intent(context, ShellActivity::class.java)
                        .setAction(Intent.ACTION_MAIN)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
                        .putExtra(EXTRA_HOME_PANEL, kind),
                )
            }
        }
        if (!open) closed()
    }

    /**
     * The launcher shut (the page said "panels.closed", or the pull was let go short): the app it was pulled over comes
     * back - unless an app came up from it meanwhile.
     */
    fun closed() {
        val task = over ?: return
        val context = appContext ?: return
        over = null
        // HACK: "nothing else came up" is read off what's in front a moment later (a launch from the drawer shuts it
        // first, then its app comes up); the real fix is the page telling the host it launched something
        // (state.ts launch -> a "panels.launched" call) so the return is decided at once, not by time.
        main.postDelayed({
            if (Switcher.homeVisible && runCatching { Tasks.visible(context) }.getOrNull() == null) {
                Log.i(TAG, "launcher shut over task $task: back to it")
                runCatching { Tasks.open(context, task) }
            }
        }, BACK_MS)
    }
}

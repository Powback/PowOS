package dev.omalauncher.system

import android.content.Context
import android.content.Intent
import android.util.Log
import dev.omalauncher.shell.EXTRA_HOME_PANEL
import dev.omalauncher.shell.ShellActivity
import org.json.JSONObject

/**
 * One launcher (the user, 2026-10-29: "Why do we have two different launchers? Like when I swipe up in the home, it's
 * different from when I swap up on the bottom"): a bottom corner's swipe up ([dev.omalauncher.system.gesture.CornerPull])
 * drives home's own drawer - the same one home's swipe up, the pill and the edge gestures' "app drawer" open
 * (shell/ui/drawer.tsx in home's page, shell/ui/gesture.ts "pull.begin" / "pull.drag" / "pull.end"). Over an app the
 * swipe is Android's own go-home: home comes up with the system's home transition and its launcher follows the finger,
 * as any launcher's swipe up from an app does. Shut, you're on home - nothing is brought back (the user, 2026-10-29,
 * of bringing home over the app without a transition and the app back after: "wtf that sounds like a hack").
 */
object HomePull {
    private const val TAG = "PowosHomePull"

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
        emit("pull.begin", JSONObject().put("kind", kind))
        if (Switcher.homeVisible) return
        // Over an app: go home, the system's way (its home transition), as a swipe up from an app does.
        runCatching {
            context.startActivity(
                Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).setPackage(context.packageName)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }.onFailure { Log.w(TAG, "can't go home", it) }
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
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        .putExtra(EXTRA_HOME_PANEL, kind),
                )
            }
        }
    }
}

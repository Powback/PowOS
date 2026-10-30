package dev.omalauncher.shell

import android.content.Context
import android.util.Log

/**
 * PowOS's own split screen (docs/WEB_WINDOWS.md "Tiles"): the tiles, their dividers, the snap hint and the tile menu are
 * the page's now (shell/ui/webwindows.tsx, "Element model") - DOM, drawn and hit-tested by the page. What stays native
 * is OnePlus's own split entry points, which must be off while PowOS tiles.
 */
object WebWindowTiles {
    private const val TAG = "PowosWebWindows"

    /**
     * OnePlus's own ways into Android's split, off while web windows are on (PowOS tiles instead), back to what they
     * were when it goes off: Settings.Secure double_finger_split_screen_enable (OxygenOS's swipe-down-with-fingers
     * split gesture) and Settings.System recommender_split_screen_enable (its split suggestions), both 1 on the
     * phone (read 2026-10-30). The switcher's own entry is the page's (ui/recents.tsx). At SystemUI's connect, off
     * the main thread.
     * HACK: OxygenOS's private settings keys, written as root (WRITE_SECURE_SETTINGS); real fix: a device config
     * without those entry points when the shell owns split screen.
     */
    fun splitEntryPoints(context: Context) {
        val app = context.applicationContext
        Thread({
            runCatching {
                val prefs = app.getSharedPreferences("powos_split_entry_points", Context.MODE_PRIVATE)
                val on = WebWindows.on(app)
                for ((ns, key) in OPLUS_SPLIT) entryPoint(prefs, on, "$ns $key")
            }.onFailure { Log.w(TAG, "OnePlus split entry points not changed", it) }
        }, "powos-ww-split-entry").start()
    }

    /** One entry point ("<namespace> <key>"): 0 while [on] (its value kept), else back to the kept value. */
    private fun entryPoint(
        prefs: android.content.SharedPreferences,
        on: Boolean,
        setting: String,
    ) {
        val now = andro.marchy.RootShell.run("settings get $setting").output.trim()
        val saved = prefs.getString(setting, null)
        if (on && now != "0") {
            prefs.edit().putString(setting, now).apply()
            andro.marchy.RootShell.run("settings put $setting 0")
            Log.i(TAG, "web windows on: OnePlus split entry $setting $now -> 0 (PowOS tiles instead)")
        } else if (!on && saved != null) {
            if (saved != "null") andro.marchy.RootShell.run("settings put $setting $saved")
            prefs.edit().remove(setting).apply()
            Log.i(TAG, "web windows off: OnePlus split entry $setting back to $saved")
        }
    }

    private val OPLUS_SPLIT = listOf("secure" to "double_finger_split_screen_enable", "system" to "recommender_split_screen_enable")
}

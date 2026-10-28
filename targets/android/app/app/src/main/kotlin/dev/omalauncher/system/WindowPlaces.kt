package dev.omalauncher.system

import android.content.Context
import android.graphics.Rect

/**
 * Where each app's floating window was last put by hand (a drag or resize ended: WindowFrames.placed), per screen -
 * the inner screen's place is not the cover's. Key: the app's package (+ a Linux window's app/title: PowOS's own
 * tasks all share PowOS's package) and the screen. Kept across restarts (SharedPreferences); always read back through
 * AppWindows.onScreen, so a place saved under another bottom bar or screen size never comes back off the screen.
 */
object WindowPlaces {
    private const val PREFS = "window_places"

    /** The key for [pkg]'s window ([linux]: a Linux window's app id/title); null without a package. */
    fun key(
        context: Context,
        pkg: String?,
        linux: String? = null,
    ): String? {
        pkg ?: return null
        val screen = if (context.resources.configuration.smallestScreenWidthDp >= 600) "inner" else "cover"
        return listOfNotNull(pkg, linux?.takeIf { it.isNotBlank() }, screen).joinToString("|")
    }

    /** [key]'s saved place, already on screen (AppWindows.onScreen); null if none. */
    fun get(
        context: Context,
        key: String?,
    ): Rect? {
        key ?: return null
        val s = prefs(context).getString(key, null) ?: return null
        val r = Rect.unflattenFromString(s)?.takeIf { !it.isEmpty } ?: return null
        return AppWindows.onScreen(context, r)
    }

    fun put(
        context: Context,
        key: String?,
        bounds: Rect,
    ) {
        if (key == null || bounds.isEmpty) return
        prefs(context).edit().putString(key, bounds.flattenToString()).apply()
    }

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

package dev.omalauncher

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * The apps pinned to the drawer's dock, the row by the bar that's always there (like the iOS dock), in the order
 * they were pinned. Keys as [AppUsage]'s; ones no longer installed are skipped where the row is drawn, and kept, so a
 * reinstalled app comes back to its place.
 */
class DrawerPins(
    context: Context,
) {
    private val prefs = context.getSharedPreferences("drawer_pins", Context.MODE_PRIVATE)

    var keys by mutableStateOf(prefs.getString(KEY, null)?.split('\n')?.filter { it.isNotEmpty() }.orEmpty())
        private set

    operator fun contains(key: String) = key in keys

    fun pin(key: String) {
        if (key in keys) return
        save(keys + key)
    }

    fun unpin(key: String) = save(keys - key)

    private fun save(new: List<String>) {
        keys = new
        prefs.edit().putString(KEY, new.joinToString("\n")).apply()
    }

    private companion object {
        const val KEY = "keys"
    }
}

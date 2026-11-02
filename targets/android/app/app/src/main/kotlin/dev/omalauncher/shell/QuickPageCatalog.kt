package dev.omalauncher.shell

import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * The control center's "add quick page" list (quickpage.pages; shell ui/launchers.tsx QuickPagePicker): the settings
 * pages THIS device really has, each with the page's own name and picture (the user, 11-02: "real settings icons, not
 * all the gear"). Candidates are Android's public settings actions (Settings.ACTION_*, stable: what an item stores);
 * each is resolved on the device - one no activity answers, or that this app may not open, isn't offered. A page's
 * picture is its activity's own icon (AOSP's Settings declares one per page: ic_settings_wireless, _bluetooth, ...);
 * an activity with none would draw the Settings app's gear, so it sends none and the shell draws the page's glyph.
 */
object QuickPageCatalog {
    /** One candidate: the action an item stores, the name used when the activity has none of its own. */
    data class Candidate(val action: String, val label: String)

    /** What the device answered for a candidate: its activity's own label / icon, if it has them. */
    data class Resolved(val label: String?, val icon: String?, val mono: Boolean)

    // Navigation actions that need no package/account URI or other arguments, in the list's order.
    val CANDIDATES = listOf(
        Candidate("android.settings.WIFI_SETTINGS", "Wi-Fi"),
        Candidate("android.settings.BLUETOOTH_SETTINGS", "Bluetooth"),
        Candidate("android.settings.WIRELESS_SETTINGS", "Network & internet"),
        Candidate("android.settings.DATA_USAGE_SETTINGS", "Data usage"),
        Candidate("android.settings.VPN_SETTINGS", "VPN"),
        Candidate("android.settings.NFC_SETTINGS", "NFC"),
        Candidate("android.settings.DISPLAY_SETTINGS", "Display"),
        Candidate("android.settings.SOUND_SETTINGS", "Sound"),
        Candidate("android.settings.ZEN_MODE_SETTINGS", "Do not disturb"),
        Candidate("android.intent.action.POWER_USAGE_SUMMARY", "Battery"),
        Candidate("android.settings.BATTERY_SAVER_SETTINGS", "Battery saver"),
        Candidate("android.settings.LOCATION_SOURCE_SETTINGS", "Location"),
        Candidate("android.settings.APPLICATION_SETTINGS", "Apps"),
        Candidate("android.settings.ALL_APPS_NOTIFICATION_SETTINGS", "Notifications"),
        Candidate("android.settings.INTERNAL_STORAGE_SETTINGS", "Storage"),
        Candidate("android.settings.SECURITY_SETTINGS", "Security"),
        Candidate("android.settings.PRIVACY_SETTINGS", "Privacy"),
        Candidate("android.settings.ACCESSIBILITY_SETTINGS", "Accessibility"),
        Candidate("android.settings.INPUT_METHOD_SETTINGS", "Keyboard"),
        Candidate("android.settings.LOCALE_SETTINGS", "Languages"),
        Candidate("android.settings.DATE_SETTINGS", "Date & time"),
        Candidate("android.settings.SYNC_SETTINGS", "Accounts"),
        Candidate("android.settings.DEVICE_INFO_SETTINGS", "About phone"),
        Candidate("android.settings.APPLICATION_DEVELOPMENT_SETTINGS", "Developer options"),
    )

    /**
     * The list: each candidate [resolve] answers (null: the device has no such page, or it can't be opened), once per
     * page (two actions landing on one page - e.g. Wi-Fi and Network on some OEMs' - keep the first, by [page] key).
     */
    fun offer(
        candidates: List<Candidate>,
        resolve: (Candidate) -> Pair<String, Resolved>?,
    ): List<JSONObject> {
        val seen = HashSet<String>()
        return candidates.mapNotNull { c ->
            val (page, r) = resolve(c) ?: return@mapNotNull null
            if (!seen.add(page)) return@mapNotNull null
            JSONObject().put("action", c.action).put("label", r.label?.takeIf { it.isNotBlank() } ?: c.label)
                .putOpt("icon", r.icon).put("mono", r.icon != null && r.mono)
        }
    }

    /**
     * A one-colour picture (AOSP's page icons are tinted vectors; drawn without the Settings theme they come out one
     * flat colour): the shell tints it with the theme instead of showing it as drawn. [argb]: its pixels.
     */
    fun monochrome(argb: IntArray): Boolean {
        var shown = 0
        for (p in argb) {
            if (p ushr 24 < 32) continue
            shown++
            val r = p shr 16 and 0xff
            val g = p shr 8 and 0xff
            val b = p and 0xff
            if (maxOf(r, g, b) - minOf(r, g, b) > 40) return false
        }
        return shown > 0
    }

    fun pages(context: Context): JSONArray {
        val pm = context.packageManager
        return JSONArray(offer(CANDIDATES) { c -> resolve(context, pm, c) })
    }

    private fun resolve(
        context: Context,
        pm: PackageManager,
        c: Candidate,
    ): Pair<String, Resolved>? {
        val info = runCatching { pm.resolveActivity(Intent(c.action), PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo }.getOrNull() ?: return null
        if (!openable(context, info) || chooser(info.packageName, info.name)) return null
        // The activity's own name only (labelRes 0: loadLabel would answer the app's, "Settings").
        val label = if (info.labelRes != 0 || info.nonLocalizedLabel != null) runCatching { info.loadLabel(pm).toString() }.getOrNull() else null
        val drawn = if (info.icon != 0) runCatching { draw(info.loadIcon(pm)) }.getOrNull() else null
        return "${info.packageName}/${info.name}" to Resolved(label, drawn?.first, drawn?.second ?: false)
    }

    /**
     * The system's "Complete action using" chooser (the phone, 11-02: a "Complete action" item in the list): two apps
     * answer the action, so a tap would ask which - not a page. Not offered.
     */
    fun chooser(pkg: String, name: String) = pkg == "android" && (name.endsWith("ResolverActivity") || name.endsWith("ChooserActivity"))

    private fun openable(
        context: Context,
        info: ActivityInfo,
    ) = info.exported && info.enabled && (info.permission == null || context.checkSelfPermission(info.permission) == PackageManager.PERMISSION_GRANTED)

    /** [drawable] as a PNG data URL, and whether it's one colour ([monochrome]). */
    private fun draw(drawable: android.graphics.drawable.Drawable): Pair<String, Boolean> {
        val size = 96
        val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(android.graphics.Canvas(bitmap))
        val pixels = IntArray(size * size).also { bitmap.getPixels(it, 0, size, 0, 0, size, size) }
        val png = java.io.ByteArrayOutputStream().also { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        bitmap.recycle()
        return "data:image/png;base64," + android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP) to monochrome(pixels)
    }
}

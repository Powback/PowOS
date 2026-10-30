package dev.omalauncher.shell

import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject

/** Public Android settings destinations, resolved on this device before advertising them. */
class SettingsSearch(private val context: Context) {
    private data class Page(val action: String, val label: String, val keywords: String)

    /**
     * Every destination with the app it opens in: "package", that app's name ("app") and, for one that isn't a launcher
     * app, its picture ("appIcon", a PNG data URL) - the launcher lists each app's settings under it (shell/search.ts group). Copies: the index's snapshot is shared.
     */
    fun destinations(changed: () -> Unit = {}): JSONArray = JSONArray().apply {
        val indexed = NativeSettingsIndex.destinations(context, changed)
        for (i in 0 until indexed.length()) put(withApp(JSONObject(indexed.getJSONObject(i).toString())))
        pages.forEach { page ->
            val pkg = resolve(page)?.packageName ?: return@forEach
            put(withApp(JSONObject().put("id", "settings:${page.action}").put("label", page.label).put("keywords", page.keywords).put("package", pkg)))
        }
    }

    private fun withApp(entry: JSONObject): JSONObject {
        val pkg = entry.optString("package").ifBlank { return entry }
        val app = appOf(pkg) ?: return entry
        return entry.put("app", app.first).putOpt("appIcon", app.second)
    }

    /** [pkg]'s name and icon, read once per package (labels follow the locale: cleared with it). */
    private fun appOf(pkg: String): Pair<String, String?>? {
        val locale = java.util.Locale.getDefault().toLanguageTag()
        synchronized(apps) {
            if (appsLocale != locale) { apps.clear(); appsLocale = locale }
            apps[pkg]?.let { return it }
        }
        val pm = context.packageManager
        val info = runCatching { pm.getApplicationInfo(pkg, 0) }.getOrNull() ?: return null
        // A launcher app's picture is the launcher's own (the page has it, themed); only the others' travel, as data -
        // on each of their entries, so never on the thousands of the Settings app's.
        val drawn = pm.getLaunchIntentForPackage(pkg) == null
        val app = pm.getApplicationLabel(info).toString() to (if (drawn) runCatching { iconUrl(pm.getApplicationIcon(info)) }.getOrNull() else null)
        synchronized(apps) { apps[pkg] = app }
        return app
    }

    private fun iconUrl(drawable: android.graphics.drawable.Drawable): String {
        val size = 96
        val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(android.graphics.Canvas(bitmap))
        val png = java.io.ByteArrayOutputStream().also { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        bitmap.recycle()
        return "data:image/png;base64," + android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP)
    }

    fun open(id: String) {
        if (id.startsWith("indexed:")) return NativeSettingsIndex.open(context, id)
        val page = pages.firstOrNull { "settings:${it.action}" == id } ?: error("Unknown settings page")
        check(available(page)) { "Settings page unavailable" }
        dev.omalauncher.system.AppWindows.startActivity(context, intent(page))
    }

    private fun intent(page: Page) = Intent("android.settings.${page.action}")

    private fun available(page: Page): Boolean = resolve(page) != null

    /** The activity [page] opens, when this app may open it. */
    private fun resolve(page: Page): android.content.pm.ActivityInfo? {
        val info = context.packageManager.resolveActivity(intent(page), android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo ?: return null
        return info.takeIf { it.exported && it.enabled && (it.permission == null || context.checkSelfPermission(it.permission) == android.content.pm.PackageManager.PERMISSION_GRANTED) }
    }

    companion object {
        private val apps = HashMap<String, Pair<String, String?>>()
        private var appsLocale = ""

        // Only navigation actions that need no package/account URI or other arguments.
        private val pages = listOf(
            Page("VPN_SETTINGS", "VPN", "virtual private network tunnel wireguard"),
            Page("WIFI_SETTINGS", "Wi-Fi", "wifi wireless internet network"),
            Page("BLUETOOTH_SETTINGS", "Bluetooth", "pairing headphones connected devices"),
            Page("WIRELESS_SETTINGS", "Network & internet", "connections wireless airplane hotspot tethering"),
            Page("DATA_ROAMING_SETTINGS", "Mobile network", "cellular sim roaming mobile data"),
            Page("DATA_USAGE_SETTINGS", "Data usage", "mobile wifi limit consumption"),
            Page("LOCATION_SOURCE_SETTINGS", "Location", "gps positioning permissions"),
            Page("NFC_SETTINGS", "NFC", "contactless payments"),
            Page("DISPLAY_SETTINGS", "Display", "brightness screen timeout resolution refresh rate rotation"),
            Page("SOUND_SETTINGS", "Sound & vibration", "volume ringtone audio vibrate"),
            Page("ZEN_MODE_SETTINGS", "Do not disturb", "dnd focus interruptions"),
            Page("ALL_APPS_NOTIFICATION_SETTINGS", "App notifications", "alerts notifications permissions"),
            Page("BATTERY_SAVER_SETTINGS", "Battery saver", "power battery energy"),
            Page("INTERNAL_STORAGE_SETTINGS", "Storage", "space disk files memory"),
            Page("MANAGE_APPLICATIONS_SETTINGS", "Apps", "applications installed default uninstall"),
            Page("SECURITY_SETTINGS", "Security", "lock fingerprint password biometrics"),
            Page("PRIVACY_SETTINGS", "Privacy", "personal data privacy"),
            Page("ACCESSIBILITY_SETTINGS", "Accessibility", "talkback screen reader hearing vision"),
            Page("INPUT_METHOD_SETTINGS", "Keyboard", "typing input language"),
            Page("LOCALE_SETTINGS", "Languages", "language locale region"),
            Page("DATE_SETTINGS", "Date & time", "clock timezone time zone"),
            Page("SYNC_SETTINGS", "Accounts", "account sync synchronization"),
            Page("DEVICE_INFO_SETTINGS", "About phone", "android version device model build"),
            Page("APPLICATION_DEVELOPMENT_SETTINGS", "Developer options", "adb usb debugging developer"),
        )
    }
}

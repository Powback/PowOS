package dev.omalauncher.shell

import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject

/** Public Android settings destinations, resolved on this device before advertising them. */
class SettingsSearch(private val context: Context) {
    private data class Page(val action: String, val label: String, val keywords: String)

    fun destinations(changed: () -> Unit = {}): JSONArray = JSONArray().apply {
        val indexed = NativeSettingsIndex.destinations(context, changed)
        for (i in 0 until indexed.length()) put(indexed.getJSONObject(i))
        pages.filter { available(it) }.forEach { page ->
            put(JSONObject().put("id", "settings:${page.action}").put("label", page.label).put("keywords", page.keywords))
        }
    }

    fun open(id: String) {
        if (id.startsWith("indexed:")) return NativeSettingsIndex.open(context, id)
        val page = pages.firstOrNull { "settings:${it.action}" == id } ?: error("Unknown settings page")
        check(available(page)) { "Settings page unavailable" }
        context.startActivity(intent(page).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), dev.omalauncher.system.AppWindows.bundle(context))
    }

    private fun intent(page: Page) = Intent("android.settings.${page.action}")

    private fun available(page: Page): Boolean {
        val info = context.packageManager.resolveActivity(intent(page), android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo ?: return false
        return info.exported && info.enabled && (info.permission == null || context.checkSelfPermission(info.permission) == android.content.pm.PackageManager.PERMISSION_GRANTED)
    }

    companion object {
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

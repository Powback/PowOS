package dev.omalauncher.shell

import android.app.UiModeManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.location.LocationManager
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.nfc.NfcAdapter
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.service.quicksettings.Tile
import android.service.notification.NotificationListenerService
import android.telephony.TelephonyManager
import android.util.Log
import dev.omalauncher.widgets.runtime.MediaListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * The control center's state and switches (shell/ui/control.tsx, and the notification panel's row): every tile the
 * phone's own control center has, in its order (SystemUI's sysui_qs_tiles), and the brightness and volume sliders.
 *
 * What an app may switch, it switches itself: the flashlight (CameraManager), do not disturb (the notification
 * listener's interruption filter), brightness and auto-rotate (system settings, WRITE_SETTINGS), volume and the ringer
 * (AudioManager). The rest - Wi-Fi, Bluetooth, mobile data, airplane mode, location, dark mode, battery saver, NFC -
 * Android lets only its own UI switch: those go through the root session PowOS runs anyway ([root]).
 *
 * HACK: the switches through root (svc / cmd / settings in a su shell). Real fix: the privileged permissions SystemUI's
 * tiles hold (NETWORK_SETTINGS, BLUETOOTH_PRIVILEGED, MODIFY_PHONE_STATE, WRITE_SECURE_SETTINGS, MODIFY_DAY_NIGHT_MODE,
 * DEVICE_POWER) on the PowOS system app's allowlist (system-module/privapp-permissions.txt) - most are signature-only.
 */
class QuickSettings(
    private val context: Context,
    private val changed: () -> Unit,
) {
    /** A third-party tile opened something (its activity, its dialog): the control center to go, as SystemUI's does. */
    var collapse: () -> Unit = {}

    /** The third-party tiles, hosted once per process ([TileHost]): their changes come here as the rest do. */
    private val tileListener = TileHost.Listener(changed = { changed() }, collapse = { collapse() })

    private val main = Handler(Looper.getMainLooper())
    private val cameras = context.getSystemService(CameraManager::class.java)
    private val audio = context.getSystemService(AudioManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)
    private val wifi = context.getSystemService(WifiManager::class.java)
    private val location = context.getSystemService(LocationManager::class.java)
    private val uiMode = context.getSystemService(UiModeManager::class.java)
    private val telephony = context.getSystemService(TelephonyManager::class.java)
    private val nfc: NfcAdapter? = runCatching { NfcAdapter.getDefaultAdapter(context) }.getOrNull()
    private var torch = false
    private val torchCamera: String? =
        runCatching { cameras.cameraIdList.firstOrNull { cameras.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true } }.getOrNull()

    private val torchCallback =
        object : CameraManager.TorchCallback() {
            override fun onTorchModeChanged(
                cameraId: String,
                enabled: Boolean,
            ) {
                if (cameraId != torchCamera) return
                torch = enabled
                changed()
            }
        }

    /** Any system or global setting changing (Wi-Fi, airplane, brightness...): the state again, once per burst. */
    private val pending = Runnable { changed() }
    private val settingsObserver =
        object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean) {
                main.removeCallbacks(pending)
                main.postDelayed(pending, 150)
            }
        }

    init {
        cameras.registerTorchCallback(torchCallback, main)
        for (uri in listOf(Settings.Global.CONTENT_URI, Settings.System.CONTENT_URI, Settings.Secure.CONTENT_URI)) {
            context.contentResolver.registerContentObserver(uri, true, settingsObserver)
        }
        grantWriteSettings()
        TileHost.attach(context, tileListener)
        loadOrder()
    }

    fun state(): JSONObject {
        val dnd = MediaListener.connected?.currentInterruptionFilter?.let { it > NotificationListenerService.INTERRUPTION_FILTER_ALL }
        val tiles = JSONArray()
        for (id in order ?: DEFAULT_ORDER) tile(id)?.let(tiles::put)
        return JSONObject()
            .put("torch", if (torchCamera == null) JSONObject.NULL else torch)
            // null: unknown (no notification access yet), so the tile can't switch it.
            .put("dnd", dnd ?: JSONObject.NULL)
            .put("tiles", tiles)
            .put("brightness", brightness())
            .put("volume", volume())
    }

    /** One tile: { id, label, on (true/false, null: not a switch), detail, app (a third-party tile's package) }. */
    private fun tile(id: String): JSONObject? {
        val t = JSONObject().put("id", id)
        fun sw(
            label: String,
            on: Boolean?,
            detail: String? = null,
        ) = t.put("label", label).put("on", on ?: JSONObject.NULL).put("detail", detail ?: JSONObject.NULL)
        return when (id) {
            "wifi" -> sw("Wi-Fi", wifi?.isWifiEnabled)
            "bt" -> sw("Bluetooth", global("bluetooth_on") == 1)
            "cell" -> sw("Mobile data", global("mobile_data") == 1, telephony?.networkOperatorName?.takeIf { it.isNotBlank() })
            "flashlight" -> if (torchCamera == null) null else sw("Torch", torch)
            "location" -> sw("Location", location?.isLocationEnabled)
            "airplane" -> sw("Airplane mode", global(Settings.Global.AIRPLANE_MODE_ON) == 1)
            "rotation" -> sw("Auto-rotate", system(Settings.System.ACCELEROMETER_ROTATION) == 1)
            "dnd" -> sw("Do not disturb", MediaListener.connected?.currentInterruptionFilter?.let { it > NotificationListenerService.INTERRUPTION_FILTER_ALL })
            "darkmode" -> sw("Dark mode", uiMode?.nightMode == UiModeManager.MODE_NIGHT_YES)
            "hotspot" -> sw("Hotspot", hotspotOn())
            "nfc" -> if (nfc == null) null else sw("NFC", nfc.isEnabled)
            "battery", "powersave" -> sw("Battery saver", power.isPowerSaveMode)
            "controls" -> sw("Device controls", null)
            "wallet" -> sw("Wallet", null)
            "screenshot" -> sw("Screenshot", null)
            "screenrecord" -> sw("Screen record", null)
            "calculator" -> sw("Calculator", null)
            "lockscreen" -> sw("Lock", null)
            "qr_code_scanner" -> sw("Scan QR code", null)
            // OnePlus's battery saver tile: the system's own battery saver, the same switch.
            else ->
                if (id.contains("com.oplus.battery/")) {
                    tile("battery")
                } else {
                    custom(id)?.let { (cn, label) ->
                        // Hosted ([TileHost]) and reported: its own state, a switch here. Until then, null: it opens.
                        val hosted = TileHost.state(id)
                        when {
                            hosted == null -> sw(label, null)
                            hosted.state == Tile.STATE_UNAVAILABLE -> sw(hosted.label?.toString() ?: label, null, "unavailable")
                            else -> sw(hosted.label?.toString() ?: label, hosted.state == Tile.STATE_ACTIVE, hosted.subtitle?.toString())
                        }.put("app", cn.packageName)
                    }
                }
        }
    }

    /** A third-party tile (custom(pkg/cls)): its component and the label its service declares. */
    private fun custom(id: String): Pair<ComponentName, String>? {
        val spec = id.removePrefix("custom(").removeSuffix(")").takeIf { id.startsWith("custom(") } ?: return null
        val cn = ComponentName.unflattenFromString(spec) ?: return null
        val info = runCatching { context.packageManager.getServiceInfo(cn, 0) }.getOrNull() ?: return null
        return cn to info.loadLabel(context.packageManager).toString()
    }

    fun toggle(name: String) {
        when (name) {
            "torch", "flashlight" -> torchCamera?.let { cameras.setTorchMode(it, !torch) }
            "dnd" ->
                MediaListener.connected?.let {
                    val on = it.currentInterruptionFilter > NotificationListenerService.INTERRUPTION_FILTER_ALL
                    it.requestInterruptionFilter(
                        if (on) NotificationListenerService.INTERRUPTION_FILTER_ALL else NotificationListenerService.INTERRUPTION_FILTER_PRIORITY,
                    )
                    changed()
                }
            "wifi" -> root("svc wifi ${if (wifi?.isWifiEnabled == true) "disable" else "enable"}")
            "bt" -> root("svc bluetooth ${if (global("bluetooth_on") == 1) "disable" else "enable"}")
            "cell" -> root("svc data ${if (global("mobile_data") == 1) "disable" else "enable"}")
            "airplane" -> root("cmd connectivity airplane-mode ${if (global(Settings.Global.AIRPLANE_MODE_ON) == 1) "disable" else "enable"}")
            "location" -> root("cmd location set-location-enabled ${location?.isLocationEnabled != true}")
            "rotation" -> setSystem(Settings.System.ACCELEROMETER_ROTATION, if (system(Settings.System.ACCELEROMETER_ROTATION) == 1) 0 else 1)
            "darkmode" -> root("cmd uimode night ${if (uiMode?.nightMode == UiModeManager.MODE_NIGHT_YES) "no" else "yes"}")
            "nfc" -> root("svc nfc ${if (nfc?.isEnabled == true) "disable" else "enable"}")
            "battery", "powersave" -> root("cmd power set-mode ${if (power.isPowerSaveMode) 0 else 1}")
            "hotspot" -> open("hotspot")
            // Actions, not switches: the panel shuts first (the page does), then they run.
            "screenshot" -> main.postDelayed({ root("input keyevent KEYCODE_SYSRQ") }, PANEL_GONE_MS)
            "lockscreen" -> root("input keyevent KEYCODE_SLEEP")
            // A third-party tile switches in place when it's hosted ([TileHost]), else opens.
            else -> if (!TileHost.click(name)) open(name)
        }
    }

    /** Whether this page shows the control center: the third-party tiles listen (and report) while one does. */
    fun listening(on: Boolean) = TileHost.listening(this, on)

    /** A slider moved: brightness or volume, 0..1. */
    fun set(
        name: String,
        value: Double,
    ) {
        val v = value.coerceIn(0.0, 1.0)
        when (name) {
            "brightness" -> {
                setSystem(Settings.System.SCREEN_BRIGHTNESS_MODE, Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
                // The slider is perceptual, the setting linear: squared, as Android's own slider roughly does.
                setSystem(Settings.System.SCREEN_BRIGHTNESS, (BRIGHTNESS_MIN + (brightnessMax - BRIGHTNESS_MIN) * v * v).roundToInt())
            }
            "auto-brightness" ->
                setSystem(
                    Settings.System.SCREEN_BRIGHTNESS_MODE,
                    if (v > 0) Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC else Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL,
                )
            "volume" -> {
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                audio.setStreamVolume(AudioManager.STREAM_MUSIC, (max * v).roundToInt(), 0)
                changed()
            }
            "ringer" -> {
                audio.ringerMode = (v * 2).roundToInt().coerceIn(0, 2)
                changed()
            }
            else -> error("no slider $name")
        }
    }

    private fun brightness(): JSONObject {
        val raw = system(Settings.System.SCREEN_BRIGHTNESS) ?: 0
        val q = ((raw - BRIGHTNESS_MIN).toDouble() / (brightnessMax - BRIGHTNESS_MIN)).coerceIn(0.0, 1.0)
        return JSONObject()
            .put("value", sqrt(q))
            .put("auto", system(Settings.System.SCREEN_BRIGHTNESS_MODE) == Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC)
    }

    private fun volume(): JSONObject {
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        return JSONObject()
            .put("value", audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max)
            // 0 silent, 1 vibrate, 2 ring (AudioManager.RINGER_MODE_*).
            .put("ringer", audio.ringerMode)
    }

    /** The brightness setting's top: the framework's (this phone goes past 255). */
    private val brightnessMax: Int by lazy {
        val res = context.resources
        val id = res.getIdentifier("config_screenBrightnessSettingMaximum", "integer", "android")
        (if (id != 0) runCatching { res.getInteger(id) }.getOrNull() else null)?.takeIf { it > BRIGHTNESS_MIN } ?: 255
    }

    /**
     * HACK: the hotspot's state is hidden API (WifiManager.isWifiApEnabled, a system API). Real fix: TetheringManager's
     * callback, which takes TETHER_PRIVILEGED (signature).
     */
    private fun hotspotOn(): Boolean? = runCatching { wifi?.javaClass?.getMethod("isWifiApEnabled")?.invoke(wifi) as? Boolean }.getOrNull()

    /** Android's own page for [name] (a tile's long press, or a tile that's a page): a tile id, or wifi/bluetooth/internet/settings. */
    fun open(name: String) {
        if (name.startsWith("settings:") || name.startsWith("indexed:") || name.startsWith("search:")) {
            SettingsSearch(context).open(name)
            return
        }
        val intent =
            when (name) {
                "wifi" -> Intent(Settings.ACTION_WIFI_SETTINGS)
                "internet" -> Intent(Settings.Panel.ACTION_INTERNET_CONNECTIVITY)
                "bt", "bluetooth" -> Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
                "cell" -> Intent(Settings.ACTION_NETWORK_OPERATOR_SETTINGS)
                "location" -> Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                "airplane" -> Intent(Settings.ACTION_AIRPLANE_MODE_SETTINGS)
                "rotation", "brightness" -> Intent(Settings.ACTION_DISPLAY_SETTINGS)
                "dnd" -> Intent("android.settings.ZEN_MODE_SETTINGS")
                "darkmode" -> Intent("android.settings.DARK_THEME_SETTINGS")
                "hotspot" -> Intent().setComponent(ComponentName("com.android.settings", "com.android.settings.TetherSettings"))
                "nfc" -> Intent(Settings.ACTION_NFC_SETTINGS)
                "battery", "powersave" -> Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
                "volume" -> Intent(Settings.ACTION_SOUND_SETTINGS)
                "flashlight", "torch" -> null
                "controls" -> Intent().setComponent(ComponentName("com.android.systemui", "com.android.systemui.controls.ui.ControlsActivity"))
                "wallet" -> launch("com.google.android.apps.walletnfcrel") ?: Intent("android.settings.NFC_PAYMENT_SETTINGS")
                "screenrecord" -> launch("com.oplus.screenrecorder")
                "calculator" -> Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_CALCULATOR)
                "qr_code_scanner" -> qrScanner()
                "settings" -> Intent(Settings.ACTION_SETTINGS)
                else ->
                    // A third-party tile: its own settings (the tile's long press), else its app.
                    custom(name)?.first?.let { cn ->
                        Intent("android.service.quicksettings.action.QS_TILE_PREFERENCES").setPackage(cn.packageName)
                            .takeIf { context.packageManager.resolveActivity(it, 0) != null } ?: launch(cn.packageName)
                    } ?: error("no quick setting $name")
            } ?: return
        runCatching { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), dev.omalauncher.system.AppWindows.bundle(context)) }
            .onFailure { Log.w(TAG, "can't open $name", it) }
    }

    private fun launch(pkg: String): Intent? = context.packageManager.getLaunchIntentForPackage(pkg)

    /** The phone's QR scanner, as SystemUI's tile finds it (config_defaultQrCodeComponent). */
    private fun qrScanner(): Intent? {
        val res = context.resources
        val id = res.getIdentifier("config_defaultQrCodeComponent", "string", "android")
        val cn = (if (id != 0) res.getString(id) else "").let(ComponentName::unflattenFromString) ?: return null
        return Intent().setComponent(cn)
    }

    private fun global(key: String): Int? = runCatching { Settings.Global.getInt(context.contentResolver, key) }.getOrNull()

    private fun system(key: String): Int? = runCatching { Settings.System.getInt(context.contentResolver, key) }.getOrNull()

    private fun setSystem(
        key: String,
        value: Int,
    ) {
        if (Settings.System.canWrite(context)) {
            Settings.System.putInt(context.contentResolver, key, value)
        } else {
            root("settings put system $key $value")
        }
    }

    /**
     * WRITE_SETTINGS (an app op the user grants in Settings): granted once through root, so the sliders write settings
     * directly instead of a su shell per move. HACK: the user's grant done for them. Real fix: the Settings page's grant.
     */
    private fun grantWriteSettings() {
        if (Settings.System.canWrite(context)) return
        root("appops set ${context.packageName} WRITE_SETTINGS allow")
    }

    /** The phone's own tile order (SystemUI's sysui_qs_tiles, a secure setting apps can't read): once per process. */
    private fun loadOrder() {
        order?.let { return hostTiles(it) }
        io.execute {
            val tiles = rootOut("settings get secure sysui_qs_tiles")?.trim()?.takeIf { it.isNotEmpty() && it != "null" } ?: return@execute
            val ids = split(tiles)
            order = ids
            main.post {
                hostTiles(ids)
                changed()
            }
        }
    }

    /** The order's third-party tiles to [TileHost] - not OnePlus's battery saver, which is the system's own switch. */
    private fun hostTiles(ids: List<String>) = TileHost.host(ids.filter { it.startsWith("custom(") && !it.contains("com.oplus.battery/") })

    private fun root(cmd: String) =
        io.execute {
            val out = rootOut(cmd)
            if (out == null) Log.w(TAG, "root: $cmd failed")
            main.post(changed)
        }

    fun close() {
        cameras.unregisterTorchCallback(torchCallback)
        context.contentResolver.unregisterContentObserver(settingsObserver)
        main.removeCallbacks(pending)
        TileHost.detach(tileListener, this)
    }

    companion object {
        private const val TAG = "PowosQuick"
        private const val BRIGHTNESS_MIN = 1

        /** The panel's slide away, before a screenshot is taken. */
        private const val PANEL_GONE_MS = 450L

        private val io = Executors.newSingleThreadExecutor()

        /** sysui_qs_tiles, read once. */
        @Volatile private var order: List<String>? = null

        private val DEFAULT_ORDER =
            listOf("wifi", "bt", "cell", "flashlight", "location", "airplane", "rotation", "dnd", "darkmode", "screenshot", "hotspot", "nfc", "battery")

        /** The tile list's commas, but not those inside custom(...). */
        private fun split(spec: String): List<String> {
            val out = mutableListOf<String>()
            var depth = 0
            val cur = StringBuilder()
            for (c in spec) {
                when {
                    c == ',' && depth == 0 -> out += cur.toString().trim().also { cur.clear() }
                    else -> {
                        if (c == '(') depth++
                        if (c == ')') depth--
                        cur.append(c)
                    }
                }
            }
            if (cur.isNotBlank()) out += cur.toString().trim()
            return out
        }

        /** A command in a su shell: its output, null if it failed. */
        private fun rootOut(cmd: String): String? =
            runCatching {
                // Through the app's one root shell: no new su (and its Magisk toast) per tile read.
                val r = andro.marchy.RootShell.run(cmd)
                if (r.code == 0) r.output else null.also { Log.w(TAG, "$cmd: ${r.output}") }
            }.getOrNull()
    }
}

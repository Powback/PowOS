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
import android.widget.Toast
import dev.omalauncher.devices.LockAccess
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.system.KeyboardShotService
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
 * Android lets only its own UI switch: rooted PowOS switches them through its root session ([root]); without root
 * each tile takes the next way [TilePaths] picks (the legacy Wi-Fi/Bluetooth calls, Android's panel for it, the
 * accessibility service's screenshot/lock), and one that can't act opens the page that lets it and says why. A
 * flipped switch shows at once and rolls back if the system's state didn't follow ([expect]).
 *
 * HACK: the switches through root (svc / cmd / settings in a su shell). Real fix: the privileged permissions SystemUI's
 * tiles hold (NETWORK_SETTINGS, BLUETOOTH_PRIVILEGED, MODIFY_PHONE_STATE, WRITE_SECURE_SETTINGS, MODIFY_DAY_NIGHT_MODE,
 * DEVICE_POWER) on the PowOS system app's allowlist (system-module/privapp-permissions.txt) - most are signature-only.
 */
class QuickSettings(
    private val context: Context,
    private val onChanged: () -> Unit,
) {
    /**
     * The tiles' system states that are binder calls (Wi-Fi, location, dark mode, NFC, battery saver, hotspot, the
     * operator, do not disturb, volume and ringer, third-party tiles' labels), read on [reads] into [sys]: the page's
     * reads ([state]) build the JSON from it on the main thread without a binder call (WifiManager.isWifiEnabled took
     * 264 ms there in perf-1793409569119). Staleness: re-read after every change signal (the settings observer - Wi-Fi,
     * location, dark mode, battery saver, airplane, Bluetooth and mobile data are all settings - the torch callback,
     * the third-party tiles, a switch's root command finishing, a slider) before the page is told, and after every
     * [state] read, which tells the page again if anything differed - so an unsignalled change (NFC, the operator)
     * shows within one read (one binder round per value) of the next look.
     */
    private data class Sys(
        val values: Map<String, Any?>,
        val customs: Map<String, Pair<ComponentName, String>?>,
    ) {
        val wifi get() = values["wifi"] as Boolean?
        val operator get() = values["operator"] as String?
        val location get() = values["location"] as Boolean?
        val dnd get() = values["dnd"] as Boolean?
        val night get() = values["night"] as Int?
        val hotspot get() = values["hotspot"] as Boolean?
        val nfc get() = values["nfc"] as Boolean?
        val powerSave get() = values["powerSave"] == true
        val volume get() = values["volume"] as Double? ?: 0.0
        val ringer get() = values["ringer"] as Int? ?: AudioManager.RINGER_MODE_NORMAL

        /** This, with [key] (a slider just set) at [value]. */
        fun with(
            key: String,
            value: Any?,
        ) = copy(values = values + (key to value))
    }

    @Volatile private var sys: Sys? = null

    /** Bumped by every slider [set] that writes [sys] itself. */
    @Volatile private var slid = 0

    /** A [readSys] is queued and not started: another ask needn't queue one more (it would read the same). */
    private val readQueued = java.util.concurrent.atomic.AtomicBoolean(false)

    /** A queued [readSys] tells the page when done, whether or not anything differed. */
    private val tellQueued = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Something changed: the states read again (off the main thread), then the page told ([onChanged]). */
    private fun changed() = reread(tell = true)

    private fun reread(tell: Boolean) {
        if (tell) tellQueued.set(true)
        if (!readQueued.compareAndSet(false, true)) return
        reads.execute {
            readQueued.set(false)
            val told = tellQueued.getAndSet(false)
            val before = sys
            val wrote = slid
            val now = runCatching { readSys() }.onFailure { Log.w(TAG, "quick settings unreadable", it) }.getOrNull() ?: return@execute
            // A slider set meanwhile: this read may predate it (the volume jumping back); the read its change() queued wins.
            if (wrote != slid) return@execute
            sys = now
            if (told || before != now) onChanged()
        }
    }

    /** The binder-call states, on [reads]. */
    private fun readSys(): Sys {
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        val ids = order ?: DEFAULT_ORDER
        val old = sys?.customs.orEmpty()
        val values =
            mapOf(
                "wifi" to wifi?.isWifiEnabled,
                "operator" to telephony?.networkOperatorName?.takeIf { it.isNotBlank() },
                "location" to location?.isLocationEnabled,
                "dnd" to MediaListener.connected?.currentInterruptionFilter?.let { it > NotificationListenerService.INTERRUPTION_FILTER_ALL },
                "night" to uiMode?.nightMode,
                "hotspot" to hotspotOn(),
                "nfc" to nfc?.isEnabled,
                "powerSave" to power.isPowerSaveMode,
                "volume" to audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max,
                "ringer" to audio.ringerMode,
            )
        // A tile's component and label don't change while it's installed: read once per tile id.
        return Sys(values, ids.filter { it.startsWith("custom(") }.associateWith { id -> if (id in old) old[id] else readCustom(id) })
    }

    /** [sys], read here if never read yet (the first look only; [init] queues the first read at once). */
    private fun sysNow(): Sys = sys ?: readSys().also { sys = it }

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
    private val bluetooth: android.bluetooth.BluetoothAdapter? = runCatching { context.getSystemService(android.bluetooth.BluetoothManager::class.java)?.adapter }.getOrNull()
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

    // Declared before init: init's listeners may ask for the state (tile(), toggle()) at once.
    /** The switches flipped optimistically ([expect]), by tile id. */
    private val expected = java.util.concurrent.ConcurrentHashMap<String, Expect>()

    /** Each tile's state as the system has it ([realOn]). */
    private val reals: Map<String, (Sys) -> Boolean?> =
        mapOf(
            "wifi" to { s -> s.wifi },
            "bt" to { _ -> global("bluetooth_on") == 1 },
            "cell" to { _ -> global("mobile_data") == 1 },
            "location" to { s -> s.location },
            "airplane" to { _ -> global(Settings.Global.AIRPLANE_MODE_ON) == 1 },
            "rotation" to { _ -> system(Settings.System.ACCELEROMETER_ROTATION) == 1 },
            "dnd" to { s -> s.dnd },
            "darkmode" to { s -> s.night?.let { it == UiModeManager.MODE_NIGHT_YES } },
            "nfc" to { s -> s.nfc },
            "battery" to { s -> s.powerSave },
            "powersave" to { s -> s.powerSave },
        )

    /** Each [direct] switch, given whether the tile is on now. */
    @Suppress("DEPRECATION")
    @android.annotation.SuppressLint("MissingPermission")
    private val directs: Map<String, (Boolean) -> Boolean> =
        mapOf(
            "wifi" to { off -> wifi?.setWifiEnabled(!off) == true },
            "bt" to { off -> bluetooth?.let { if (off) it.disable() else it.enable() } == true },
            "darkmode" to { off -> night(if (off) UiModeManager.MODE_NIGHT_NO else UiModeManager.MODE_NIGHT_YES) },
            "dnd" to ::dnd,
            "rotation" to { off -> Settings.System.canWrite(context) && Settings.System.putInt(context.contentResolver, Settings.System.ACCELEROMETER_ROTATION, if (off) 0 else 1) },
        )

    init {
        cameras.registerTorchCallback(torchCallback, main)
        for (uri in listOf(Settings.Global.CONTENT_URI, Settings.System.CONTENT_URI, Settings.Secure.CONTENT_URI)) {
            context.contentResolver.registerContentObserver(uri, true, settingsObserver)
        }
        grantWriteSettings()
        TileHost.attach(context, tileListener)
        loadOrder()
        reread(tell = false)
    }

    fun state(): JSONObject {
        val sys = sysNow()
        reread(tell = false) // fresh for the next look; the page is told if this one was behind
        val dnd = sys.dnd
        val tiles = JSONArray()
        for (id in order ?: DEFAULT_ORDER) tile(id)?.let(tiles::put)
        return JSONObject()
            .put("torch", if (torchCamera == null) JSONObject.NULL else torch)
            // null: unknown (no notification access yet), so the tile can't switch it.
            .put("dnd", dnd ?: JSONObject.NULL)
            .put("tiles", tiles)
            .put("brightness", brightness())
            .put("volume", volume(sys))
    }

    /** One tile: { id, label, on (true/false, null: not a switch), detail, app (a third-party tile's package) }. */
    private fun tile(id: String): JSONObject? {
        val sys = sysNow()
        val t = JSONObject().put("id", id)
        fun sw(
            label: String,
            on: Boolean?,
            detail: String? = null,
        ) = t.put("label", label).put("on", on ?: JSONObject.NULL).put("detail", detail ?: JSONObject.NULL)
        return when (id) {
            "wifi" -> sw("Wi-Fi", shown(id, sys.wifi))
            "bt" -> sw("Bluetooth", shown(id, global("bluetooth_on") == 1))
            "cell" -> sw("Mobile data", shown(id, global("mobile_data") == 1), sys.operator)
            "flashlight" -> if (torchCamera == null) null else sw("Torch", torch)
            "location" -> sw("Location", shown(id, sys.location))
            "airplane" -> sw("Airplane mode", shown(id, global(Settings.Global.AIRPLANE_MODE_ON) == 1))
            "rotation" -> sw("Auto-rotate", shown(id, system(Settings.System.ACCELEROMETER_ROTATION) == 1))
            "dnd" -> sw("Do not disturb", shown(id, sys.dnd))
            "darkmode" -> sw("Dark mode", shown(id, sys.night == UiModeManager.MODE_NIGHT_YES))
            "hotspot" -> sw("Hotspot", sys.hotspot)
            "nfc" -> if (nfc == null) null else sw("NFC", shown(id, sys.nfc))
            "battery", "powersave" -> sw("Battery saver", shown("battery", sys.powerSave))
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
                    (if (id in sys.customs) sys.customs[id] else custom(id))?.let { (cn, label) ->
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

    /** A third-party tile (custom(pkg/cls)): its component and its label, as last read ([sys]) or read now. */
    private fun custom(id: String): Pair<ComponentName, String>? = sys?.customs?.get(id) ?: readCustom(id)

    /** A third-party tile (custom(pkg/cls)): its component and the label its service declares (a binder call). */
    private fun readCustom(id: String): Pair<ComponentName, String>? {
        val spec = id.removePrefix("custom(").removeSuffix(")").takeIf { id.startsWith("custom(") } ?: return null
        val cn = ComponentName.unflattenFromString(spec) ?: return null
        val info = runCatching { context.packageManager.getServiceInfo(cn, 0) }.getOrNull() ?: return null
        return cn to info.loadLabel(context.packageManager).toString()
    }

    /** A tile tapped: its path on this phone ([TilePaths]: root, the app's own call, Android's panel, or why not). */
    fun toggle(name: String) {
        when (name) {
            "torch", "flashlight" -> torchCamera?.let { cameras.setTorchMode(it, !torch) }
            "hotspot" -> open("hotspot")
            else -> {
                val on = realOn(name, sysNow())
                val caps = caps()
                val path = TilePaths.choose(name, on, caps)
                // A third-party tile switches in place when it's hosted ([TileHost]), else opens.
                if (path == null) {
                    if (!TileHost.click(name)) open(name)
                    return
                }
                Log.i(TAG, "tile $name (on=$on): $path")
                // OnePlus's battery saver id and "powersave" show as the "battery" tile.
                if (on != null && TilePaths.optimistic(path)) expect(if (name == "powersave") "battery" else name, !on, path)
                act(name, on, caps, path)
            }
        }
    }

    /** What this phone lets the tiles do, now ([TilePaths]). */
    private fun caps() =
        TileCaps(
            rooted = RootedGuest.enabled,
            legacyWifi = wifi != null && context.applicationInfo.targetSdkVersion < android.os.Build.VERSION_CODES.Q,
            legacyBt = bluetooth != null && context.applicationInfo.targetSdkVersion < android.os.Build.VERSION_CODES.TIRAMISU,
            accessibility = KeyboardShotService.instance != null,
            lockAdmin = LockAccess.allowed(context),
            writeSettings = Settings.System.canWrite(context),
            dndAccess = MediaListener.connected != null,
        )

    /** Tile [id]'s [path]; one that doesn't take goes on to [TilePaths.fallback] (never silent). */
    private fun act(
        id: String,
        on: Boolean?,
        caps: TileCaps,
        path: TilePath,
    ) {
        val next = { failed(id, on, caps, path) }
        when (path) {
            is TilePath.Root -> su(id, path.cmd, next)
            TilePath.Direct -> io.execute { if (directly(id, on)) changed() else next() }
            is TilePath.Global -> global(path.action, next)
            TilePath.AdminLock -> adminLock(next)
            is TilePath.Panel -> panel(path.page)
            is TilePath.Ask -> ask(path)
        }
    }

    /** Tile [id]'s su [cmd]; a screenshot after the panel's slide (the page shuts it first). */
    private fun su(
        id: String,
        cmd: String,
        failed: () -> Unit,
    ) {
        val delay = if (id == "screenshot") PANEL_GONE_MS else 0L
        main.postDelayed({ root(cmd) { ok -> if (!ok) failed() } }, delay)
    }

    /** The lock admin's lockNow; [failed] if Android refused it. */
    private fun adminLock(failed: () -> Unit) {
        if (runCatching { LockAccess.locker(context).lock() }.isFailure) failed()
    }

    /** [path] didn't take: the optimistic flip goes, the next way runs ([TilePaths.fallback]). */
    private fun failed(
        id: String,
        on: Boolean?,
        caps: TileCaps,
        path: TilePath,
    ) {
        expected.remove(id)
        TilePaths.fallback(id, on, caps)?.takeIf { it != path }?.let { main.post { act(id, on, caps, it) } }
        changed()
    }

    /** An accessibility global action, after the panel's slide for a screenshot; [failed] if the service is gone. */
    private fun global(
        action: Int,
        failed: () -> Unit,
    ) = main.postDelayed(
        { if (KeyboardShotService.instance?.performGlobalAction(action) != true) failed() },
        if (action == TilePaths.GLOBAL_SCREENSHOT) PANEL_GONE_MS else 0L,
    )

    /** Why the tile can't act, said; the page that lets it opened. */
    private fun ask(path: TilePath.Ask) {
        main.post { Toast.makeText(context, path.why, Toast.LENGTH_LONG).show() }
        panel(path.page)
    }

    /** [direct], a refusal (an exception) as false. */
    private fun directly(
        id: String,
        on: Boolean?,
    ): Boolean = runCatching { direct(id, on) }.onFailure { Log.w(TAG, "$id: refused", it) }.getOrDefault(false)

    /**
     * The app's own switch for tile [id] (on: its state now): false if Android refused it. HACK: Wi-Fi and Bluetooth
     * through the legacy calls, which work only because the app targets SDK 28 (targetSdk is pinned there for W^X, see
     * build.gradle). Real fix: the privileged permissions in the class comment; until then a target bump turns these
     * into the panels ([TileCaps.legacyWifi] / [TileCaps.legacyBt] go false by themselves).
     */
    private fun direct(
        id: String,
        on: Boolean?,
    ): Boolean = directs[id]?.invoke(on == true) ?: false

    /** Dark mode [want]: without MODIFY_DAY_NIGHT_MODE Android ignores it (logs "Night mode locked"), so read it back. */
    private fun night(want: Int): Boolean {
        val ui = uiMode ?: return false
        ui.nightMode = want
        return ui.nightMode == want
    }

    /** Do not disturb off ([off]: it's on now) or on, through the notification listener; false without one. */
    private fun dnd(off: Boolean): Boolean {
        val l = MediaListener.connected ?: return false
        l.requestInterruptionFilter(if (off) NotificationListenerService.INTERRUPTION_FILTER_ALL else NotificationListenerService.INTERRUPTION_FILTER_PRIORITY)
        return true
    }

    /** Android's panel or page for a [TilePath.Panel] / [TilePath.Ask]: the control center goes, the sheet comes up over home. */
    private fun panel(page: String) {
        main.post {
            collapse()
            val sheet =
                when (page) {
                    "wifi" -> Intent(Settings.Panel.ACTION_WIFI)
                    "cell" -> Intent(Settings.Panel.ACTION_INTERNET_CONNECTIVITY)
                    "nfc" -> Intent(Settings.Panel.ACTION_NFC)
                    "write-settings" -> Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, android.net.Uri.parse("package:${context.packageName}"))
                    "accessibility" ->
                        Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS")
                            .putExtra(Intent.EXTRA_COMPONENT_NAME, ComponentName(context, KeyboardShotService::class.java).flattenToString())
                            .takeIf { context.packageManager.resolveActivity(it, 0) != null } ?: Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    "lock-admin" -> return@post runCatching { LockAccess.ask(context) }.onFailure { Log.w(TAG, "lock admin screen", it) }.let {}
                    // A settings page: as a tile's long press opens it.
                    else -> return@post open(page)
                }
            // Android's own sheets (and the grant pages): launched plain, never into an app window (QuickPageRoute's PANEL).
            runCatching { context.startActivity(sheet.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                .onFailure {
                    Log.w(TAG, "no sheet for $page", it)
                    open(page)
                }
        }
    }

    /** Tile [id]'s state as the system has it (null: not a switch / unknown). */
    private fun realOn(
        id: String,
        sys: Sys,
    ): Boolean? = reals[id]?.invoke(sys)

    /** A switch flipped and not yet seen by the system: shown [on] until it is, or [until] passes. */
    private class Expect(
        val on: Boolean,
        val until: Long,
    )

    /**
     * Tile [id] shown [on] at once (optimistic); [SETTLE_MS] later, read again: not there, the real state comes back
     * (rollback), and a direct call Android accepted but didn't carry out opens the tile's page (never silent).
     */
    private fun expect(
        id: String,
        on: Boolean,
        path: TilePath,
    ) {
        val e = Expect(on, android.os.SystemClock.uptimeMillis() + SETTLE_MS)
        expected[id] = e
        main.postDelayed({
            reads.execute {
                val now = runCatching { readSys() }.getOrNull() ?: return@execute
                sys = now
                val real = realOn(id, now)
                if (!expected.remove(id, e) || real == on) return@execute onChanged()
                Log.w(TAG, "tile $id: still $real after ${SETTLE_MS}ms ($path), rolled back")
                if (path == TilePath.Direct) TilePaths.fallback(id, !on, caps())?.let { main.post { act(id, !on, caps(), it) } }
                onChanged()
            }
        }, SETTLE_MS)
    }

    /** [real], or the flip [expect]ed while the system hasn't caught up. */
    private fun shown(
        id: String,
        real: Boolean?,
    ): Boolean? {
        val e = expected[id] ?: return real
        if (real == e.on || android.os.SystemClock.uptimeMillis() > e.until) {
            expected.remove(id, e)
            return real
        }
        return e.on
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
                slid++
                sys = sysNow().with("volume", (max * v).roundToInt().toDouble() / max.coerceAtLeast(1))
                changed()
            }
            "ringer" -> {
                audio.ringerMode = (v * 2).roundToInt().coerceIn(0, 2)
                slid++
                sys = sysNow().with("ringer", (v * 2).roundToInt().coerceIn(0, 2))
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

    private fun volume(sys: Sys): JSONObject =
        JSONObject()
            .put("value", sys.volume)
            // 0 silent, 1 vibrate, 2 ring (AudioManager.RINGER_MODE_*).
            .put("ringer", sys.ringer)

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
        if (name.startsWith("settings:") || name.startsWith("indexed:")) {
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
        runCatching { dev.omalauncher.system.AppWindows.startActivity(context, intent) }
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

    /** [cmd] in the root shell, off the main thread; [done] (whether it worked) before the page hears of the change. */
    private fun root(
        cmd: String,
        done: (Boolean) -> Unit = {},
    ) = io.execute {
        val out = rootOut(cmd)
        if (out == null) Log.w(TAG, "root: $cmd failed")
        done(out != null)
        changed()
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

        /** How long a flipped switch may take to show in the system's state (Wi-Fi and Bluetooth take ~1-3 s) before it's rolled back. */
        private const val SETTLE_MS = 5_000L

        private val io = Executors.newSingleThreadExecutor()

        /** Where [QuickSettings.readSys] runs: not [io], whose root commands can take seconds. */
        private val reads = Executors.newSingleThreadExecutor { r -> Thread(r, "qs-reads") }

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

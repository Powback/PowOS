package dev.omalauncher.shell

/**
 * How a control-center tile acts on this phone ([QuickSettings.toggle]). Pure: the JVM tests drive it (TilePathsTest).
 *
 * Rooted PowOS keeps its su commands - instant, no sheet. Without root (S25, razr) every tile still does something:
 *  - what the app may switch itself, it switches ([Direct]): Wi-Fi and Bluetooth through the legacy WifiManager /
 *    BluetoothAdapter calls (the app targets SDK 28, under Q's Wi-Fi and T's Bluetooth cut-offs), dark mode through
 *    UiModeManager (often refused without MODIFY_DAY_NIGHT_MODE: then [fallback]), the torch, do not disturb (with
 *    notification access), auto-rotate (with WRITE_SETTINGS);
 *  - screenshot and lock through PowOS's accessibility service's global actions ([Global]); lock also through the
 *    device-admin lockNow ([AdminLock], LockAccess) the Devices app turns on;
 *  - the rest opens Android's own panel or page for it ([Panel]), inline as stock third-party shades do;
 *  - a tile whose way in is off says why and opens the page that turns it on ([Ask]). Never silent.
 */
sealed interface TilePath {
    /** A su command (rooted PowOS). */
    data class Root(
        val cmd: String,
    ) : TilePath

    /** The app's own API call; it may still be refused, then [TilePaths.fallback]. */
    data object Direct : TilePath

    /** Android's panel / settings page [page] (a [QuickSettings.panel] name): the user switches it there. */
    data class Panel(
        val page: String,
    ) : TilePath

    /** An accessibility global action (AccessibilityService.GLOBAL_ACTION_*) through PowOS's service. */
    data class Global(
        val action: Int,
    ) : TilePath

    /** DevicePolicyManager.lockNow through PowOS's lock admin. */
    data object AdminLock : TilePath

    /** Can't act yet: [why] said, and [page] (what turns the way in on) opened. */
    data class Ask(
        val page: String,
        val why: String,
    ) : TilePath
}

/** What this phone lets the control center do: read once per tap ([QuickSettings.caps]). */
data class TileCaps(
    /** PowOS's root (persist.powos.root, RootedGuest.enabled). */
    val rooted: Boolean,
    /** WifiManager.setWifiEnabled works: the app targets < 29 (Q). */
    val legacyWifi: Boolean,
    /** BluetoothAdapter.enable/disable work: the app targets < 33 (T) and the phone has Bluetooth. */
    val legacyBt: Boolean,
    /** PowOS's accessibility service (KeyboardShotService) is on. */
    val accessibility: Boolean,
    /** PowOS's lock device admin (LockAccess) is active. */
    val lockAdmin: Boolean,
    /** WRITE_SETTINGS granted (Settings.System.canWrite). */
    val writeSettings: Boolean,
    /** The notification listener is connected (do not disturb's interruption filter). */
    val dndAccess: Boolean,
)

object TilePaths {
    /** AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN / _TAKE_SCREENSHOT (API 28; constants here so the tests need no SDK). */
    const val GLOBAL_LOCK = 8
    const val GLOBAL_SCREENSHOT = 9

    const val WHY_SCREENSHOT = "Screenshots without root need PowOS's accessibility service: turn on \"PowOS keyboard screenshots\""
    const val WHY_LOCK = "Locking without root needs PowOS's accessibility service or its lock admin: allow it on the next screen"
    const val WHY_ROTATION = "Auto-rotate needs PowOS to modify system settings: allow it on the next screen"

    /**
     * Tile [id]'s path, [on] its state now (null: not a switch, or unknown), null for a tile this doesn't switch (the
     * torch, hotspot, actions that are pages, third-party tiles: [QuickSettings.toggle] handles those as before).
     */
    fun choose(
        id: String,
        on: Boolean?,
        caps: TileCaps,
    ): TilePath? = PATHS[id]?.invoke(on == true, caps)

    /** A switch only root may flip ([cmd] given whether it's on now), else Android's [page] for it. */
    private fun rootOr(
        page: String,
        cmd: (Boolean) -> String,
    ): (Boolean, TileCaps) -> TilePath = { on, caps -> if (caps.rooted) TilePath.Root(cmd(on)) else TilePath.Panel(page) }

    /** Wi-Fi / Bluetooth: root, else the legacy call ([legacy]), else Android's page. */
    private fun radio(
        page: String,
        svc: String,
        legacy: (TileCaps) -> Boolean,
    ): (Boolean, TileCaps) -> TilePath =
        { on, caps ->
            when {
                caps.rooted -> TilePath.Root("svc $svc ${if (on) "disable" else "enable"}")
                legacy(caps) -> TilePath.Direct
                else -> TilePath.Panel(page)
            }
        }

    private fun rotation(
        on: Boolean,
        caps: TileCaps,
    ): TilePath =
        when {
            caps.writeSettings -> TilePath.Direct
            caps.rooted -> TilePath.Root("settings put system accelerometer_rotation ${if (on) 0 else 1}")
            else -> TilePath.Ask("write-settings", WHY_ROTATION)
        }

    private fun screenshot(caps: TileCaps): TilePath =
        when {
            caps.rooted -> TilePath.Root("input keyevent KEYCODE_SYSRQ")
            caps.accessibility -> TilePath.Global(GLOBAL_SCREENSHOT)
            else -> TilePath.Ask("accessibility", WHY_SCREENSHOT)
        }

    private fun lock(caps: TileCaps): TilePath =
        when {
            caps.rooted -> TilePath.Root("input keyevent KEYCODE_SLEEP")
            // The accessibility lock first: lockNow (the admin) makes the next unlock skip biometrics.
            caps.accessibility -> TilePath.Global(GLOBAL_LOCK)
            caps.lockAdmin -> TilePath.AdminLock
            else -> TilePath.Ask("lock-admin", WHY_LOCK)
        }

    private val battery = rootOr("battery") { "cmd power set-mode ${if (it) 0 else 1}" }

    /** Each tile's path, given whether it's on now and the phone's [TileCaps]. */
    private val PATHS: Map<String, (Boolean, TileCaps) -> TilePath> =
        mapOf(
            "wifi" to radio("wifi", "wifi") { it.legacyWifi },
            "bt" to radio("bt", "bluetooth") { it.legacyBt },
            "cell" to rootOr("cell") { "svc data ${if (it) "disable" else "enable"}" },
            "airplane" to rootOr("airplane") { "cmd connectivity airplane-mode ${if (it) "disable" else "enable"}" },
            "location" to rootOr("location") { "cmd location set-location-enabled ${!it}" },
            "nfc" to rootOr("nfc") { "svc nfc ${if (it) "disable" else "enable"}" },
            "battery" to battery,
            "powersave" to battery,
            "darkmode" to { on, caps -> if (caps.rooted) TilePath.Root("cmd uimode night ${if (on) "no" else "yes"}") else TilePath.Direct },
            "dnd" to { _, caps -> if (caps.dndAccess) TilePath.Direct else TilePath.Panel("dnd") },
            "rotation" to ::rotation,
            "screenshot" to { _, caps -> screenshot(caps) },
            "lockscreen" to { _, caps -> lock(caps) },
        )

    /**
     * [path] for tile [id] didn't take (su failed, the app's call refused): the next way, as if neither root nor the
     * direct call were there. Never null for a switch: at worst Android's page for it.
     */
    fun fallback(
        id: String,
        on: Boolean?,
        caps: TileCaps,
    ): TilePath? =
        choose(id, on, caps.copy(rooted = false, legacyWifi = false, legacyBt = false))
            .let { if (it == TilePath.Direct) TilePath.Panel(id) else it }

    /** Tiles whose path is a switch the page may show flipped at once ([QuickSettings] rolls it back if it didn't). */
    fun optimistic(path: TilePath?): Boolean = path is TilePath.Root || path == TilePath.Direct
}

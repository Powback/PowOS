package dev.omalauncher.system

import android.telephony.ServiceState
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * What the status bar's icons show (shell/ui/chrome.tsx StatusIcons), as stock SystemUI maps it (its MobileMappings /
 * SignalStrength levels) - pure, so the JVM tests pin every mapping. [StatusSignals] feeds it Android's raw values and
 * sends [Status.json] to the page as "system.status".
 */
object StatusIcons {
    /** One SIM slot as the bar shows it. [sim]: "ready" | "absent" | "locked" | "error" | "unknown". */
    data class Cell(
        val slot: Int,
        val sim: String,
        /** Signal bars 0..4; null: no reading yet. */
        val bars: Int? = null,
        /** "in" (in service) | "none" (out of service) | "emergency" (emergency calls only) | "off" (radio off). */
        val service: String = "in",
        /** The network type label ("5G", "LTE", "4G+", ...); null: none shown. */
        val type: String? = null,
        val roaming: Boolean = false,
        /** Data moving on it: "in" | "out" | "inout"; null: idle or not this SIM's data. */
        val activity: String? = null,
        /** This SIM carries mobile data (the default data subscription). */
        val data: Boolean = false,
        /** The carrier's name (spoken label only). */
        val carrier: String? = null,
    ) {
        fun json(): JSONObject =
            JSONObject()
                .put("slot", slot)
                .put("sim", sim)
                .put("bars", bars ?: JSONObject.NULL)
                .put("service", service)
                .put("type", type ?: JSONObject.NULL)
                .put("roaming", roaming)
                .put("activity", activity ?: JSONObject.NULL)
                .put("data", data)
                .put("carrier", carrier ?: JSONObject.NULL)
    }

    /** A notification's icon on the bar's left: its key and its small icon's URL. */
    data class NotifIcon(val key: String, val pkg: String, val url: String)

    /** Everything the bar's icons need. Nulls are "unknown" (the page shows nothing for them). */
    data class Status(
        val cells: List<Cell> = emptyList(),
        val airplane: Boolean = false,
        /** Wi-Fi connected: bars 0..4 (null: not connected), and whether it has internet (validated). */
        val wifi: Int? = null,
        val wifiInternet: Boolean = true,
        val hotspot: Boolean = false,
        /** "off" | "on" | "connected". */
        val bluetooth: String = "off",
        /** A connected headset's battery 0-100 (null: none reported). */
        val bluetoothBattery: Int? = null,
        val nfc: Boolean = false,
        val location: Boolean = false,
        val dnd: Boolean = false,
        /** "normal" | "vibrate" | "silent". */
        val ringer: String = "normal",
        /** The next alarm (epoch ms), null: none set. */
        val alarm: Long? = null,
        val dataSaver: Boolean = false,
        val batterySaver: Boolean = false,
        val cast: Boolean = false,
        /** The phone permission is missing: SIMs past the first and the network type can't be read. */
        val limited: Boolean = false,
        val notifications: List<NotifIcon> = emptyList(),
    ) {
        fun json(): JSONObject =
            JSONObject()
                .put("cells", JSONArray(cells.map { it.json() }))
                .put("airplane", airplane)
                .put("wifi", wifi ?: JSONObject.NULL)
                .put("wifiInternet", wifiInternet)
                .put("hotspot", hotspot)
                .put("bluetooth", bluetooth)
                .put("bluetoothBattery", bluetoothBattery ?: JSONObject.NULL)
                .put("nfc", nfc)
                .put("location", location)
                .put("dnd", dnd)
                .put("ringer", ringer)
                .put("alarm", alarm ?: JSONObject.NULL)
                .put("dataSaver", dataSaver)
                .put("batterySaver", batterySaver)
                .put("cast", cast)
                .put("limited", limited)
                .put("notifications", JSONArray(notifications.map { JSONObject().put("key", it.key).put("pkg", it.pkg).put("url", it.url) }))
    }

    /** TelephonyManager.getSimState(slot) -> the bar's SIM state. */
    fun sim(state: Int): String =
        when (state) {
            // 10 SIM_STATE_LOADED, 11 SIM_STATE_PRESENT: system API constants, the same as ready for the bar.
            TelephonyManager.SIM_STATE_READY, 10, 11 -> "ready"
            TelephonyManager.SIM_STATE_ABSENT -> "absent"
            TelephonyManager.SIM_STATE_PIN_REQUIRED, TelephonyManager.SIM_STATE_PUK_REQUIRED,
            TelephonyManager.SIM_STATE_NETWORK_LOCKED,
            -> "locked"
            TelephonyManager.SIM_STATE_PERM_DISABLED, TelephonyManager.SIM_STATE_CARD_IO_ERROR,
            TelephonyManager.SIM_STATE_CARD_RESTRICTED,
            -> "error"
            else -> "unknown"
        }

    /** SignalStrength.getLevel() (0 none .. 4 great; some OEMs report up to [levels]-1) -> 0..4 bars. */
    fun bars(
        level: Int,
        levels: Int = 5,
    ): Int {
        if (levels <= 1) return 0
        val l = level.coerceIn(0, levels - 1)
        return if (levels == 5) l else Math.round(l * 4f / (levels - 1))
    }

    /** Wi-Fi: WifiManager.calculateSignalLevel(rssi) against its maxSignalLevel -> 0..4 bars. */
    fun wifiBars(
        level: Int,
        max: Int,
    ): Int = bars(level, max + 1)

    /** ServiceState.getState() (+ its emergency-only flag) -> the bar's service word. */
    fun service(
        state: Int,
        emergencyOnly: Boolean = false,
    ): String =
        when {
            state == ServiceState.STATE_POWER_OFF -> "off"
            state == ServiceState.STATE_IN_SERVICE -> "in"
            emergencyOnly || state == ServiceState.STATE_EMERGENCY_ONLY -> "emergency"
            else -> "none"
        }

    /**
     * The network type label stock shows: the radio's own type ([network], TelephonyManager.NETWORK_TYPE_*), raised by
     * the display override ([override], TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_*: LTE CA "+", 5G NSA on an LTE
     * anchor). [show4g]: the carrier says "4G" for LTE (CarrierConfigManager KEY_SHOW_4G_FOR_LTE_DATA_ICON_BOOL).
     */
    fun type(
        network: Int,
        override: Int = TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NONE,
        show4g: Boolean = false,
    ): String? {
        val lte = if (show4g) "4G" else "LTE"
        @Suppress("DEPRECATION")
        return when (override) {
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_ADVANCED, TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA_MMWAVE -> "5G+"
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA -> "5G"
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_CA, TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_ADVANCED_PRO -> "$lte+"
            else ->
                when (network) {
                    TelephonyManager.NETWORK_TYPE_NR -> "5G"
                    TelephonyManager.NETWORK_TYPE_LTE -> lte
                    19 -> "$lte+" // NETWORK_TYPE_LTE_CA (hidden)
                    TelephonyManager.NETWORK_TYPE_HSPAP -> "H+"
                    TelephonyManager.NETWORK_TYPE_HSDPA, TelephonyManager.NETWORK_TYPE_HSUPA, TelephonyManager.NETWORK_TYPE_HSPA -> "H"
                    TelephonyManager.NETWORK_TYPE_UMTS, TelephonyManager.NETWORK_TYPE_TD_SCDMA,
                    TelephonyManager.NETWORK_TYPE_EVDO_0, TelephonyManager.NETWORK_TYPE_EVDO_A, TelephonyManager.NETWORK_TYPE_EVDO_B,
                    TelephonyManager.NETWORK_TYPE_EHRPD,
                    -> "3G"
                    TelephonyManager.NETWORK_TYPE_EDGE -> "E"
                    TelephonyManager.NETWORK_TYPE_GPRS -> "G"
                    TelephonyManager.NETWORK_TYPE_CDMA, TelephonyManager.NETWORK_TYPE_1xRTT -> "1X"
                    TelephonyManager.NETWORK_TYPE_GSM -> "G"
                    else -> null // UNKNOWN, IWLAN (Wi-Fi calling: no mobile type)
                }
        }
    }

    /** TelephonyManager.DATA_ACTIVITY_* -> the bar's data arrows. */
    fun activity(value: Int): String? =
        when (value) {
            TelephonyManager.DATA_ACTIVITY_IN -> "in"
            TelephonyManager.DATA_ACTIVITY_OUT -> "out"
            TelephonyManager.DATA_ACTIVITY_INOUT -> "inout"
            else -> null
        }

    /** AudioManager.ringerMode -> "normal" | "vibrate" | "silent". */
    fun ringer(mode: Int): String =
        when (mode) {
            android.media.AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
            android.media.AudioManager.RINGER_MODE_SILENT -> "silent"
            else -> "normal"
        }

    /**
     * The slots' icons (slot, its [sim] state): every slot holding a SIM (in slot order); no SIM in any slot - empty, or
     * only NOT_READY/unknown (a disabled eSIM: OnePlus Open 11-25, slot 0 ABSENT, slot 1 NOT_READY) - one "absent" icon
     * (stock's "no SIM"); an empty slot beside a SIM shows nothing, as stock.
     */
    fun slots(sims: List<String>): List<Pair<Int, String>> {
        val held = sims.indices.filter { sims[it] != "absent" && sims[it] != "unknown" }.map { it to sims[it] }
        return held.ifEmpty { if (sims.isEmpty()) emptyList() else listOf(0 to "absent") }
    }

    /**
     * The notification icons, as stock's status bar shows them: one per app (its newest first), the silent/minimised ones
     * left out (stock hides silent notifications' icons in the status bar), PowOS's own status-only ones too.
     */
    fun notifications(
        list: List<NotifIcon>,
        shown: (NotifIcon) -> Boolean,
    ): List<NotifIcon> = list.filter(shown).distinctBy { it.pkg }
}

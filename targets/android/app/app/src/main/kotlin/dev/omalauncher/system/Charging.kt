package dev.omalauncher.system

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import org.json.JSONObject

/**
 * The battery as the lock face shows it (shell/ui/charge.ts chargeLine): level, plugged into what, how fast it charges
 * and how long until full - from public BatteryManager facts only, the same on a rooted and a non-rooted phone.
 *
 * How fast: the CHARGER's power, not the vendor's name for it. Android's own broadcast carries what the charger offers
 * ("max_charging_current" uA, "max_charging_voltage" uV: BatteryManager.EXTRA_MAX_CHARGING_CURRENT/_VOLTAGE, hidden
 * constants with these public string keys, filled by the framework's BatteryService on every phone). Power = their
 * product, the voltage taken as 5 V when the charger gives none - exactly AOSP SystemUI's KeyguardIndicationController.
 * Thresholds (watts):
 * - below [SLOW_W] 5 W: "slow"   (AOSP config_chargingSlowlyThreshold, 5 W: a PC port)
 * - from [FAST_W] 7.5 W: "fast"  (AOSP config_chargingFastThreshold, 7.5 W: QC/AFC 9 V adapters, ~10-18 W)
 * - from [SUPER_FAST_W] 20 W: "superfast" (USB PD/PPS class: 25 W and 45 W adapters report ~25-45 W; a 15 W
 *   adapter stays under it). Our own line, chosen between the 15 W and 25 W adapter classes - no vendor table.
 * When the charger reports nothing, the battery's own intake (BATTERY_PROPERTY_CURRENT_NOW x EXTRA_VOLTAGE) may
 * raise the class (the intake is always below the charger's power, so it never overstates), but never lowers it to
 * "slow": a vendor that reports mA where Android says uA would otherwise read as a trickle.
 *
 * Time until full: BatteryManager.computeChargeTimeRemaining() (Android's own estimate); null when it can't tell (-1)
 * - the face then shows no time rather than a guess.
 */
object Charging {
    const val SLOW_W = 5.0
    const val FAST_W = 7.5
    const val SUPER_FAST_W = 20.0
    /** AOSP's DEFAULT_CHARGING_VOLTAGE_MICRO_VOLT: a charger that gives a current but no voltage. */
    const val DEFAULT_UV = 5_000_000

    /** Public string keys of BatteryManager's hidden EXTRA_MAX_CHARGING_CURRENT / EXTRA_MAX_CHARGING_VOLTAGE. */
    const val EXTRA_MAX_CURRENT = "max_charging_current"
    const val EXTRA_MAX_VOLTAGE = "max_charging_voltage"

    data class Info(
        /** 0-100, null unknown. */
        val level: Int?,
        /** Charging or full on power (the old `charging` the page already reads). */
        val charging: Boolean,
        /** "ac" | "usb" | "wireless" | "dock" | null (on battery). */
        val plugged: String?,
        /** Plugged in and full. */
        val full: Boolean,
        /** Plugged in but not charging (the phone's battery protection holding it, a too-weak charger). */
        val held: Boolean,
        /** "slow" | "normal" | "fast" | "superfast" while charging, else null. */
        val speed: String?,
        /** The power the class came from, W (one decimal), null unknown. */
        val watts: Double?,
        /** "charger" (what it offers) | "measured" (the battery's intake) | null. */
        val wattsFrom: String?,
        /** ms until full, null when Android can't tell or it isn't charging. */
        val fullInMs: Long?,
    ) {
        fun json(): JSONObject =
            JSONObject()
                .put("level", level ?: JSONObject.NULL)
                .put("charging", charging)
                .put("plugged", plugged ?: JSONObject.NULL)
                .put("full", full)
                .put("held", held)
                .put("speed", speed ?: JSONObject.NULL)
                .put("watts", watts ?: JSONObject.NULL)
                .put("wattsFrom", wattsFrom ?: JSONObject.NULL)
                .put("fullInMs", fullInMs ?: JSONObject.NULL)
    }

    fun pluggedName(plugged: Int): String? =
        when {
            plugged and BatteryManager.BATTERY_PLUGGED_WIRELESS != 0 -> "wireless"
            plugged and BatteryManager.BATTERY_PLUGGED_AC != 0 -> "ac"
            plugged and BatteryManager.BATTERY_PLUGGED_USB != 0 -> "usb"
            plugged and 8 != 0 -> "dock" // BATTERY_PLUGGED_DOCK (API 33)
            else -> null
        }

    /** The charger's offered power, W; null when it offers nothing (no current). AOSP's formula. */
    fun chargerWatts(maxCurrentUa: Int, maxVoltageUv: Int): Double? {
        if (maxCurrentUa <= 0) return null
        val uv = if (maxVoltageUv > 0) maxVoltageUv else DEFAULT_UV
        return (maxCurrentUa / 1000.0) * (uv / 1000.0) / 1_000_000.0
    }

    /** The battery's intake, W; null unless it reads as current flowing IN (positive, as Android documents). */
    fun measuredWatts(currentNowUa: Long, voltageMv: Int): Double? {
        if (currentNowUa <= 0 || currentNowUa == Long.MIN_VALUE || voltageMv <= 0) return null
        return currentNowUa / 1_000_000.0 * voltageMv / 1000.0
    }

    fun speedOf(w: Double): String =
        when {
            w >= SUPER_FAST_W -> "superfast"
            w >= FAST_W -> "fast"
            w < SLOW_W -> "slow"
            else -> "normal"
        }

    /** Everything from the broadcast's numbers - pure, for the JVM test. */
    fun classify(
        level: Int,
        scale: Int,
        status: Int,
        plugged: Int,
        maxCurrentUa: Int,
        maxVoltageUv: Int,
        currentNowUa: Long,
        voltageMv: Int,
        chargeTimeMs: Long,
    ): Info {
        val lvl = if (level >= 0 && scale > 0) level * 100 / scale else null
        val on = pluggedName(plugged)
        val full = on != null && (status == BatteryManager.BATTERY_STATUS_FULL || lvl == 100 && status != BatteryManager.BATTERY_STATUS_CHARGING)
        val chargingNow = status == BatteryManager.BATTERY_STATUS_CHARGING
        val held = on != null && !full && !chargingNow
        val charging = chargingNow || status == BatteryManager.BATTERY_STATUS_FULL
        if (!chargingNow || on == null || full) return Info(lvl, charging, on, full, held, null, null, null, null)
        val offered = chargerWatts(maxCurrentUa, maxVoltageUv)
        val measured = measuredWatts(currentNowUa, voltageMv)
        val (speed, watts, from) =
            when {
                offered != null -> Triple(speedOf(offered), offered, "charger")
                // Intake only raises the class (see the header): below 7.5 W it says "normal", never "slow".
                measured != null && measured >= FAST_W -> Triple(speedOf(measured), measured, "measured")
                measured != null -> Triple("normal", measured, "measured")
                else -> Triple("normal", null, null)
            }
        val time = chargeTimeMs.takeIf { it > 0 }
        return Info(lvl, true, on, false, false, speed, watts?.let { Math.round(it * 10) / 10.0 }, from, time)
    }

    fun from(context: Context, b: Intent?): Info {
        val bm = context.getSystemService(BatteryManager::class.java)
        return classify(
            level = b?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1,
            scale = b?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100,
            status = b?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1,
            plugged = b?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0,
            maxCurrentUa = b?.getIntExtra(EXTRA_MAX_CURRENT, -1) ?: -1,
            maxVoltageUv = b?.getIntExtra(EXTRA_MAX_VOLTAGE, -1) ?: -1,
            currentNowUa = runCatching { bm?.getLongProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW) }.getOrNull() ?: Long.MIN_VALUE,
            voltageMv = b?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1) ?: -1,
            chargeTimeMs = runCatching { bm?.computeChargeTimeRemaining() }.getOrNull() ?: -1L,
        )
    }

    /** Now, from the sticky broadcast (no receiver kept). */
    fun read(context: Context): Info = from(context, context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)))
}

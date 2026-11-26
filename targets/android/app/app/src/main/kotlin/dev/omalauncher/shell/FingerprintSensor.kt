package dev.omalauncher.shell

import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Resources
import android.graphics.Rect
import android.graphics.Region
import android.hardware.display.DisplayManager
import android.util.Log
import android.view.Display
import android.view.View
import android.view.ViewTreeObserver
import android.view.Window
import android.view.WindowManager
import org.json.JSONObject
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The phone's fingerprint sensor as the lock face shows it (lock.tsx, "lock.sensor"; docs/NATIVE-SYSTEM-UI.md, "Lock
 * screen"): which kind it is and, for an in-display one, where - a spot is drawn there and the face takes no touch on
 * it ([TouchHole]), so a finger on it is SystemUI's (its UDFPS overlay, the keyguard's fingerprint listening while the
 * face occludes it). The unlock itself stays the keyguard's: once it is gone the face goes (LockFace USER_PRESENT).
 *
 * Where it is comes from the system's own config, the one SystemUI's UDFPS overlay falls back to:
 * `com.android.internal.R.array.config_udfps_sensor_props` = [x, y, radius] in the panel's native pixels, natural
 * orientation (an OEM overlays the same resource). The live sensor properties (FingerprintManager
 * getSensorPropertiesInternal) need USE_BIOMETRIC_INTERNAL (signature): a phone whose HAL alone knows the spot gets no
 * spot, only the hint ("other").
 */
object FingerprintSensor {
    private const val TAG = "PowosFingerprint"

    /** In the display's current pixels, as the lock face's window lays out (full screen, from the top left). */
    data class Spot(val x: Int, val y: Int, val r: Int)

    /** in-display with a known spot */
    const val UDFPS = "udfps"

    /** the power button's (side) sensor: nothing to draw, the button is where it always is */
    const val SIDE = "side"

    /** a sensor whose place the system doesn't say (in-display without the config, rear) */
    const val OTHER = "other"

    /** no fingerprint sensor */
    const val NONE = "none"

    /**
     * [props] (config_udfps_sensor_props: x, y, radius in the native mode's pixels, natural orientation) on the display as
     * it is now: scaled by the current mode against the native one ([nativeW] x [nativeH] -> [naturalW] x [naturalH],
     * both natural orientation, as SystemUI's UdfpsOverlayParams scale), then turned by [rotation] (Surface.ROTATION_*).
     * Null when there is nothing usable (empty, a zero radius, off the panel).
     */
    fun spot(
        props: IntArray?,
        nativeW: Int,
        nativeH: Int,
        naturalW: Int,
        naturalH: Int,
        rotation: Int,
    ): Spot? {
        if (props == null || props.size < 3 || nativeW <= 0 || nativeH <= 0 || naturalW <= 0 || naturalH <= 0) return null
        val (x, y, r) = props
        if (r <= 0 || x !in 0..nativeW || y !in 0..nativeH) return null
        val scale = min(naturalW.toFloat() / nativeW, naturalH.toFloat() / nativeH)
        val sx = x * scale
        val sy = y * scale
        val (rx, ry) =
            when (rotation) {
                1 -> sy to naturalW - sx
                2 -> naturalW - sx to naturalH - sy
                3 -> naturalH - sy to sx
                else -> sx to sy
            }
        return Spot(rx.roundToInt(), ry.roundToInt(), (r * scale).roundToInt().coerceAtLeast(1))
    }

    /** Which kind, from what the system says: the feature, the UDFPS spot, a side (power button) sensor's config. */
    fun kind(
        hasSensor: Boolean,
        spot: Spot?,
        side: Boolean,
    ): String =
        when {
            !hasSensor -> NONE
            spot != null -> UDFPS
            side -> SIDE
            else -> OTHER
        }

    data class Sensor(val kind: String, val enrolled: Boolean, val spot: Spot?) {
        /** For the page: the spot in CSS px ([density]: the WebView's px per CSS px). */
        fun json(density: Float): JSONObject =
            JSONObject()
                .put("kind", kind)
                .put("enrolled", enrolled)
                .put(
                    "spot",
                    spot?.let {
                        JSONObject().put("x", it.x / density).put("y", it.y / density).put("r", it.r / density)
                    } ?: JSONObject.NULL,
                )
    }

    fun read(context: Context): Sensor {
        val pm = context.packageManager
        val has = pm.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)
        if (!has) return Sensor(NONE, false, null)
        val sys = Resources.getSystem()
        val spot = runCatching { spotOn(display(context), intArray(sys, "config_udfps_sensor_props")) }.getOrNull()
        val side =
            bool(sys, "config_is_powerbutton_fps") ||
                runCatching {
                    val id = sys.getIdentifier("config_sfps_sensor_props", "array", "android")
                    id != 0 && sys.obtainTypedArray(id).run { length().also { recycle() } } > 0
                }.getOrDefault(false)
        return Sensor(kind(true, spot, side), enrolled(context), spot)
    }

    private fun spotOn(
        display: Display?,
        props: IntArray?,
    ): Spot? {
        if (display == null || props == null) return null
        val native = display.supportedModes.maxByOrNull { it.physicalWidth * it.physicalHeight } ?: return null
        val now = display.mode
        return spot(props, native.physicalWidth, native.physicalHeight, now.physicalWidth, now.physicalHeight, display.rotation)
    }

    private fun display(context: Context): Display? =
        runCatching { context.display }.getOrNull()
            ?: context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY)

    // A strong biometric enrolled (BiometricManager, USE_BIOMETRIC: a normal permission). FingerprintManager's
    // hasEnrolledFingerprints is gone from the SDK; on these phones the strong one is the fingerprint (face is weak).
    private fun enrolled(context: Context): Boolean =
        runCatching {
            context.getSystemService(android.hardware.biometrics.BiometricManager::class.java)
                ?.canAuthenticate(android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
                android.hardware.biometrics.BiometricManager.BIOMETRIC_SUCCESS
        }.getOrDefault(false)

    private fun intArray(
        res: Resources,
        name: String,
    ): IntArray? = res.getIdentifier(name, "array", "android").takeIf { it != 0 }?.let { runCatching { res.getIntArray(it) }.getOrNull() }

    private fun bool(
        res: Resources,
        name: String,
    ): Boolean = res.getIdentifier(name, "bool", "android").takeIf { it != 0 }?.let { runCatching { res.getBoolean(it) }.getOrNull() } ?: false

    /**
     * The lock face's window takes no touch on [spot] (a square around it): a finger there reaches whatever is under the
     * face at that point (SystemUI's UDFPS overlay when it lies under it, an OEM's sensor view), never the face's swipe.
     * Returns the listener (null when it couldn't be set: the face then takes every touch, as before).
     * HACK: ViewTreeObserver's internal-insets listener is hidden (the IME's and SystemUI's own touch regions; PanelLift's
     * keyboard hole), reflected past the checks. Real fix: none for an app - Window has no public touchable region.
     */
    fun touchHole(
        window: Window,
        spot: Spot,
    ): Any? =
        runCatching {
            dev.omalauncher.system.HiddenApi.allow()
            val type = Class.forName("android.view.ViewTreeObserver\$OnComputeInternalInsetsListener")
            val root: View = window.decorView
            val hole = Rect(spot.x - spot.r, spot.y - spot.r, spot.x + spot.r, spot.y + spot.r)
            val listener =
                java.lang.reflect.Proxy.newProxyInstance(type.classLoader, arrayOf(type)) { proxy, method, args ->
                    when (method.name) {
                        "onComputeInternalInsets" -> {
                            val info = args!![0]
                            info.javaClass.getMethod("setTouchableInsets", Int::class.javaPrimitiveType).invoke(info, TOUCHABLE_INSETS_REGION)
                            (info.javaClass.getField("touchableRegion").get(info) as Region).apply {
                                set(0, 0, root.width, root.height)
                                op(hole, Region.Op.DIFFERENCE)
                            }
                            null
                        }
                        "equals" -> proxy === args?.getOrNull(0)
                        "hashCode" -> System.identityHashCode(proxy)
                        else -> "FingerprintSensor.touchHole"
                    }
                }
            ViewTreeObserver::class.java.getMethod("addOnComputeInternalInsetsListener", type).invoke(root.viewTreeObserver, listener)
            // WM ignores the region of a modal activity window (the task bounds instead); the face is full screen.
            window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
            root.requestLayout()
            listener
        }.onFailure { Log.w(TAG, "no touch-through hole over the fingerprint sensor", it) }.getOrNull()

    private const val TOUCHABLE_INSETS_REGION = 3
}

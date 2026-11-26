package dev.omalauncher.shell

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * HDMI in's host side (shell/ui/hdmiin.tsx, docs/HDMI-IN.md): the capture itself is the page's - getUserMedia on the
 * dongle, which Android's WebView reaches through Camera2 when the phone's camera HAL takes external (UVC) cameras.
 * No root, no USB permission. This only says what is plugged in ("probe"), asks the camera + mic permissions the
 * WebView needs ("permissions"), and holds the screen while it shows ("screen": awake; full: immersive + landscape).
 * "hdmiin.*" calls from the page; ShellHost grants the page's own media requests ([grantable]).
 */
class HdmiIn(
    private val context: Context,
    private val activity: Activity?,
    private val emit: (String, Any?) -> Unit,
) {
    /** The window as it was before "screen" took it: put back on release. */
    private var held: Held? = null

    private class Held(val orientation: Int, val barsShown: Boolean)

    fun call(
        method: String,
        a: JSONArray,
    ): Any? =
        when (method) {
            "probe" -> probe()
            "permissions" -> permissions()
            "screen" -> screen(a.optBoolean(0), a.optBoolean(1)).let { null }
            else -> throw IllegalArgumentException("no such call: hdmiin.$method")
        }

    /** USB devices with a video / audio interface, Camera2's external cameras, a USB audio input, the permissions. */
    fun probe(): JSONObject {
        val usb = JSONArray()
        val manager = context.getSystemService(UsbManager::class.java)
        runCatching { manager?.deviceList?.values.orEmpty() }.getOrDefault(emptyList()).forEach { d ->
            val classes = (0 until d.interfaceCount).map { d.getInterface(it).interfaceClass }
            val video = UsbConstants.USB_CLASS_VIDEO in classes
            val audio = UsbConstants.USB_CLASS_AUDIO in classes
            if (!video && !audio) return@forEach
            usb.put(
                JSONObject().put("name", runCatching { d.productName }.getOrNull() ?: JSONObject.NULL)
                    .put("vendorId", d.vendorId).put("productId", d.productId).put("video", video).put("audio", audio),
            )
        }
        val cameras = context.getSystemService(CameraManager::class.java)
        val external =
            runCatching {
                cameras.cameraIdList.filter { id ->
                    cameras.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_EXTERNAL
                }
            }.getOrDefault(emptyList())
        val audioIn =
            runCatching {
                context.getSystemService(AudioManager::class.java).getDevices(AudioManager.GET_DEVICES_INPUTS)
                    .any { it.type == AudioDeviceInfo.TYPE_USB_DEVICE || it.type == AudioDeviceInfo.TYPE_USB_HEADSET }
            }.getOrDefault(false)
        return JSONObject()
            .put("usb", usb)
            .put("externalCameras", JSONArray(external))
            .put("usbAudioIn", audioIn)
            .put("camera", held(Manifest.permission.CAMERA))
            .put("mic", held(Manifest.permission.RECORD_AUDIO))
    }

    /** "granted" (both held), "asked" (Android's dialog is up; "hdmiin.permission" answers), "unavailable" (no activity). */
    private fun permissions(): String {
        val missing = PERMISSIONS.filterNot(::held)
        if (missing.isEmpty()) return "granted"
        val asker = activity ?: return "unavailable"
        asker.requestPermissions(missing.toTypedArray(), REQUEST)
        return "asked"
    }

    /** The answer to [permissions]' request ([ShellActivity.onRequestPermissionsResult]). */
    fun answered() = emit("hdmiin.permission", JSONObject().put("granted", PERMISSIONS.all(::held)))

    /**
     * Holds the screen for the picture: [awake] keeps it on; [full] also hides the bars (a swipe shows them a moment)
     * and turns to landscape. Released (awake false): as it was before.
     */
    private fun screen(
        awake: Boolean,
        full: Boolean,
    ) {
        val a = activity ?: return
        val window = a.window
        val bars = WindowCompat.getInsetsController(window, window.decorView)
        if (awake) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (full && held == null) {
            val shown = window.decorView.rootWindowInsets?.let { WindowInsetsCompat.toWindowInsetsCompat(it).isVisible(WindowInsetsCompat.Type.statusBars()) } ?: true
            held = Held(a.requestedOrientation, shown)
            bars.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            bars.hide(WindowInsetsCompat.Type.systemBars())
            a.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            Log.i(TAG, "screen held: immersive, landscape")
        } else if (!full) {
            val h = held ?: return
            held = null
            if (h.barsShown) bars.show(WindowInsetsCompat.Type.systemBars())
            a.requestedOrientation = h.orientation
            Log.i(TAG, "screen released")
        }
    }

    private fun held(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    companion object {
        private const val TAG = "HdmiIn"

        /** ShellActivity's request code for HDMI in's camera + mic. */
        const val REQUEST = 47

        /** [ShellActivity] with this: HDMI in's screen opens ("hdmiin.open"), as from [Attach]. */
        const val EXTRA_OPEN = "dev.omalauncher.shell.hdmiin"

        private val PERMISSIONS = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)

        /**
         * May the shell page's media request for [resources] from [origin] be granted: the page's own origin ([shell])
         * only, and only what PowOS holds the Android permission for. The rest is denied (no dialog: the page asks
         * through "hdmiin.permissions" first).
         */
        fun grantable(
            context: Context,
            origin: String?,
            shell: String,
            resources: Array<String>,
        ): Array<String> {
            if (origin?.trimEnd('/') != shell.trimEnd('/')) return emptyArray()
            return resources.filter { r ->
                when (r) {
                    WebPermissions.RES_VIDEO -> context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
                    WebPermissions.RES_AUDIO -> context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                    else -> false
                }
            }.toTypedArray()
        }
    }

    /**
     * A UVC device plugged in (res/xml/hdmi_in_usb.xml: any USB video interface - the dongle, but a webcam too):
     * Android offers PowOS for it; picked, home opens with HDMI in's screen up. No window of its own.
     */
    class Attach : Activity() {
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            startActivity(
                Intent(this, ShellActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .putExtra(EXTRA_OPEN, true),
            )
            finish()
        }
    }
}

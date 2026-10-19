package dev.omalauncher.shell

import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import dev.omalauncher.widgets.runtime.MediaListener
import org.json.JSONObject

/**
 * The notification panel's quick settings (shell/ui/notifications.tsx): what an app may switch itself - the
 * flashlight (CameraManager's torch), do not disturb (the notification listener PowOS has may set the interruption
 * filter) - and Android's own panels for what it may not (Wi-Fi, Bluetooth, internet: Settings.Panel), so the panel
 * still covers them once it's the phone's shade.
 */
class QuickSettings(
    private val context: Context,
    private val changed: () -> Unit,
) {
    private val cameras = context.getSystemService(CameraManager::class.java)
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

    init {
        cameras.registerTorchCallback(torchCallback, Handler(Looper.getMainLooper()))
    }

    fun state(): JSONObject {
        val dnd = MediaListener.connected?.currentInterruptionFilter?.let { it > NotificationListenerService.INTERRUPTION_FILTER_ALL }
        return JSONObject()
            .put("torch", if (torchCamera == null) JSONObject.NULL else torch)
            // null: unknown (no notification access yet), so the tile can't switch it.
            .put("dnd", dnd ?: JSONObject.NULL)
    }

    fun toggle(name: String) {
        when (name) {
            "torch" -> torchCamera?.let { cameras.setTorchMode(it, !torch) }
            "dnd" ->
                MediaListener.connected?.let {
                    val on = it.currentInterruptionFilter > NotificationListenerService.INTERRUPTION_FILTER_ALL
                    it.requestInterruptionFilter(
                        if (on) NotificationListenerService.INTERRUPTION_FILTER_ALL else NotificationListenerService.INTERRUPTION_FILTER_PRIORITY,
                    )
                    changed()
                }
            else -> error("no quick setting $name")
        }
    }

    /** Android's own panel or page for [name]: wifi, bluetooth, internet, settings. */
    fun open(name: String) {
        val action =
            when (name) {
                "wifi" -> Settings.Panel.ACTION_WIFI
                "internet" -> Settings.Panel.ACTION_INTERNET_CONNECTIVITY
                "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
                "settings" -> Settings.ACTION_SETTINGS
                else -> error("no quick setting $name")
            }
        context.startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun close() = cameras.unregisterTorchCallback(torchCallback)
}

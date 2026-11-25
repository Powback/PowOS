package dev.omalauncher.shell

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import org.json.JSONObject

/**
 * The lock face's corner shortcuts (shell/ui/lockshortcuts.ts), as stock's lock screen has them: the torch, switched
 * without unlocking, and the camera, opened over the lock in its secure mode (MediaStore's
 * INTENT_ACTION_STILL_IMAGE_CAMERA_SECURE: the camera app shows only what it takes now; its gallery asks for the unlock).
 * Neither needs a permission: CameraManager.setTorchMode is open to any app, and the secure camera is the camera app's
 * own activity, shown over the keyguard by itself. "lock.torch" ({ on }) tells the page when the torch changes, from
 * here or anywhere (the shade's tile, the camera taking it).
 */
class LockShortcuts(
    private val activity: Activity,
    private val emit: (String, Any?) -> Unit,
) {
    private val cameras = activity.getSystemService(CameraManager::class.java)
    private val main = Handler(Looper.getMainLooper())

    /** The camera with a flash unit, null: none (the torch shortcut isn't offered). */
    private val torchCamera: String? =
        runCatching { cameras.cameraIdList.firstOrNull { cameras.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true } }.getOrNull()

    private var torchOn = false

    private val callback =
        object : CameraManager.TorchCallback() {
            override fun onTorchModeChanged(
                cameraId: String,
                enabled: Boolean,
            ) {
                if (cameraId != torchCamera || enabled == torchOn) return
                torchOn = enabled
                emit("lock.torch", JSONObject().put("on", enabled).toString())
            }
        }

    init {
        if (torchCamera != null) cameras.registerTorchCallback(callback, main)
    }

    private fun secureCamera() = Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA_SECURE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** { torch: on | null (no flash), camera: a camera app takes the secure intent }. */
    fun state(): JSONObject =
        JSONObject()
            .put("torch", if (torchCamera == null) JSONObject.NULL else torchOn)
            .put("camera", activity.packageManager.resolveActivity(secureCamera(), PackageManager.MATCH_DEFAULT_ONLY) != null)

    /** Switches the torch to [on]; resolves to what it is now (false while the camera app holds it: Android refuses). */
    fun torch(on: Boolean): Boolean {
        val id = torchCamera ?: return false
        runCatching { cameras.setTorchMode(id, on) }
            .onSuccess { torchOn = on }
            .onFailure { Log.w(TAG, "torch refused", it) }
        return torchOn
    }

    /** The camera over the lock: from the face's own activity (in front, so the start is allowed); Back returns to it. */
    fun camera(): Boolean =
        runCatching { activity.startActivity(secureCamera()) }
            .onFailure { Log.w(TAG, "no secure camera", it) }
            .isSuccess

    fun close() {
        if (torchCamera != null) runCatching { cameras.unregisterTorchCallback(callback) }
    }

    private companion object {
        const val TAG = "PowosLockShortcuts"
    }
}

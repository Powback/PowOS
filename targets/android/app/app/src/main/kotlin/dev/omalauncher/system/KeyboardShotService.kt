package dev.omalauncher.system

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.graphics.Bitmap
import android.view.Display
import android.view.accessibility.AccessibilityEvent

/**
 * The keyboard AI button's screenshot on a phone without root ([KeyboardAiProvider]): Android's
 * AccessibilityService.takeScreenshot (API 30+), the one way an app takes a silent screenshot without root once the user
 * has allowed it. The user turns it on once (Settings > Accessibility > PowOS keyboard screenshots; the keyboard opens
 * that page when the button needs it). It reads no window content and handles no events: it only takes a screenshot
 * when the keyboard's button is tapped. Secure windows come back black and are refused ([KeyboardAi.blackedOut]).
 */
class KeyboardShotService : AccessibilityService() {
    override fun onServiceConnected() {
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    /** One screenshot of the default display, software-backed (croppable), to [done] with null and why on failure. */
    fun shoot(done: (Bitmap?, String?) -> Unit) {
        takeScreenshot(
            Display.DEFAULT_DISPLAY,
            mainExecutor,
            object : TakeScreenshotCallback {
                override fun onSuccess(result: ScreenshotResult) {
                    val buffer = result.hardwareBuffer
                    val bitmap = runCatching { Bitmap.wrapHardwareBuffer(buffer, result.colorSpace)?.copy(Bitmap.Config.ARGB_8888, false) }.getOrNull()
                    buffer.close()
                    done(bitmap, if (bitmap == null) "accessibility screenshot: no bitmap" else null)
                }

                override fun onFailure(errorCode: Int) = done(null, "accessibility screenshot failed (error $errorCode)")
            },
        )
    }

    companion object {
        /** The running service (null: the user hasn't turned it on). */
        @Volatile var instance: KeyboardShotService? = null
            private set
    }
}

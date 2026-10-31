package dev.omalauncher.ui

import android.content.Context
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.View

/**
 * The shell's one haptic feel (the page's ui/haptics.ts reaches it through ShellBridge "haptics.tick"/"haptics.confirm"):
 * a light tick as a gesture crosses its commit threshold, a confirm when it commits. Same constants everywhere, so a
 * native gesture (NavGesture, ShadeHost) feels as the page's do.
 *
 * With a view: View.performHapticFeedback, which honours the system's "touch feedback" setting itself. Without one (the
 * gesture monitor has no view of its own): the vibrator with the touch usage, which that setting also scales / mutes.
 */
object Haptics {
    private val TICK = if (Build.VERSION.SDK_INT >= 34) HapticFeedbackConstants.SEGMENT_TICK else HapticFeedbackConstants.CLOCK_TICK

    fun tick(view: View) = view.post { view.performHapticFeedback(TICK) }

    fun confirm(view: View) = view.post { view.performHapticFeedback(HapticFeedbackConstants.CONFIRM) }

    fun tick(context: Context) = vibrate(context, VibrationEffect.EFFECT_TICK)

    fun confirm(context: Context) = vibrate(context, VibrationEffect.EFFECT_CLICK)

    private fun vibrate(
        context: Context,
        effect: Int,
    ) {
        val v = context.getSystemService(Vibrator::class.java) ?: return
        if (!v.hasVibrator()) return
        val e = VibrationEffect.createPredefined(effect)
        if (Build.VERSION.SDK_INT >= 33) {
            v.vibrate(e, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
        } else if (Settings.System.getInt(context.contentResolver, Settings.System.HAPTIC_FEEDBACK_ENABLED, 1) != 0) {
            @Suppress("DEPRECATION")
            v.vibrate(e)
        }
    }

    /**
     * A threshold's crossings: [at] each frame with whether the gesture is past it; true (fire a tick) only on the frame it
     * goes from short to past. Held past, nothing more; back and over again, once more. [reset] when the gesture ends.
     */
    class Crossing {
        private var past = false

        fun at(now: Boolean): Boolean = (now && !past).also { past = now }

        fun reset() {
            past = false
        }
    }
}

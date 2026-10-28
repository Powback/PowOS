package dev.omalauncher.shell

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.health.connect.client.PermissionController

/**
 * A tiny transparent PowOS activity that asks Health Connect for permissions and finishes ([HealthConnectBridge.grant]).
 *
 * Health Connect's sheet must be started for a result from an activity of the asking app. The Health page and widget
 * run in app islands, overlays and the AI page - WebViews with no activity of their own ([ShellHost] with a null
 * activity) - so the bridge refused there and "Allow" did nothing. This activity is that window, whatever the surface.
 * The contract is androidx's ([PermissionController.createRequestPermissionResultContract]): on SDK 34+ it is the
 * framework's `HealthConnectManager.ACTION_REQUEST_HEALTH_PERMISSIONS`.
 */
class HealthGrantActivity : Activity() {
    private val contract = PermissionController.createRequestPermissionResultContract()

    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)
        // Recreated (a fold, rotation) while the sheet is open: its result still comes to onActivityResult.
        if (saved != null) return
        val want = intent.getStringArrayListExtra(EXTRA_PERMISSIONS).orEmpty().toSet()
        try {
            val ask = contract.createIntent(this, want)
            Log.i(TAG, "asking Health Connect (${ask.action}) for ${want.size} permissions")
            @Suppress("DEPRECATION")
            startActivityForResult(ask, REQUEST)
        } catch (e: Exception) {
            Log.w(TAG, "Health Connect's permission sheet didn't open", e)
            answer(null, e.message ?: e.toString())
        }
    }

    @Deprecated("Health Connect's sheet answers here", ReplaceWith(""))
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST) return
        val granted = runCatching { contract.parseResult(resultCode, data) }.getOrDefault(emptySet())
        Log.i(TAG, "Health Connect answered: result=$resultCode granted=${granted.size} $granted")
        answer(granted, null)
    }

    override fun onDestroy() {
        // Gone without an answer (killed, back pressed before the sheet): the caller still hears, and checks status.
        if (isFinishing) answer(emptySet(), null)
        super.onDestroy()
    }

    private fun answer(
        granted: Set<String>?,
        err: String?,
    ) {
        val cb = pending ?: return finishIfNot()
        pending = null
        cb(granted, err)
        finishIfNot()
    }

    private fun finishIfNot() {
        if (!isFinishing) finish()
    }

    companion object {
        private const val TAG = "PowosHealth"
        private const val REQUEST = 42
        private const val EXTRA_PERMISSIONS = "permissions"

        /** The caller waiting for the open sheet; one at a time (a newer ask replaces it). */
        @Volatile private var pending: ((Set<String>?, String?) -> Unit)? = null

        /** Opens Health Connect's sheet for [want] over whatever is on screen; [done] on the main thread when it closes. */
        fun ask(
            context: Context,
            want: Set<String>,
            done: (Set<String>?, String?) -> Unit,
        ) {
            pending?.invoke(null, "another request replaced this one")
            pending = done
            context.startActivity(
                Intent(context, HealthGrantActivity::class.java)
                    .putStringArrayListExtra(EXTRA_PERMISSIONS, ArrayList(want))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION),
            )
        }
    }
}

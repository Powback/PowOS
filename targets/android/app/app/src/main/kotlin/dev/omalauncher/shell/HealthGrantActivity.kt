package dev.omalauncher.shell

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.health.connect.client.PermissionController

/**
 * A tiny transparent PowOS activity that asks Health Connect for permissions and finishes ([HealthConnectBridge.grant]).
 *
 * Health Connect's sheet must be started for a result from an activity of the asking app. The Health page and widget
 * run in app islands, overlays and the AI page - WebViews with no activity of their own ([ShellHost] with a null
 * activity) - so the bridge refused there and "Allow" did nothing. This activity is that window, whatever the surface.
 * The contract is androidx's ([PermissionController.createRequestPermissionResultContract]), launched through this
 * ComponentActivity's result registry: on SDK 34+ it is a runtime-permission request Android hands to Health Connect.
 */
class HealthGrantActivity : ComponentActivity() {
    // Registered as a field, before STARTED, so a recreated activity (a fold, rotation) gets the open sheet's answer too.
    // The registry is required: on SDK 34+ androidx's contract is ActivityResultContracts.RequestMultiplePermissions,
    // whose intent (androidx.activity.result.contract.action.REQUEST_PERMISSIONS) resolves to nothing and works only
    // through a ComponentActivity's registry (it turns it into requestPermissions, which Android routes to Health
    // Connect's sheet). Started by hand with startActivityForResult from a plain Activity it failed with -91
    // (START_INTENT_NOT_RESOLVED) and came back at once as "nothing granted": "nothing happens when I press allow".
    private val launcher =
        registerForActivityResult(PermissionController.createRequestPermissionResultContract()) { granted ->
            Log.i(TAG, "Health Connect answered: granted=${granted.size} $granted")
            answer(granted, null)
        }

    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)
        // Recreated while the sheet is open: its result still comes to [launcher].
        if (saved != null) return
        val want = intent.getStringArrayListExtra(EXTRA_PERMISSIONS).orEmpty().toSet()
        try {
            Log.i(TAG, "asking Health Connect for ${want.size} permissions")
            launcher.launch(want)
        } catch (e: Exception) {
            Log.w(TAG, "Health Connect's permission sheet didn't open", e)
            answer(null, e.message ?: e.toString())
        }
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

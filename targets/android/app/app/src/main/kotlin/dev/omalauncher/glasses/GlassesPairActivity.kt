package dev.omalauncher.glasses

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.le.ScanResult
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Intent
import android.content.IntentSender
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import java.util.regex.Pattern

/**
 * Pairing the glasses with Android's companion device flow (CompanionDeviceManager): the system scans and shows its
 * own picker of nearby Even arms - so PowOS needs no location permission and no scan code of its own - and the
 * association lets Android tell PowOS when the glasses are in range again ([GlassesPresenceService]).
 *
 * Two steps, one per arm: any G1/G2 arm first (a list to pick from), then that pair's other arm (a single-device
 * confirmation). Each arm's name says its model, pair and side ("Even G2_84_L_..."). Then they connect. Invisible
 * itself (translucent): only the system's dialogs show.
 */
@SuppressLint("MissingPermission")
class GlassesPairActivity : Activity() {
    private var first: GlassesName? = null
    private val found = ArrayList<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Glasses.init(this)
        ask(GlassesName.pattern(), single = false)
    }

    private fun ask(
        pattern: String,
        single: Boolean,
    ) {
        val cdm = getSystemService(CompanionDeviceManager::class.java) ?: return done("Android's companion pairing isn't available")
        val filter = BluetoothLeDeviceFilter.Builder().setNamePattern(Pattern.compile(pattern)).build()
        val request = AssociationRequest.Builder().addDeviceFilter(filter).setSingleDevice(single).build()
        runCatching {
            cdm.associate(
                request,
                object : CompanionDeviceManager.Callback() {
                    @Deprecated("onAssociationPending on API 33+ (whose default calls this)")
                    override fun onDeviceFound(chooser: IntentSender) {
                        runCatching { startIntentSenderForResult(chooser, REQUEST, null, 0, 0, 0) }
                            .onFailure { done("couldn't show the pairing dialog: ${it.message}") }
                    }

                    override fun onFailure(error: CharSequence?) = step(null, null, error?.toString() ?: "not found")
                },
                null,
            )
        }.onFailure { done("pairing failed: ${it.message}") }
    }

    @Deprecated("Activity result API: this activity has no other result")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST) return
        if (resultCode != RESULT_OK || data == null) return step(null, null, "cancelled")
        @Suppress("DEPRECATION")
        val picked = data.getParcelableExtra<android.os.Parcelable>(CompanionDeviceManager.EXTRA_DEVICE)
        val (address, name) =
            when (picked) {
                is ScanResult -> picked.device.address to (picked.scanRecord?.deviceName ?: picked.device.name)
                is BluetoothDevice -> picked.address to picked.name
                else -> null to null
            }
        step(address, name, if (address == null) "no device in the result" else null)
    }

    /** An arm picked (or not, with [error]): remembered, then the other arm, then connect. */
    private fun step(
        address: String?,
        name: String?,
        error: String?,
    ) {
        if (address != null) {
            val n = Glasses.remember(address, name)
            if (n == null) return done("$name isn't an Even G1/G2 arm")
            found += address
            observe(address)
            if (first == null) {
                first = n
                // The same pair's other arm.
                val other = if (n.side == GlassesSide.LEFT) GlassesSide.RIGHT else GlassesSide.LEFT
                return ask(GlassesName.pattern(n.pairId, other), single = true)
            }
        } else {
            Log.w(TAG, "pairing step: $error")
        }
        if (found.isEmpty()) return done("Glasses not paired: $error")
        Glasses.connect()
        done(if (found.size == 2) "Glasses paired" else "Glasses paired (one arm: ${error ?: "the other wasn't found"})")
    }

    /** Android tells us when this arm is in range again (API 31+). */
    private fun observe(address: String) {
        if (Build.VERSION.SDK_INT < 31) return
        runCatching {
            @Suppress("DEPRECATION")
            getSystemService(CompanionDeviceManager::class.java)?.startObservingDevicePresence(address)
        }.onFailure { Log.w(TAG, "presence not observed for $address", it) }
    }

    private fun done(message: String) {
        Log.i(TAG, message)
        Toast.makeText(applicationContext, message, Toast.LENGTH_LONG).show()
        finish()
    }

    private companion object {
        const val TAG = "PowosGlasses"
        const val REQUEST = 0x61a
    }
}

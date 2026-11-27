package dev.omalauncher.system

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import org.json.JSONObject

/**
 * Passwords and passkeys on PowOS: PowPass (its own repo ~/Projects/PowPass, app `pow.powpass`, served at powpass.pow,
 * sign-in through PowAuth) is the vault AND the fill provider - its AutofillService fills apps and Chrome, offers to
 * save on submit and unlocks with the fingerprint; its CredentialProviderService serves passkeys. PowOS stores no
 * credential and runs no second autofill service (Android takes one): it shows whether PowPass is the phone's provider
 * and takes the user to the one place that sets it. docs/research/autofill.md.
 *
 * Rooted or not alike: nothing here needs root. The settings tile "passwords" (ui/screens.tsx) shows [json]; its tap is
 * [open].
 */
object Passwords {
    const val PACKAGE = "pow.powpass"
    private const val STORE_APP = "com.powapps"
    private const val STORE_APK = "http://android.pow/apk/powpass.apk"

    /** Android 14's "Passwords, passkeys & accounts" page (Settings.ACTION_CREDENTIAL_PROVIDER, API 34). */
    private const val ACTION_CREDENTIAL_PROVIDER = "android.settings.CREDENTIAL_PROVIDER"

    /** What the tile says: PowPass missing, installed but not picked, or the phone's provider. */
    enum class State { MISSING, NOT_PICKED, ON, UNKNOWN }

    /**
     * [autofill] / [credential] are Settings.Secure's picked services ("pkg/cls", credential_service is a ":" list);
     * null when Android didn't let PowOS read them. Pure: PasswordsTest.
     */
    fun state(
        installed: Boolean,
        autofill: String?,
        credential: String?,
    ): State {
        if (!installed) return State.MISSING
        if (autofill == null && credential == null) return State.UNKNOWN
        val picked = listOfNotNull(autofill, credential).flatMap { it.split(':') }.any { it.substringBefore('/') == PACKAGE }
        return if (picked) State.ON else State.NOT_PICKED
    }

    fun line(s: State): String =
        when (s) {
            State.MISSING -> "get PowPass to fill passwords"
            State.NOT_PICKED -> "PowPass is installed: pick it to fill"
            State.ON -> "PowPass fills passwords and passkeys"
            State.UNKNOWN -> "PowPass: passwords and passkeys"
        }

    private fun installed(c: Context) = runCatching { c.packageManager.getPackageInfo(PACKAGE, 0) }.isSuccess

    // Both keys are @Readable for apps on the phones PowOS runs on; a vendor that refuses gives UNKNOWN, never a crash.
    private fun secure(
        c: Context,
        key: String,
    ): String? = runCatching { Settings.Secure.getString(c.contentResolver, key) ?: "" }.getOrNull()

    fun current(c: Context): State = state(installed(c), secure(c, "autofill_service"), secure(c, "credential_service"))

    fun json(c: Context): JSONObject = current(c).let { JSONObject().put("state", it.name.lowercase()).put("line", line(it)) }

    /**
     * The tile's tap: PowPass itself once it fills (its vault), Android's provider page while it isn't picked (Android
     * lets only the service's own app ask to be picked), the PowApps store (or the APK) while it is missing.
     */
    fun open(
        c: Context,
        start: (Intent) -> Unit,
    ) {
        when (current(c)) {
            State.ON -> c.packageManager.getLaunchIntentForPackage(PACKAGE)?.let(start)
            State.NOT_PICKED, State.UNKNOWN ->
                start(Intent(if (Build.VERSION.SDK_INT >= 34) ACTION_CREDENTIAL_PROVIDER else Settings.ACTION_SETTINGS))
            State.MISSING ->
                start(c.packageManager.getLaunchIntentForPackage(STORE_APP) ?: Intent(Intent.ACTION_VIEW, Uri.parse(STORE_APK)))
        }
    }
}

package dev.omalauncher.devices

import android.content.Context
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * An app's secrets (a Hue bridge's key) in the owner's account, so every device signed in to it has them without
 * pairing again (the user, 11-24: "i paired lights on one phone I dont want to go through the pairing process again").
 * The account store is the realm on PowStation (enroll/powos-enroll.py /v1/account/secret): AES-GCM encrypted there,
 * answered only to an enrolled, unrevoked device's own token ([PowStation.credentials]). Rows that sync between devices
 * never carry a secret (lib/apps/powos-account-sync); [dev.omalauncher.shell.ShellNet] keeps the device's copy and
 * calls this. docs/REMOTE-POWOS.md §2.5 "Secrets".
 */
object AccountSecrets {
    sealed interface Got {
        data class Value(val value: String) : Got

        /** The account has none (never kept, or forgotten on another device). */
        data object None : Got

        /** This device isn't in the account any more (revoked, left): what it got from the account goes. */
        data object Revoked : Got

        /** Not joined, or PowStation not reachable right now (away without the VPN): keep what is here. */
        data object Unknown : Got
    }

    fun get(
        c: Context,
        app: String,
        name: String,
    ): Got {
        val (realm, token) = PowStation.credentials(c) ?: return Got.Unknown
        val (st, r) = call("GET", "$realm/v1/account/secret?app=${enc(app)}&name=${enc(name)}", null, token) ?: return Got.Unknown
        return outcome(st, r)
    }

    /** Keeps [value] in the account ("" / null drops it). True when the account has it now. */
    fun put(
        c: Context,
        app: String,
        name: String,
        value: String?,
    ): Boolean {
        val (realm, token) = PowStation.credentials(c) ?: return false
        val body = JSONObject().put("app", app).put("name", name).put("value", value ?: JSONObject.NULL)
        return call("POST", "$realm/v1/account/secret", body, token)?.first == 200
    }

    /** The realm's answer as a [Got] (pure: AccountSecretsTest). */
    fun outcome(
        status: Int,
        r: JSONObject,
    ): Got =
        when {
            status == 200 && r.optString("value").isNotEmpty() -> Got.Value(r.getString("value"))
            status == 404 -> Got.None
            status == 401 -> Got.Revoked
            else -> Got.Unknown
        }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    // HACK: plain HTTP to the realm on the LAN/VPN, as PowStation.kt's own calls (the realm serves only that): a secret
    // crosses the LAN/VPN leg unencrypted. Real fix: the realm CA / a .pow certificate (device-ecosystem.md P4).
    private fun call(
        method: String,
        url: String,
        body: JSONObject?,
        token: String,
    ): Pair<Int, JSONObject>? =
        runCatching {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.requestMethod = method
            conn.connectTimeout = 2500
            conn.readTimeout = 5000
            conn.setRequestProperty("Authorization", "Bearer $token")
            try {
                if (body != null) {
                    conn.doOutput = true
                    conn.setRequestProperty("Content-Type", "application/json")
                    conn.outputStream.use { it.write(body.toString().toByteArray()) }
                }
                val st = conn.responseCode
                val text = (if (st < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
                st to (runCatching { JSONObject(text) }.getOrNull() ?: JSONObject())
            } finally {
                conn.disconnect()
            }
        }.getOrNull()
}

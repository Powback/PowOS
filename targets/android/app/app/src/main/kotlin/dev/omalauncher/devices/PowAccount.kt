package dev.omalauncher.devices

import android.content.Context
import android.content.Intent
import android.net.Uri
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * "Sign in to your Pow account" on this device (docs/DEVICES.md, the user 11-23: "I guess we need to signin to auth.pow
 * or something?"). PowAuth (https://auth.powback.com, public, a publicly trusted certificate) is asked the way a native
 * app asks an OpenID provider (RFC 8252): the authorization code flow with PKCE, in the phone's own browser, back to a
 * one-shot listener on this phone's loopback (http://127.0.0.1:<port>/callback; PowAuth matches loopback redirects on
 * any port). The owner types the owner account's password (and 2FA, as PowAuth's policy says) on PowAuth's page - never
 * into PowOS. What comes back is a 1 h access token, used once by [PowStation] to show the realm who signed in; it is
 * not stored and no refresh token is asked for.
 *
 * [info] is the realm's GET /v1/realm `signin` block: {issuer, client_id, scope}.
 */
object PowAccount {
    private val rnd = SecureRandom()

    /** Blocks until the browser comes back (or [timeoutMs]); the access token, or throws with words for the user. */
    fun signIn(
        c: Context,
        info: JSONObject,
        timeoutMs: Int = 5 * 60_000,
    ): String {
        val issuer = info.optString("issuer").trimEnd('/')
        require(issuer.startsWith("https://")) { "the PowStation names no Pow account sign-in" }
        val client = info.optString("client_id").ifBlank { "powos-device" }
        val scope = info.optString("scope").ifBlank { "openid profile groups" }
        val disco = getJson("$issuer/.well-known/openid-configuration")
        val authorize = disco.optString("authorization_endpoint").ifBlank { "$issuer/api/oidc/authorization" }
        val tokenUrl = disco.optString("token_endpoint").ifBlank { "$issuer/api/oidc/token" }
        val verifier = b64(bytes(48))
        val state = b64(bytes(16))
        ServerSocket(0, 4, InetAddress.getByName("127.0.0.1")).use { srv ->
            srv.soTimeout = timeoutMs
            val redirect = "http://127.0.0.1:${srv.localPort}/callback"
            val url = authorizeUrl(authorize, client, redirect, scope, state, challengeOf(verifier))
            c.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            val deadline = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < deadline) {
                val s =
                    try {
                        srv.accept()
                    } catch (_: SocketTimeoutException) {
                        break
                    }
                val q = s.use { callback(it, state) } ?: continue
                bringBack(c)
                q["error"]?.let { throw IllegalStateException(q["error_description"] ?: it) }
                check(q["state"] == state) { "the sign-in answer didn't match this request - try again" }
                val code = checkNotNull(q["code"]) { "PowAuth sent no code - try again" }
                return exchange(tokenUrl, client, redirect, code, verifier)
            }
            throw IllegalStateException("the sign-in wasn't finished in time - try again")
        }
    }

    /** One browser request on the loopback: the callback's query (answered with a page), or null for anything else. */
    private fun callback(
        s: Socket,
        state: String,
    ): Map<String, String>? {
        s.soTimeout = 10_000
        val line = runCatching { BufferedReader(InputStreamReader(s.getInputStream())).readLine() }.getOrNull() ?: return null
        val target = line.split(' ').getOrNull(1) ?: return null
        if (!target.startsWith("/callback")) {
            reply(s, 404, "<p>Not here.</p>")
            return null
        }
        val q = queryOf(target.substringAfter('?', ""))
        val ok = q["code"] != null && q["state"] == state
        reply(
            s,
            200,
            if (ok) {
                "<h2>Signed in</h2><p>Go back to PowOS - it finishes there by itself.</p>"
            } else {
                "<h2>Not signed in</h2><p>${esc(q["error_description"] ?: q["error"] ?: "try again in PowOS")}</p>"
            },
        )
        return q
    }

    private fun reply(
        s: Socket,
        status: Int,
        body: String,
    ) = runCatching {
        val html =
            "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>" +
                "<title>PowOS</title><body style='font:18px system-ui;margin:2em;background:#0f172a;color:#e2e8f0'>$body" +
                "<script>setTimeout(function(){window.close()},800)</script>"
        val b = html.toByteArray()
        val head = "HTTP/1.1 $status ${if (status == 200) "OK" else "Not Found"}\r\nContent-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: ${b.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        s.getOutputStream().apply {
            write(head.toByteArray())
            write(b)
            flush()
        }
    }

    /** PowOS to the front again (best effort: Android may hold a background start back; the page says go back). */
    private fun bringBack(c: Context) {
        runCatching {
            c.packageManager.getLaunchIntentForPackage(c.packageName)?.let {
                c.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
            }
        }
    }

    private fun exchange(
        tokenUrl: String,
        client: String,
        redirect: String,
        code: String,
        verifier: String,
    ): String {
        val form =
            listOf(
                "grant_type" to "authorization_code",
                "code" to code,
                "redirect_uri" to redirect,
                "client_id" to client,
                "code_verifier" to verifier,
            ).joinToString("&") { (k, v) -> "$k=${enc(v)}" }
        val conn = URL(tokenUrl).openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.connectTimeout = 10_000
        conn.readTimeout = 10_000
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        conn.setRequestProperty("Accept", "application/json")
        try {
            conn.outputStream.use { it.write(form.toByteArray()) }
            val st = conn.responseCode
            val text = (if (st < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            val r = runCatching { JSONObject(text) }.getOrNull() ?: JSONObject()
            val at = r.optString("access_token")
            check(st == 200 && at.isNotBlank()) {
                "PowAuth didn't finish the sign-in: " + r.optString("error_description").ifBlank { r.optString("error").ifBlank { "HTTP $st" } }
            }
            return at
        } finally {
            conn.disconnect()
        }
    }

    private fun getJson(url: String): JSONObject =
        runCatching {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 8000
            conn.readTimeout = 8000
            try {
                JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
            } finally {
                conn.disconnect()
            }
        }.getOrElse { JSONObject() }

    // --- pure (PowAccountTest)

    fun authorizeUrl(
        endpoint: String,
        client: String,
        redirect: String,
        scope: String,
        state: String,
        challenge: String,
    ) = endpoint + "?" +
        listOf(
            "response_type" to "code",
            "client_id" to client,
            "redirect_uri" to redirect,
            "scope" to scope,
            "state" to state,
            "code_challenge" to challenge,
            "code_challenge_method" to "S256",
        ).joinToString("&") { (k, v) -> "$k=${enc(v)}" }

    /** RFC 7636 S256: base64url(sha256(verifier)), no padding. */
    fun challengeOf(verifier: String): String = b64(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)))

    fun queryOf(q: String): Map<String, String> =
        q.split('&').filter { '=' in it }.associate {
            URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('='), "UTF-8")
        }

    private fun bytes(n: Int) = ByteArray(n).also { rnd.nextBytes(it) }

    private fun b64(b: ByteArray) = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(b)

    private fun enc(v: String) = URLEncoder.encode(v, "UTF-8")

    private fun esc(v: String) = v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
}

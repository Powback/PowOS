package dev.omalauncher.shell

import android.content.Context
import android.util.Log
import dev.omalauncher.R
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Date
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory

/**
 * HTTPS for `.pow` web apps, so getUserMedia works in them (docs/WEB_WINDOWS.md "Web app permissions"). `.pow` is plain
 * HTTP and Chromium gives the mic/camera (and geolocation) only to a secure context; Android's WebView has no API to
 * mark an origin trustworthy (Chrome's unsafely-treat-insecure-origin-as-secure is a command-line flag a release
 * WebView reads only on a debuggable build). PowStation already has the fleet answer: its local CA
 * (PowStation/bin/pow-local-cert, name-constrained to `.pow`) issues a cert per host served on `websecure` (LAN/VPN
 * only, local-only@docker). PowOS carries that CA's certificate (res/raw/pow_ca.pem, public) and trusts it ONLY for
 * `.pow` hosts in WebAppActivity: a cert for a `.pow` host signed by it, valid now, naming the host. Nothing else is
 * relaxed - every other site, error kind and the rest of the app keep Android's normal TLS checks.
 *
 * A web app whose host answers over HTTPS with such a cert opens on https (WebAppTls.url); the rest stay on http (no
 * mic there: the host needs `pow-local-cert <host>` + a websecure router, the way powmap.pow and voiceagent.pow have).
 */
object PowCa {
    fun parse(pem: InputStream): X509Certificate = pem.use { CertificateFactory.getInstance("X.509").generateCertificate(it) as X509Certificate }

    /** [leaf] (what [host] presented) is a `.pow` server cert for [host] signed by [ca] and valid at [now]. */
    fun trusts(
        ca: X509Certificate,
        host: String?,
        leaf: X509Certificate?,
        now: Date = Date(),
    ): Boolean {
        if (leaf == null || !WebAppSync.isPowHost(host)) return false
        return runCatching {
            if (leaf.basicConstraints >= 0) return false // a CA, not a server cert
            leaf.verify(ca.publicKey)
            leaf.checkValidity(now)
            ca.checkValidity(now)
            leaf.subjectAlternativeNames.orEmpty().any { it.size >= 2 && it[0] == 2 && (it[1] as? String)?.lowercase() == host }
        }.getOrDefault(false)
    }

    /** An SSL context that trusts [ca] alone (the HTTPS probe; never used for anything but `.pow` hosts). */
    fun sslContext(ca: X509Certificate): SSLContext {
        val ks = KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null, null); setCertificateEntry("pow-ca", ca) }
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(ks) }
        return SSLContext.getInstance("TLS").apply { init(null, tmf.trustManagers, null) }
    }

    /** A probe answer that means the site is served on https (not Traefik's 404 for a host without a websecure router). */
    fun serves(code: Int) = code in 200..399 || code == 401

    /** [url] on https (same host, path and query); null: not an http `.pow` URL. */
    fun httpsOf(url: String): String? =
        url.takeIf { it.startsWith("http://", ignoreCase = true) && WebAppSync.isPowHost(WebAppSync.hostOf(it)) }?.let { "https://" + it.substring(7) }
}

/** Which `.pow` hosts serve HTTPS with a PowStation-CA cert: remembered per host (prefs "webapp-tls"), re-checked on each open. */
object WebAppTls {
    private const val TAG = "PowosWebTls"
    private val io = Executors.newSingleThreadExecutor { Thread(it, "powos-webapp-tls").apply { isDaemon = true } }

    @Volatile private var ca: X509Certificate? = null

    fun ca(context: Context): X509Certificate? =
        ca ?: runCatching { PowCa.parse(context.resources.openRawResource(R.raw.pow_ca)) }.onFailure { Log.w(TAG, "no CA: ${it.message}") }.getOrNull()?.also { ca = it }

    private fun prefs(context: Context) = context.getSharedPreferences("webapp-tls", Context.MODE_PRIVATE)

    /**
     * The URL to open [url] on, handed to [then] (at once, or from a background thread after the probe): https when its host
     * was seen serving it, else after a quick probe (first open of a host). The answer is re-checked in the background
     * for next time either way.
     */
    fun url(
        context: Context,
        url: String,
        then: (String) -> Unit,
    ) {
        val https = PowCa.httpsOf(url) ?: return then(url)
        val host = WebAppSync.hostOf(url)!!
        val known = prefs(context).getString(host, null)
        if (known != null) then(if (known == "https") https else url)
        io.execute {
            val now = if (probe(context, https)) "https" else "http"
            if (now != known) {
                prefs(context).edit().putString(host, now).apply()
                Log.i(TAG, "$host: $now")
            }
            if (known == null) then(if (now == "https") https else url)
        }
    }

    private fun probe(
        context: Context,
        https: String,
    ): Boolean {
        val ca = ca(context) ?: return false
        return runCatching {
            val c = URL(https).openConnection() as HttpsURLConnection
            c.sslSocketFactory = PowCa.sslContext(ca).socketFactory
            c.connectTimeout = 1500
            c.readTimeout = 2000
            c.instanceFollowRedirects = false
            c.requestMethod = "HEAD"
            try {
                PowCa.serves(c.responseCode)
            } finally {
                (c as HttpURLConnection).disconnect()
            }
        }.getOrDefault(false)
    }
}

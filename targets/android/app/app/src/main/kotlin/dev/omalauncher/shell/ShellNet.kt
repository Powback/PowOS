package dev.omalauncher.shell

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.IOException
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URL
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

/**
 * PowOS apps' network capability (host.net in shell/apps/net.ts): the app's islands and pages reach the devices and
 * services their manifest declares - a Hue bridge, a printer, a TV - from the app itself, with no process of their
 * own. Commands come over ShellNative's port as "n.req <json>"; answers go back as "n.res" / "n.ev" / "n.st".
 *
 * Scope, per app (its installed powos-app.json, files/apps/<id>/current): `"net": [...]` lists what it may reach -
 * host names or addresses exactly, and "lan" for any private address (10/8, 172.16/12, 192.168/16, 169.254/16,
 * fc00::/7, fe80::/10, *.local). Nothing declared, nothing reachable.
 *
 * TLS: public hosts are checked against the system's CAs as always. A LAN device's self-signed certificate is pinned
 * on first use, per app and host:port (its SHA-256 in this app's private storage): later connections must present
 * the same one or fail ("certificate changed" - `forget` resets it).
 *
 * Secrets: an app's keys (a bridge's application key) are kept here, per app, never handed back to the page:
 * `capture` takes one out of a response (and blanks it there), `${secret:name}` in a header puts it in.
 *
 * Ops (n.req {"id", "op", "app", ...}):
 *   fetch  {url, method?, headers?, body?, capture?: {secret, path: "0.success.username"}}  -> {status, body}
 *   events {sub, url, headers?}   Server-sent events, one connection per sub, reconnected with backoff until close:
 *                                 "n.ev {sub, event, data}" per event, "n.st {sub, state: open|retry|closed, error}"
 *   close  {sub}
 *   mdns   {type: "_hue._tcp", ms?}  -> {services: [{name, host, port, txt}]} (needs "lan")
 *   secret {name}               -> {has}
 *   forget {host?, secret?}     drops a pin and/or a secret
 *
 * HACK: the app id is the island's word for itself - islands are imported into the shell page, one origin, so one
 * could name another app's id and use its grants. Real fix: per-app origins (islands in <id>.app.powos iframes, the
 * feasibility study's section 6.1) and the id taken from the calling frame's origin.
 */
class ShellNet(
    private val context: Context,
    private val reply: (String) -> Unit,
) {
    private val pool = Executors.newCachedThreadPool()
    private val subs = ConcurrentHashMap<String, Stream>()
    private val pins = context.getSharedPreferences("powos-net-pins", Context.MODE_PRIVATE)
    private val secrets = context.getSharedPreferences("powos-net-secrets", Context.MODE_PRIVATE)
    private val factories = ConcurrentHashMap<String, SSLSocketFactory>()

    fun command(json: String) {
        val r =
            try {
                JSONObject(json)
            } catch (e: Exception) {
                Log.w(TAG, "bad request: $e")
                return
            }
        val id = r.optString("id")
        pool.execute {
            val out =
                try {
                    handle(r)
                } catch (e: Exception) {
                    JSONObject().put("error", e.message ?: e.toString())
                }
            if (out != null) reply("n.res " + out.put("id", id))
        }
    }

    /** The page reloaded or went: every stream it had goes. */
    fun reset() {
        subs.values.forEach { it.stop() }
        subs.clear()
    }

    private fun handle(r: JSONObject): JSONObject? {
        val app = r.optString("app")
        require(APP_ID.matches(app)) { "bad app id" }
        val ok = JSONObject()
        when (r.optString("op")) {
            "fetch" -> return fetch(app, r)
            "events" -> {
                val sub = app + "/" + r.getString("sub")
                val url = allowed(app, r.getString("url"))
                subs.remove(sub)?.stop()
                subs[sub] = Stream(app, sub, url, headers(app, r.optJSONObject("headers"))).also { pool.execute(it) }
            }
            "close" -> subs.remove(app + "/" + r.getString("sub"))?.stop()
            "mdns" -> {
                require("lan" in declared(app)) { "$app doesn't declare \"lan\" in its manifest's net" }
                return ok.put("services", mdns(r.getString("type"), r.optLong("ms", 3000).coerceIn(500, 10_000)))
            }
            "secret" -> return ok.put("has", secrets.contains(key(app, r.getString("name"))))
            "forget" -> {
                r.optString("host").takeIf { it.isNotEmpty() }?.let { h ->
                    pins.edit().apply { pins.all.keys.filter { it.startsWith("$app\u0000$h:") }.forEach { remove(it) } }.apply()
                    factories.keys.filter { it.startsWith("$app\u0000$h:") }.forEach { factories.remove(it) }
                }
                r.optString("secret").takeIf { it.isNotEmpty() }?.let { secrets.edit().remove(key(app, it)).apply() }
            }
            else -> throw IllegalArgumentException("no such op: ${r.optString("op")}")
        }
        return ok
    }

    // ---- scope ------------------------------------------------------------------------------------------------------

    private fun declared(app: String): List<String> {
        val f = File(context.filesDir, "apps/$app/current/powos-app.json")
        val net = runCatching { JSONObject(f.readText()).optJSONArray("net") }.getOrNull() ?: return emptyList()
        return (0 until net.length()).map { net.optString(it).lowercase() }
    }

    /** The URL if [app] may reach it, else an exception naming what to declare. */
    private fun allowed(
        app: String,
        url: String,
    ): URL {
        val u = URL(url)
        require(u.protocol == "https" || u.protocol == "http") { "only http(s)" }
        val host = u.host.lowercase().trim('[', ']')
        val net = declared(app)
        if (host in net) return u
        if ("lan" in net && private(host)) return u
        throw SecurityException("$app may not reach $host: add it (or \"lan\") to \"net\" in its powos-app.json")
    }

    private fun private(host: String): Boolean {
        if (host.endsWith(".local")) return true
        if (!IP_LITERAL.matches(host)) return false
        val a = runCatching { InetAddress.getByName(host) }.getOrNull() ?: return false
        return when (a) {
            is Inet4Address -> a.isSiteLocalAddress || a.isLinkLocalAddress
            is Inet6Address -> a.isLinkLocalAddress || (a.address[0].toInt() and 0xfe) == 0xfc
            else -> false
        }
    }

    // ---- requests ---------------------------------------------------------------------------------------------------

    private fun key(
        app: String,
        name: String,
    ) = "$app\u0000$name"

    private fun headers(
        app: String,
        h: JSONObject?,
    ): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        h?.keys()?.forEach { k ->
            out[k] =
                SECRET_REF.replace(h.getString(k)) { m ->
                    secrets.getString(key(app, m.groupValues[1]), null) ?: throw IllegalStateException("no secret ${m.groupValues[1]}")
                }
        }
        return out
    }

    private fun open(
        app: String,
        u: URL,
        headers: Map<String, String>,
    ): HttpURLConnection {
        val c = u.openConnection() as HttpURLConnection
        if (c is HttpsURLConnection && private(u.host.lowercase().trim('[', ']'))) {
            val pinKey = "$app\u0000${u.host.lowercase()}:${if (u.port > 0) u.port else 443}"
            c.sslSocketFactory = factories.getOrPut(pinKey) { pinned(pinKey) }
            // The pin is the device's identity; its certificate names a serial number, not the address.
            c.hostnameVerifier = javax.net.ssl.HostnameVerifier { _, _ -> true }
        }
        c.connectTimeout = 8_000
        c.readTimeout = 20_000
        c.useCaches = false
        headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
        return c
    }

    private fun fetch(
        app: String,
        r: JSONObject,
    ): JSONObject {
        val u = allowed(app, r.getString("url"))
        val c = open(app, u, headers(app, r.optJSONObject("headers")))
        try {
            c.requestMethod = r.optString("method", "GET").uppercase()
            if (r.has("body")) {
                c.doOutput = true
                if (c.getRequestProperty("Content-Type") == null) c.setRequestProperty("Content-Type", "application/json")
                c.outputStream.use { it.write(r.getString("body").toByteArray()) }
            }
            val status = c.responseCode
            var body = (if (status >= 400) c.errorStream else c.inputStream)?.use { it.readBytes().decodeToString() } ?: ""
            r.optJSONObject("capture")?.let { cap -> body = capture(app, cap, body) }
            return JSONObject().put("status", status).put("body", body)
        } finally {
            c.disconnect()
        }
    }

    /** Takes the secret at [cap].path ("0.success.username") out of a JSON body into this app's secrets. */
    private fun capture(
        app: String,
        cap: JSONObject,
        body: String,
    ): String {
        val root: Any = runCatching { JSONArray(body) }.getOrNull() ?: runCatching { JSONObject(body) }.getOrNull() ?: return body
        val path = cap.getString("path").split('.')
        var parent: Any = root
        for (p in path.dropLast(1)) {
            parent = (if (parent is JSONArray) parent.opt(p.toIntOrNull() ?: return body) else (parent as JSONObject).opt(p)) ?: return body
        }
        val last = path.last()
        val value =
            when (parent) {
                is JSONArray -> parent.opt(last.toIntOrNull() ?: return body)
                is JSONObject -> parent.opt(last)
                else -> null
            } as? String ?: return body
        secrets.edit().putString(key(app, cap.getString("secret")), value).apply()
        when (parent) {
            is JSONArray -> parent.put(last.toInt(), "(kept)")
            is JSONObject -> parent.put(last, "(kept)")
        }
        return root.toString()
    }

    /** A TLS factory trusting exactly the certificate first seen for [pinKey] (and pinning it then). */
    private fun pinned(pinKey: String): SSLSocketFactory {
        val trust =
            object : X509TrustManager {
                override fun checkClientTrusted(
                    chain: Array<out X509Certificate>?,
                    authType: String?,
                ) = throw CertificateException("no client certificates")

                override fun checkServerTrusted(
                    chain: Array<out X509Certificate>?,
                    authType: String?,
                ) {
                    val leaf = chain?.firstOrNull() ?: throw CertificateException("no certificate")
                    val sha = MessageDigest.getInstance("SHA-256").digest(leaf.encoded).joinToString("") { "%02x".format(it) }
                    val pin = pins.getString(pinKey, null)
                    if (pin == null) {
                        pins.edit().putString(pinKey, sha).apply()
                        Log.i(TAG, "pinned ${pinKey.substringAfter('\u0000')} for ${pinKey.substringBefore('\u0000')}")
                    } else if (pin != sha) {
                        throw CertificateException("the device's certificate changed (forget it to trust the new one)")
                    }
                }

                override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
            }
        return SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }.socketFactory
    }

    // ---- server-sent events -----------------------------------------------------------------------------------------

    private inner class Stream(
        private val app: String,
        private val sub: String,
        private val url: URL,
        private val headers: Map<String, String>,
    ) : Runnable {
        @Volatile private var stopped = false

        @Volatile private var conn: HttpURLConnection? = null

        fun stop() {
            stopped = true
            runCatching { conn?.disconnect() }
        }

        private fun state(
            s: String,
            error: String? = null,
        ) = reply("n.st " + JSONObject().put("sub", sub.substringAfter('/')).put("app", app).put("state", s).put("error", error ?: ""))

        override fun run() {
            var backoff = 1_000L
            while (!stopped) {
                try {
                    val c = open(app, url, headers + ("Accept" to "text/event-stream"))
                    // Quiet streams stay open; a dead network shows as this timeout and a reconnect.
                    c.readTimeout = 300_000
                    conn = c
                    if (c.responseCode != 200) throw IOException("HTTP ${c.responseCode}")
                    state("open")
                    backoff = 1_000L
                    BufferedReader(InputStreamReader(c.inputStream)).use { rd ->
                        var event = ""
                        val data = StringBuilder()
                        while (!stopped) {
                            val line = rd.readLine() ?: break
                            when {
                                line.isEmpty() -> {
                                    if (data.isNotEmpty()) {
                                        val ev = JSONObject().put("sub", sub.substringAfter('/')).put("app", app).put("event", event).put("data", data.toString())
                                        reply("n.ev $ev")
                                    }
                                    event = ""
                                    data.setLength(0)
                                }
                                line.startsWith(":") -> {}
                                line.startsWith("data:") -> {
                                    if (data.isNotEmpty()) data.append('\n')
                                    data.append(line.removePrefix("data:").removePrefix(" "))
                                }
                                line.startsWith("event:") -> event = line.removePrefix("event:").trim()
                            }
                        }
                    }
                } catch (e: Exception) {
                    if (stopped) break
                    state("retry", e.message ?: e.toString())
                    // A changed certificate or a refused scope won't heal by retrying fast.
                    if (e is SecurityException || e.cause is CertificateException) backoff = 60_000L
                } finally {
                    runCatching { conn?.disconnect() }
                }
                if (stopped) break
                Thread.sleep(backoff)
                backoff = (backoff * 2).coerceAtMost(30_000L)
            }
            state("closed")
        }
    }

    // ---- mDNS -------------------------------------------------------------------------------------------------------

    private fun mdns(
        type: String,
        ms: Long,
    ): JSONArray {
        val nsd = context.getSystemService(NsdManager::class.java)
        val found = JSONArray()
        val lock = Object()
        val thread = HandlerThread("PowosNetMdns").apply { start() }
        val pending = mutableListOf<NsdServiceInfo>()
        val listener =
            object : NsdManager.DiscoveryListener {
                override fun onStartDiscoveryFailed(
                    t: String?,
                    code: Int,
                ) = Unit

                override fun onStopDiscoveryFailed(
                    t: String?,
                    code: Int,
                ) = Unit

                override fun onDiscoveryStarted(t: String?) = Unit

                override fun onDiscoveryStopped(t: String?) = Unit

                override fun onServiceFound(info: NsdServiceInfo) {
                    synchronized(lock) { pending += info }
                }

                override fun onServiceLost(info: NsdServiceInfo) = Unit
            }
        try {
            nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
            Thread.sleep(ms)
        } finally {
            runCatching { nsd.stopServiceDiscovery(listener) }
        }
        val handler = Handler(thread.looper)
        for (info in synchronized(lock) { pending.toList() }) {
            val done = Object()
            var got: NsdServiceInfo? = null
            handler.post {
                @Suppress("DEPRECATION")
                nsd.resolveService(
                    info,
                    object : NsdManager.ResolveListener {
                        override fun onResolveFailed(
                            i: NsdServiceInfo?,
                            code: Int,
                        ) = synchronized(done) { done.notifyAll() }

                        override fun onServiceResolved(i: NsdServiceInfo) =
                            synchronized(done) {
                                got = i
                                done.notifyAll()
                            }
                    },
                )
            }
            synchronized(done) { if (got == null) done.wait(2_000) }
            val s = got ?: continue
            val txt = JSONObject()
            s.attributes.forEach { (k, v) -> txt.put(k, v?.decodeToString() ?: "") }
            @Suppress("DEPRECATION")
            found.put(JSONObject().put("name", s.serviceName).put("host", s.host?.hostAddress ?: "").put("port", s.port).put("txt", txt))
        }
        thread.quitSafely()
        return found
    }

    companion object {
        private const val TAG = "PowosNet"
        private val APP_ID = Regex("^[a-z0-9][a-z0-9.-]{0,63}$")
        private val IP_LITERAL = Regex("^[0-9.]+$|^[0-9a-f:]+(%.*)?$")
        private val SECRET_REF = Regex("""\$\{secret:([a-zA-Z0-9_.-]{1,64})\}""")
    }
}

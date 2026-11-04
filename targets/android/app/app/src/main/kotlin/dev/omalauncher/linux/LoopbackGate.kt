package dev.omalauncher.linux

import android.content.Context
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The launcher's own way to PowOS's services on a phone WITHOUT root (docs/research/nonroot-parity.md, "Who can reach
 * SpacetimeDB and the App API"). Android's loopback is shared by every installed app and only root can lock a TCP port
 * to one uid, so in the no-root PowOS image SpacetimeDB (3410) and the App API (3411) listen on NO TCP port: their
 * binds become Unix sockets in the app's private files (engine loopback-unix.c, preloaded by lotfix-run), which only
 * this app's uid can open - the image's own clients (the agents' tools, `powos app`, the starter) reach them the same
 * way. The WebView can't open a Unix socket, so for the page and ShellNet this gate listens on a random 127.0.0.1
 * port per service and forwards to the socket only requests whose path starts with /_powos/<token>/ - a per-install
 * random token (files/powos-loopback.token, private to the app), compared in constant time, stripped before the
 * service sees the request. Everything else gets 403 and never reaches the service. The page gets its URL from
 * apps.local ([url]); ShellNet routes http://127.0.0.1:3410|3411 through [route].
 *
 * Rooted phones: powos-start.sh locks the TCP ports to this uid and nothing here runs.
 */
object LoopbackGate {
    private const val TAG = "LoopbackGate"
    const val PREFIX = "/_powos/"
    val PORTS = intArrayOf(3410, 3411)

    @Volatile private var gates: Map<Int, Gate> = emptyMap()

    @Volatile private var token: String? = null

    /** Starts the gates once (no root only; idempotent). */
    @Synchronized
    fun ensure(ctx: Context) {
        if (RootedGuest.enabled || gates.isNotEmpty()) return
        val t = token(ctx)
        val dir = andro.marchy.SessionService.loopbackDir(ctx)
        gates =
            PORTS.associateWith { port ->
                val path = File(dir, "$port.sock").path
                Gate(t) { unix(path) }.also { it.start() }
            }
        Log.i(TAG, "gates: " + gates.entries.joinToString { "${it.key}->${it.value.port}" })
    }

    /** The service on [port] for this app's own clients ("http://127.0.0.1:<gate>/_powos/<token>/"), null when not gated. */
    fun url(port: Int): String? {
        val g = gates[port] ?: return null
        return "http://127.0.0.1:${g.port}$PREFIX${g.token}/"
    }

    /** [u] through its gate when it names a gated service on loopback, else [u]. */
    fun route(
        ctx: Context,
        u: URL,
    ): URL {
        if (u.protocol != "http" || u.host !in LOOPBACK || u.port !in PORTS) return u
        ensure(ctx)
        val g = gates[u.port] ?: return u
        return URL("http", "127.0.0.1", g.port, PREFIX + g.token + (u.file.ifEmpty { "/" }))
    }

    /** The service on [port] answers on its Unix socket (no root). */
    fun up(
        ctx: Context,
        port: Int,
    ): Boolean = runCatching { unix(File(andro.marchy.SessionService.loopbackDir(ctx), "$port.sock").path).close() }.isSuccess

    /** This install's token: made once, kept in the app's private files. */
    @Synchronized
    fun token(ctx: Context): String {
        token?.let { return it }
        val f = File(ctx.filesDir, "powos-loopback.token")
        val t =
            f.takeIf { it.isFile }?.readText()?.trim()?.takeIf { TOKEN.matches(it) }
                ?: ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }.also { new ->
                    val tmp = File(ctx.filesDir, ".powos-loopback.token")
                    tmp.writeText(new)
                    tmp.setReadable(false, false)
                    tmp.setReadable(true, true)
                    tmp.renameTo(f)
                }
        token = t
        return t
    }

    private fun unix(path: String): Upstream {
        val s = LocalSocket()
        try {
            s.connect(LocalSocketAddress(path, LocalSocketAddress.Namespace.FILESYSTEM))
        } catch (e: IOException) {
            s.close()
            throw e
        }
        return Upstream(s.inputStream, s.outputStream) { s.close() }
    }

    private val LOOPBACK = setOf("127.0.0.1", "localhost")
    private val TOKEN = Regex("[0-9a-f]{64}")

    /** A connection to the service behind a gate. */
    class Upstream(
        val input: InputStream,
        val output: OutputStream,
        val close: () -> Unit,
    )

    /**
     * The request line [line] ("GET /_powos/<token>/v1/... HTTP/1.1") with the token taken out of its path when it
     * carries [token], else null (refused). Pure (LoopbackGateTest).
     */
    fun admit(
        line: String,
        token: String,
    ): String? {
        val parts = line.split(' ')
        if (parts.size != 3 || !parts[1].startsWith(PREFIX)) return null
        val rest = parts[1].substring(PREFIX.length)
        val end = rest.indexOfAny(charArrayOf('/', '?')).let { if (it < 0) rest.length else it }
        // Constant time: how much of the token matched never shows in the timing.
        if (!MessageDigest.isEqual(rest.substring(0, end).toByteArray(), token.toByteArray())) return null
        val path = rest.substring(end).let { if (it.startsWith("/")) it else "/$it" }
        return "${parts[0]} $path ${parts[2]}"
    }

    /** One service's gate: a random loopback port, each request admitted or refused, the rest piped. */
    class Gate(
        val token: String,
        private val connect: () -> Upstream,
    ) {
        private val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port: Int = server.localPort

        fun start() {
            Thread({
                while (!server.isClosed) {
                    val c = runCatching { server.accept() }.getOrNull() ?: continue
                    Thread({ serve(c) }, "loopback-gate-$port").apply { isDaemon = true }.start()
                }
            }, "loopback-gate").apply { isDaemon = true }.start()
        }

        fun stop() = runCatching { server.close() }

        private fun serve(client: Socket) {
            val c = Conn(client)
            try {
                client.use { while (c.next()) Unit }
            } catch (_: IOException) {
            } finally {
                c.up?.let { runCatching(it.close) }
            }
        }

        /** One client connection: each request admitted (forwarded, the token out) or refused. */
        private inner class Conn(
            private val client: Socket,
        ) {
            private val input = client.getInputStream().buffered()
            private val out = client.getOutputStream()
            var up: Upstream? = null

            /** Handles one request; false when the connection is done. */
            fun next(): Boolean {
                val lines = (readHead(input) ?: return false).split("\r\n")
                val line = admit(lines[0], token) ?: return answer(FORBIDDEN)
                val u = up ?: open() ?: return answer(UNAVAILABLE)
                u.output.write(((listOf(line) + lines.drop(1)).joinToString("\r\n") + "\r\n\r\n").toByteArray(Charsets.ISO_8859_1))
                u.output.flush()
                val h = lines.drop(1).associate { it.substringBefore(':').trim().lowercase() to it.substringAfter(':', "").trim().lowercase() }
                // A WebSocket or a chunked body: this connection's own bytes from here on (it was admitted).
                if ("upgrade" in h || h["transfer-encoding"]?.contains("chunked") == true) {
                    pipe(input, u.output) {}
                    return false
                }
                val length = h["content-length"]?.toLongOrNull() ?: 0L
                if (length > 0) copy(input, u.output, length)
                return true
            }

            private fun answer(status: ByteArray): Boolean {
                out.write(status)
                out.flush()
                return false
            }

            /** The service, opened on the first admitted request, its answers piped back. */
            private fun open(): Upstream? {
                val u = runCatching(connect).getOrNull() ?: return null
                up = u
                Thread({ pipe(u.input, out) { runCatching { client.shutdownOutput() } } }, "loopback-gate-up").apply { isDaemon = true }.start()
                return u
            }
        }
    }

    /** The request head up to its blank line (without it), null at the end of the stream; at most 64 KB. */
    internal fun readHead(input: InputStream): String? {
        val b = ByteArrayOutputStream()
        var tail = 0
        while (true) {
            val c = input.read()
            if (c < 0) return null
            b.write(c)
            tail = (tail shl 8) or c
            if (tail == 0x0d0a0d0a) return b.toString("ISO-8859-1").removeSuffix("\r\n\r\n")
            if (b.size() > 65536) throw IOException("request head too large")
        }
    }

    private fun copy(
        input: InputStream,
        out: OutputStream,
        n: Long,
    ) {
        val buf = ByteArray(16384)
        var left = n
        while (left > 0) {
            val r = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            if (r < 0) throw IOException("body cut short")
            out.write(buf, 0, r)
            left -= r
        }
        out.flush()
    }

    private fun pipe(
        input: InputStream,
        out: OutputStream,
        done: () -> Unit,
    ) {
        try {
            val buf = ByteArray(16384)
            while (true) {
                val r = input.read(buf)
                if (r < 0) break
                out.write(buf, 0, r)
                out.flush()
            }
        } catch (_: IOException) {
        } finally {
            done()
        }
    }

    private val FORBIDDEN = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray()
    private val UNAVAILABLE = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray()
}

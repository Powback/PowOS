package dev.omalauncher.ui

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/**
 * RFC 6455 framing, the little a client needs (the app has no OkHttp): masked frames out, whole messages in
 * (continuations joined, control frames returned as they come). Pure, so it's unit-tested (VoiceSocketTest).
 */
internal object WsFrames {
    const val CONT = 0x0
    const val TEXT = 0x1
    const val BINARY = 0x2
    const val CLOSE = 0x8
    const val PING = 0x9
    const val PONG = 0xA
    private const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    class Frame(
        val fin: Boolean,
        val op: Int,
        val payload: ByteArray,
    )

    /** The Sec-WebSocket-Accept a server must answer for [key]. */
    fun accept(key: String): String =
        Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1").digest((key + GUID).toByteArray()))

    /** One final frame, masked with [mask] (4 bytes) - a client's frames must be. */
    fun encode(
        op: Int,
        payload: ByteArray,
        mask: ByteArray,
    ): ByteArray {
        val n = payload.size
        val head = if (n < 126) 2 else if (n <= 0xffff) 4 else 10
        val out = ByteArray(head + 4 + n)
        out[0] = (0x80 or op).toByte()
        when (head) {
            2 -> out[1] = (0x80 or n).toByte()
            4 -> {
                out[1] = (0x80 or 126).toByte()
                out[2] = (n ushr 8).toByte()
                out[3] = n.toByte()
            }
            else -> {
                out[1] = (0x80 or 127).toByte()
                for (i in 0 until 8) out[2 + i] = (n.toLong() ushr (56 - 8 * i)).toByte()
            }
        }
        System.arraycopy(mask, 0, out, head, 4)
        for (i in 0 until n) out[head + 4 + i] = (payload[i].toInt() xor mask[i and 3].toInt()).toByte()
        return out
    }

    /** The next frame on [inp] (unmasked if the server masked it); EOFException at the stream's end. */
    fun read(inp: InputStream): Frame {
        val b0 = byte(inp)
        val b1 = byte(inp)
        var n = (b1 and 0x7f).toLong()
        if (n == 126L) n = ((byte(inp) shl 8) or byte(inp)).toLong()
        else if (n == 127L) {
            n = 0
            repeat(8) { n = (n shl 8) or byte(inp).toLong() }
        }
        if (n < 0 || n > 16L shl 20) throw IOException("frame too big ($n)")
        val mask = if (b1 and 0x80 != 0) ByteArray(4).also { full(inp, it) } else null
        val p = ByteArray(n.toInt()).also { full(inp, it) }
        if (mask != null) for (i in p.indices) p[i] = (p[i].toInt() xor mask[i and 3].toInt()).toByte()
        return Frame(b0 and 0x80 != 0, b0 and 0x0f, p)
    }

    /** The next whole message: [onControl] gets pings/pongs/closes as they come; a close returns as the message. */
    fun readMessage(
        inp: InputStream,
        onControl: (Frame) -> Unit,
    ): Frame {
        var op = -1
        val acc = ByteArrayOutputStream()
        while (true) {
            val f = read(inp)
            if (f.op >= 0x8) {
                onControl(f)
                if (f.op == CLOSE) return f
                continue
            }
            if (f.op != CONT) op = f.op
            acc.write(f.payload)
            if (f.fin && op >= 0) return Frame(true, op, acc.toByteArray())
        }
    }

    private fun byte(inp: InputStream): Int {
        val b = inp.read()
        if (b < 0) throw EOFException("closed")
        return b
    }

    private fun full(
        inp: InputStream,
        b: ByteArray,
    ) {
        var off = 0
        while (off < b.size) {
            val n = inp.read(b, off, b.size - off)
            if (n < 0) throw EOFException("closed")
            off += n
        }
    }
}

/**
 * A plain ws:// client on a socket: [connect] (blocking: the handshake), then [send]/[sendText] from any thread and
 * messages to [onText] on the reader thread until the connection ends ([onClosed], with why, once). No read timeout
 * (a dictation can be quiet for minutes); pings every [PING_MS] keep the route open and find a dead one (the write fails).
 */
internal class VoiceSocket(
    private val url: String,
    private val onText: (String) -> Unit,
    private val onClosed: (String?) -> Unit,
) {
    companion object {
        const val CONNECT_MS = 3000
        private const val PING_MS = 20_000L
    }

    private val rnd = SecureRandom()
    private var sock: Socket? = null
    private var out: OutputStream? = null

    @Volatile private var closed = false

    @Volatile private var lastSent = 0L

    fun connect() {
        val u = URI(url)
        val host = u.host ?: throw IOException("bad url")
        val port = if (u.port > 0) u.port else 80
        val s = Socket()
        sock = s
        s.tcpNoDelay = true
        s.connect(InetSocketAddress(host, port), CONNECT_MS)
        s.soTimeout = CONNECT_MS // the handshake only: afterwards no read timeout
        val key = Base64.getEncoder().encodeToString(ByteArray(16).also { rnd.nextBytes(it) })
        val o = s.getOutputStream()
        val path = (u.rawPath ?: "").ifEmpty { "/" } + (u.rawQuery?.let { "?$it" } ?: "")
        o.write(
            ("GET $path HTTP/1.1\r\nHost: $host${if (port != 80) ":$port" else ""}\r\nUpgrade: websocket\r\n" +
                "Connection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n").toByteArray(),
        )
        o.flush()
        val inp = BufferedInputStream(s.getInputStream())
        val status = line(inp)
        var accept: String? = null
        while (true) {
            val h = line(inp)
            if (h.isEmpty()) break
            val i = h.indexOf(':')
            if (i > 0 && h.substring(0, i).trim().equals("Sec-WebSocket-Accept", ignoreCase = true)) accept = h.substring(i + 1).trim()
        }
        if (!status.startsWith("HTTP/1.1 101")) throw IOException("upgrade refused: ${status.take(60)}")
        if (accept != WsFrames.accept(key)) throw IOException("bad handshake")
        s.soTimeout = 0
        out = o
        lastSent = System.currentTimeMillis()
        Thread({ readLoop(inp) }, "voice-ws-read").apply {
            isDaemon = true
            start()
        }
        Thread({
            while (!closed) {
                runCatching { Thread.sleep(1000) }
                if (!closed && System.currentTimeMillis() - lastSent >= PING_MS) runCatching { frame(WsFrames.PING, ByteArray(0)) }.onFailure { end("ping: ${it.message}") }
            }
        }, "voice-ws-ping").apply {
            isDaemon = true
            start()
        }
    }

    fun sendText(t: String) = frame(WsFrames.TEXT, t.toByteArray())

    fun send(pcm: ByteArray) = frame(WsFrames.BINARY, pcm)

    /** A clean close (code 1000); [onClosed] is not called for it. */
    fun close() {
        if (closed) return
        runCatching { frame(WsFrames.CLOSE, byteArrayOf(0x03, 0xe8.toByte())) }
        closed = true
        runCatching { sock?.close() }
    }

    private fun frame(
        op: Int,
        p: ByteArray,
    ) {
        val o = out ?: throw IOException("not connected")
        if (closed) throw IOException("closed")
        val mask = ByteArray(4).also { rnd.nextBytes(it) }
        val f = WsFrames.encode(op, p, mask)
        synchronized(o) {
            o.write(f)
            o.flush()
        }
        lastSent = System.currentTimeMillis()
    }

    private fun readLoop(inp: InputStream) {
        try {
            while (!closed) {
                val m =
                    WsFrames.readMessage(inp) { f ->
                        if (f.op == WsFrames.PING) runCatching { frame(WsFrames.PONG, f.payload) }
                    }
                when (m.op) {
                    WsFrames.CLOSE -> return end("the server closed the connection")
                    WsFrames.TEXT -> onText(String(m.payload))
                }
            }
        } catch (e: IOException) {
            end(e.message ?: e.javaClass.simpleName)
        }
    }

    private fun end(why: String?) {
        // After close(): ours, already known - no callback.
        if (closed) return
        closed = true
        runCatching { sock?.close() }
        onClosed(why)
    }

    private fun line(inp: InputStream): String {
        val b = StringBuilder()
        while (true) {
            val c = inp.read()
            if (c < 0) throw EOFException("closed during the handshake")
            if (c == '\n'.code) return b.toString().trimEnd('\r')
            b.append(c.toChar())
            if (b.length > 4096) throw IOException("bad handshake")
        }
    }
}

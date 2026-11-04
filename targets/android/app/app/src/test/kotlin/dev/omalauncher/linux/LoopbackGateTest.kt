package dev.omalauncher.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * No root (docs/research/nonroot-parity.md, "Who can reach SpacetimeDB and the App API"): the launcher's gate to the
 * services' private sockets lets through only requests carrying this install's token, and nothing else reaches them.
 */
class LoopbackGateTest {
    private val token = "ab".repeat(32)

    @Test
    fun aRequestWithTheTokenIsAdmittedWithTheTokenTakenOut() {
        assertEquals("GET /v1/database/x/subscribe?light=true HTTP/1.1", LoopbackGate.admit("GET /_powos/$token/v1/database/x/subscribe?light=true HTTP/1.1", token))
        assertEquals("POST /apps HTTP/1.1", LoopbackGate.admit("POST /_powos/$token/apps HTTP/1.1", token))
        assertEquals("GET / HTTP/1.1", LoopbackGate.admit("GET /_powos/$token HTTP/1.1", token))
        assertEquals("GET /?a=1 HTTP/1.1", LoopbackGate.admit("GET /_powos/$token?a=1 HTTP/1.1", token))
    }

    @Test
    fun aRequestWithoutTheRightTokenIsRefused() {
        assertNull(LoopbackGate.admit("GET /v1/database/x/sql HTTP/1.1", token))
        assertNull(LoopbackGate.admit("GET /_powos/v1/database/x HTTP/1.1", token))
        assertNull(LoopbackGate.admit("GET /_powos/${"cd".repeat(32)}/v1/database/x HTTP/1.1", token))
        assertNull(LoopbackGate.admit("GET /_powos/${token.dropLast(1)}/v1 HTTP/1.1", token))
        assertNull(LoopbackGate.admit("GET /_powos/${token}0/v1 HTTP/1.1", token))
        assertNull(LoopbackGate.admit("GET /_powos//v1 HTTP/1.1", token))
        assertNull(LoopbackGate.admit("garbage", token))
    }

    /** A stand-in service: answers each request with the request line it saw; counts its connections. */
    private class Service {
        val server = ServerSocket(0)
        val connections = AtomicInteger()
        val seen = CopyOnWriteArrayList<String>()

        init {
            Thread {
                while (true) {
                    val c = runCatching { server.accept() }.getOrNull() ?: break
                    connections.incrementAndGet()
                    Thread {
                        c.use {
                            val r = BufferedReader(InputStreamReader(c.getInputStream()))
                            val out = c.getOutputStream()
                            while (true) {
                                val line = r.readLine() ?: break
                                while ((r.readLine() ?: "").isNotEmpty()) Unit
                                seen.add(line)
                                out.write("HTTP/1.1 200 OK\r\nContent-Length: ${line.length}\r\n\r\n$line".toByteArray())
                                out.flush()
                            }
                        }
                    }.start()
                }
            }.apply { isDaemon = true }.start()
        }

        fun upstream(): LoopbackGate.Upstream {
            val s = Socket("127.0.0.1", server.localPort)
            return LoopbackGate.Upstream(s.getInputStream(), s.getOutputStream()) { s.close() }
        }
    }

    /** Sends [requests] on one connection to the gate; the responses' status lines and bodies. */
    private fun send(
        port: Int,
        vararg requests: String,
    ): List<String> =
        Socket("127.0.0.1", port).use { s ->
            s.soTimeout = 5000
            val r = BufferedReader(InputStreamReader(s.getInputStream()))
            requests.map { path ->
                s.getOutputStream().write("GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".toByteArray())
                response(r)
            }
        }

    /** One response: "<status line>|<body>", or "closed". */
    private fun response(r: BufferedReader): String {
        val status = r.readLine() ?: return "closed"
        val length = contentLength(r)
        val body = CharArray(length)
        var n = 0
        while (n < length) n += r.read(body, n, length - n)
        return "$status|${String(body)}"
    }

    /** Reads the headers up to the blank line; their Content-Length (0 without one). */
    private fun contentLength(r: BufferedReader): Int =
        generateSequence { r.readLine()?.takeIf { it.isNotEmpty() } }
            .lastOrNull { it.lowercase().startsWith("content-length:") }
            ?.substringAfter(':')?.trim()?.toInt() ?: 0

    @Test
    fun withoutTheTokenNothingReachesTheService() {
        val svc = Service()
        val gate = LoopbackGate.Gate(token) { svc.upstream() }.also { it.start() }
        try {
            assertEquals(listOf("HTTP/1.1 403 Forbidden|"), send(gate.port, "/v1/database/powos-agents/sql"))
            assertEquals(listOf("HTTP/1.1 403 Forbidden|"), send(gate.port, "/_powos/${"00".repeat(32)}/v1/database/powos-agents/sql"))
            Thread.sleep(100)
            assertEquals(0, svc.connections.get())
            assertTrue(svc.seen.isEmpty())
        } finally {
            gate.stop()
            svc.server.close()
        }
    }

    @Test
    fun powosOwnRequestsWorkAndEachOneNeedsTheToken() {
        val svc = Service()
        val gate = LoopbackGate.Gate(token) { svc.upstream() }.also { it.start() }
        try {
            val r = send(gate.port, "/_powos/$token/v1/database/local-pet/schema?version=9", "/_powos/$token/apps", "/apps")
            assertEquals("HTTP/1.1 200 OK|GET /v1/database/local-pet/schema?version=9 HTTP/1.1", r[0])
            assertEquals("HTTP/1.1 200 OK|GET /apps HTTP/1.1", r[1])
            // A later request on the same connection without the token: refused, never forwarded.
            assertEquals("HTTP/1.1 403 Forbidden|", r[2])
            assertEquals(listOf("GET /v1/database/local-pet/schema?version=9 HTTP/1.1", "GET /apps HTTP/1.1"), svc.seen.toList())
        } finally {
            gate.stop()
            svc.server.close()
        }
    }
}

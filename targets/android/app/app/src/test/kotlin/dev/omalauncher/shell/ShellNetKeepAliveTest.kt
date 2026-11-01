package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/** ShellNet's fetch keeps LAN connections alive: a response is read out and its stream closed, never disconnect(). */
class ShellNetKeepAliveTest {
    private class Tracked(bytes: ByteArray) : ByteArrayInputStream(bytes) {
        var closed = false

        override fun close() {
            closed = true
            super.close()
        }
    }

    private class Fake(private val status: Int, body: String) : HttpURLConnection(URL("https://192.168.50.2/api")) {
        val stream = Tracked(body.toByteArray())
        var disconnected = false

        override fun getResponseCode() = status

        override fun getInputStream(): InputStream = if (status < 400) stream else error("no body stream on an error")

        override fun getErrorStream(): InputStream? = if (status >= 400) stream else null

        override fun disconnect() {
            disconnected = true
        }

        override fun usingProxy() = false

        override fun connect() = Unit
    }

    @Test
    fun aResponseIsReadFullyAndClosedNotDisconnected() {
        val c = Fake(200, """[{"success":{"/lights/1/state/on":true}}]""")
        assertEquals(200 to """[{"success":{"/lights/1/state/on":true}}]""", ShellNet.readAndRelease(c))
        assertTrue(c.stream.closed)
        assertEquals(0, c.stream.available())
        assertFalse(c.disconnected)
    }

    @Test
    fun anErrorResponseIsReadFromTheErrorStreamAndAlsoKept() {
        val c = Fake(404, "nope")
        assertEquals(404 to "nope", ShellNet.readAndRelease(c))
        assertTrue(c.stream.closed)
        assertFalse(c.disconnected)
    }

    @Test
    fun theHostnameVerifierIsOneInstanceSoThePoolCanMatchIt() {
        assertSame(ShellNet.PIN_IS_IDENTITY, ShellNet.PIN_IS_IDENTITY)
    }
}

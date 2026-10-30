package dev.omalauncher.ui

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

/** The WebSocket framing and the voice agent's messages (the swipe keyboard's protocol), without a server. */
class VoiceSocketTest {
    private val mask = byteArrayOf(0x37, 0xfa.toByte(), 0x21, 0x3d)

    @Test fun acceptKeyIsRfc6455s() {
        assertEquals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", WsFrames.accept("dGhlIHNhbXBsZSBub25jZQ=="))
    }

    @Test fun maskedTextFrameIsRfc6455sExample() {
        val f = WsFrames.encode(WsFrames.TEXT, "Hello".toByteArray(), mask)
        val want = intArrayOf(0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58).map { it.toByte() }.toByteArray()
        assertArrayEquals(want, f)
        val back = WsFrames.read(ByteArrayInputStream(f))
        assertEquals(WsFrames.TEXT, back.op)
        assertEquals("Hello", String(back.payload))
    }

    @Test fun pcmFrameUsesTheTwoByteLength() {
        val pcm = ByteArray(VoiceAgentProtocol.CHUNK_BYTES) { it.toByte() }
        val f = WsFrames.encode(WsFrames.BINARY, pcm, mask)
        assertEquals(0x82, f[0].toInt() and 0xff)
        assertEquals(0x80 or 126, f[1].toInt() and 0xff)
        assertEquals(1024, ((f[2].toInt() and 0xff) shl 8) or (f[3].toInt() and 0xff))
        assertEquals(4 + 4 + 1024, f.size)
        assertArrayEquals(pcm, WsFrames.read(ByteArrayInputStream(f)).payload)
    }

    @Test fun bigFrameUsesTheEightByteLength() {
        val p = ByteArray(70_000) { (it * 7).toByte() }
        val f = WsFrames.encode(WsFrames.BINARY, p, mask)
        assertEquals(0x80 or 127, f[1].toInt() and 0xff)
        assertArrayEquals(p, WsFrames.read(ByteArrayInputStream(f)).payload)
    }

    @Test fun fragmentsJoinAndPingsPassThrough() {
        // Server frames are unmasked: "Hel" + ping + "lo".
        val s = ByteArrayOutputStream()
        s.write(byteArrayOf(0x01, 0x03) + "Hel".toByteArray())
        s.write(byteArrayOf(0x89.toByte(), 0x01, 0x78))
        s.write(byteArrayOf(0x80.toByte(), 0x02) + "lo".toByteArray())
        val pings = mutableListOf<Int>()
        val m = WsFrames.readMessage(ByteArrayInputStream(s.toByteArray())) { pings.add(it.op) }
        assertEquals(WsFrames.TEXT, m.op)
        assertEquals("Hello", String(m.payload))
        assertEquals(listOf(WsFrames.PING), pings)
    }

    @Test fun messagesParse() {
        assertEquals(
            VoiceAgentProtocol.Msg.Transcript("We need to call Matt.", true),
            VoiceAgentProtocol.parse("""{"type":"transcript","text":" We need to call Matt.","final":true}"""),
        )
        assertEquals(VoiceAgentProtocol.Msg.Transcript("All the GPUs.", false), VoiceAgentProtocol.parse("""{"type":"transcript","text":"All the GPUs.","final":false}"""))
        assertEquals(VoiceAgentProtocol.Msg.Phase("processing"), VoiceAgentProtocol.parse("""{"type":"state","phase":"processing","is_sleeping":false}"""))
        assertEquals(VoiceAgentProtocol.Msg.Error("boom"), VoiceAgentProtocol.parse("""{"type":"error","code":"x","message":"boom"}"""))
        assertEquals(VoiceAgentProtocol.Msg.Other, VoiceAgentProtocol.parse("""{"type":"config_sync"}"""))
        assertEquals(VoiceAgentProtocol.Msg.Other, VoiceAgentProtocol.parse("not json"))
        assertEquals("""{"type":"start","mode":"transcription_only"}""", VoiceAgentProtocol.START)
    }

    @Test fun pcmIsRechunkedTo512Samples() {
        val out = mutableListOf<ByteArray>()
        val r = VoiceAgentProtocol.Rechunker { out.add(it) }
        val twentyMs = ByteArray(640) { 1 }
        repeat(5) { r.write(twentyMs, twentyMs.size) } // 3200 bytes: 3 frames + 128 left
        assertEquals(3, out.size)
        r.flush()
        assertEquals(4, out.size)
        out.forEach { assertEquals(1024, it.size) }
        assertEquals(1.toByte(), out[3][127])
        assertEquals(0.toByte(), out[3][128])
    }
}

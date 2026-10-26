package dev.omalauncher.glasses

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The G1's command bytes and bitmap framing, as G1Protocol.java / G1BluetoothModule.java built them. */
class G1ProtocolTest {
    private fun b(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test fun heartbeat() {
        assertArrayEquals(b(0x25, 0x06, 0x00, 0x05, 0x04, 0x05), G1Protocol.heartbeat(5))
        assertArrayEquals(b(0x25, 0x06, 0x00, 0x01, 0x04, 0x01), G1Protocol.heartbeat(257))
    }

    @Test fun textPacket() {
        val t = "Hi".toByteArray()
        assertArrayEquals(b(0x4E, 0, 1, 0, 0x71, 0, 0, 2, 3, 'H'.code, 'i'.code), G1Protocol.text(G1Protocol.STATUS_TEXT_SHOW, 2, 3, t))
        // One page: marked complete.
        assertEquals(0x41, G1Protocol.textPages("short")[0][4].toInt())
    }

    @Test fun pages() {
        assertEquals(listOf(""), G1Protocol.pages(""))
        val words = (1..60).joinToString(" ") { "word$it" }
        val pages = G1Protocol.pages(words)
        assertTrue(pages.size > 1)
        assertTrue(pages.all { p -> p.lines().size <= 5 && p.lines().all { it.length <= 40 } })
        assertEquals("x".repeat(37) + "...", G1Protocol.pages("x".repeat(50))[0])
    }

    @Test fun crc32() {
        assertEquals(0xCBF43926L, G1Protocol.crc32("123456789".toByteArray()))
    }

    @Test fun commands() {
        assertArrayEquals(b(0x0E, 1), G1Protocol.microphone(true))
        assertArrayEquals(b(0x0E, 0), G1Protocol.microphone(false))
        assertArrayEquals(b(0x18), G1Protocol.clear())
    }

    @Test fun bmpHeaderAndPixels() {
        val w = 576
        val h = 136
        val white = BooleanArray(w * h)
        white[0] = true // top-left lit
        val bmp = G1Protocol.bmp(white, w, h)
        assertEquals(62 + 72 * 136, bmp.size)
        assertEquals('B'.code, bmp[0].toInt())
        assertEquals('M'.code, bmp[1].toInt())
        assertEquals(bmp.size, (bmp[2].toInt() and 0xFF) or ((bmp[3].toInt() and 0xFF) shl 8))
        assertEquals(62, bmp[10].toInt())
        assertEquals(576, (bmp[18].toInt() and 0xFF) or ((bmp[19].toInt() and 0xFF) shl 8))
        assertEquals(136, bmp[22].toInt() and 0xFF)
        assertEquals(1, bmp[28].toInt())
        // Rows bottom-up: the top row is the last one, its first pixel the high bit.
        assertEquals(0x80, bmp[62 + 135 * 72].toInt() and 0xFF)
        assertEquals(0, bmp[62].toInt())
        val inv = G1Protocol.invertPixels(bmp)
        assertArrayEquals(bmp.copyOfRange(0, 62), inv.copyOfRange(0, 62))
        assertEquals(0x7F, inv[62 + 135 * 72].toInt() and 0xFF)
        assertEquals(0xFF, inv[62].toInt() and 0xFF)
    }

    @Test fun imagePackets() {
        val bmp = ByteArray(62 + 72 * 136) { it.toByte() }
        val packets = G1Protocol.imagePackets(bmp)
        // 9854 bytes in 194-byte chunks: 51, then end, then CRC.
        assertEquals(51 + 2, packets.size)
        assertArrayEquals(b(0x15, 0x00, 0x00, 0x1C, 0x00, 0x00), packets[0].copyOfRange(0, 6))
        assertEquals(6 + 194, packets[0].size)
        assertArrayEquals(b(0x15, 0x01), packets[1].copyOfRange(0, 2))
        assertEquals(2 + (9854 - 50 * 194), packets[50].size)
        assertArrayEquals(b(0x20, 0x0D, 0x0E), packets[51])
        val crc = G1Protocol.crc32(b(0x00, 0x1C, 0x00, 0x00) + bmp)
        assertArrayEquals(b(0x16, crc.toInt() and 0xFF, (crc shr 8).toInt() and 0xFF, (crc shr 16).toInt() and 0xFF, (crc shr 24).toInt() and 0xFF), packets[52])
    }

    @Test fun events() {
        assertEquals(GlassesEvent.Input(GlassesInput.CLICK), G1Protocol.event(b(0x00)))
        assertEquals(GlassesEvent.Input(GlassesInput.DOUBLE_CLICK), G1Protocol.event(b(0x01)))
        assertEquals(GlassesEvent.Worn(true), G1Protocol.event(b(0x06)))
        assertEquals(GlassesEvent.Worn(false), G1Protocol.event(b(0x07)))
        assertEquals(GlassesEvent.Battery(87, case = false), G1Protocol.event(b(0x0A, 87)))
        assertEquals(GlassesEvent.Battery(40, case = true), G1Protocol.event(b(0x0F, 40)))
        assertNull(G1Protocol.event(b(0x0A)))
        assertNull(G1Protocol.event(ByteArray(0)))
    }
}

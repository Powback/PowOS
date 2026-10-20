package dev.omalauncher.glasses

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The G2 packets, byte for byte. The expected bytes come from the community reference that drove real glasses
 * (even-g2-protocol/examples/teleprompter/teleprompter.py: build_auth_packets with time.time() = 1760000000,
 * build_display_config, build_teleprompter_init, build_content_page, build_marker, build_sync), which the user's
 * G2BluetoothModule ported - so this port must produce them too.
 */
class G2ProtocolTest {
    private fun hex(s: String) = G2Protocol.hex(s)

    private fun hexOf(b: ByteArray) = b.joinToString("") { "%02X".format(it) }

    @Test fun crcIsCcittFalse() {
        // CRC-16/CCITT-FALSE's check value (init 0xFFFF, poly 0x1021, no reflection).
        assertEquals(0x29B1, G2Protocol.crc16("123456789".toByteArray()))
    }

    @Test fun varints() {
        assertEquals("00", hexOf(G2Protocol.varint(0)))
        assertEquals("7F", hexOf(G2Protocol.varint(127)))
        assertEquals("AC02", hexOf(G2Protocol.varint(300)))
        assertEquals("80F09DC706", hexOf(G2Protocol.varint(1_760_000_000)))
        assertEquals(1_760_000_000 to 5, G2Protocol.readVarint(hex("80F09DC706"), 0))
        assertEquals(300 to 3, G2Protocol.readVarint(hex("00AC02"), 1))
        assertNull(G2Protocol.readVarint(hex("AC"), 0))
    }

    @Test fun authPacketsMatchTheReference() {
        val expected =
            listOf(
                "AA21010C010180000804100C1A0408011004C6BC",
                "AA21020A010180200805100E22020802C29E",
                "AA21031B01018020088001100F8208110880F09DC70610E8FFFFFFFFFFFFFFFF01F340",
                "AA21040C01018000080410101A0408011004D6D9",
                "AA21050C01018000080410111A0408011004B761",
                "AA21060A010180200805101222020801D021",
                "AA21071B0101802008800110138208110880F09DC70610E8FFFFFFFFFFFFFFFF01F366",
            )
        assertEquals(expected, G2Protocol.authPackets(1_760_000_000).map(::hexOf))
    }

    @Test fun teleprompterPackets() {
        assertEquals(
            "AA21087201010E2008021014226A08011213080210904E1D00E0944425000000002800300012130803100D0F1D00408D442500000000280030001212080410001D000088422500000000280030001212080510001D00009242250000A242280030001212080610001D0000C642250000C44228003000180032D1",
            hexOf(G2Protocol.displayConfig(8, 0x14)),
        )
        assertEquals("AA21092101010620080110151A1908011215080110001800208B02283930E601388E0A40054800F1FB", hexOf(G2Protocol.teleprompterInit(9, 0x15, 3, manual = true)))
        assertEquals("AA21092201010620080110151A1A08011216080110001800208B0228E91430E601388E0A40054801D6D3", hexOf(G2Protocol.teleprompterInit(9, 0x15, 140, manual = false)))
        assertEquals("AA210A1A01010620080310162A120800100A1A0C0A48656C6C6F2047320A200AD78E", hexOf(G2Protocol.contentPage(10, 0x16, 0, "Hello G2\n \n")))
        assertEquals("AA21140D0101062008FF0110206A04080010068E15", hexOf(G2Protocol.marker(20, 0x20)))
        assertEquals("AA21170801018000080E10236A002AEC", hexOf(G2Protocol.sync(23, 0x23)))
    }

    @Test fun heartbeat() {
        // build_packet(12, 0x80, 0x00, 08 04 10 varint(13)), as buildG2Heartbeat(seq, seq + 1).
        assertEquals("AA210C06010180000804100D1D0F", hexOf(G2Protocol.heartbeat(12, 13)))
    }

    @Test fun packetHeaderAndCrc() {
        val p = G2Protocol.packet(0x105, 0x0B, 0x20, G2Protocol.bytes(0x08, 0x01, 0x10, 0x07))
        assertEquals(0x05, p[2].toInt() and 0xFF) // seq wraps to a byte
        assertEquals(6, p[3].toInt()) // payload + CRC
        val crc = G2Protocol.crc16(G2Protocol.bytes(0x08, 0x01, 0x10, 0x07))
        assertEquals(crc and 0xFF, p[p.size - 2].toInt() and 0xFF)
        assertEquals(crc shr 8, p[p.size - 1].toInt() and 0xFF)
        // conversate(seq, msg, on) is exactly that packet.
        assertArrayEquals(G2Protocol.packet(5, 0x0B, 0x20, G2Protocol.bytes(0x08, 0x01, 0x10, 0x06)), G2Protocol.conversate(5, 6, on = true))
    }

    @Test fun teleprompterSequenceOrderAndNumbering() {
        val (steps, next) = G2Protocol.teleprompter("one two three", 8)
        // config, init, pages 0-9, marker, pages 10-11, sync, pages 12-13 (14 pages minimum).
        assertEquals(2 + 10 + 1 + 2 + 1 + 2, steps.size)
        assertEquals((8 + steps.size) and 0xFF, next)
        steps.forEachIndexed { i, s -> assertEquals((8 + i) and 0xFF, s.packet[2].toInt() and 0xFF) }
        assertEquals(0x0E, steps[0].packet[6].toInt())
        assertEquals(300L, steps[0].delayMs)
        assertEquals(500L, steps[1].delayMs)
        assertEquals(0xFF, steps[12].packet[9].toInt() and 0xFF) // the marker's type
        assertEquals(0x80, steps[15].packet[6].toInt() and 0xFF) // the sync
        // Message ids from 0x14, one per packet (after the payload's "08 tt 10"): the config's 0x14, the sync's 0x14 + 15.
        assertEquals(0x14, steps[0].packet[11].toInt())
        assertEquals(0x14 + 15, steps[15].packet[11].toInt())
    }

    @Test fun pagesAsTheModuleFormatsThem() {
        val pages = G2Protocol.pages("Hello world")
        assertEquals(14, pages.size)
        assertEquals("Hello world\n" + " \n".repeat(9) + " \n", pages[0])
        assertTrue(pages.all { it.endsWith(" \n") })
        // 25 characters a line, words kept whole.
        val long = G2Protocol.pages("aaaa bbbb cccc dddd eeee ffff gggg")
        assertEquals("aaaa bbbb cccc dddd eeee", long[0].lines()[0])
        assertEquals("ffff gggg", long[0].lines()[1])
        // 25 lines -> 3 pages of 10, padded to 14.
        val many = G2Protocol.pages((1..25).joinToString("\n") { "line $it" })
        assertEquals("line 11", many[1].lines()[0])
        assertEquals(14, many.size)
        // The escaped newline the module accepted.
        assertEquals("a", G2Protocol.pages("a\\nb")[0].lines()[0])
        assertEquals("b", G2Protocol.pages("a\\nb")[0].lines()[1])
    }

    @Test fun parsesResponses() {
        val raw = G2Protocol.packet(3, 0x0B, 0x20, G2Protocol.bytes(0x08, 0x03)).also { it[1] = 0x12 }
        val p = G2Protocol.parse(raw)!!
        assertEquals(0x12, p.type)
        assertEquals(3, p.seq)
        assertEquals(0x0B, p.svcHi)
        assertTrue(G2Protocol.isConversate(p))
        assertArrayEquals(G2Protocol.bytes(0x08, 0x03), p.payload)
        assertNull(G2Protocol.parse(G2Protocol.bytes(0x55, 0, 0, 0, 0, 0, 0, 0)))
        assertNull(G2Protocol.parse(G2Protocol.bytes(0xAA, 0x12)))
    }

    @Test fun inputEvents() {
        assertEquals(G2Protocol.EVT_CLICK, G2Protocol.inputEvent(ByteArray(0)))
        assertEquals(G2Protocol.EVT_DOUBLE_CLICK, G2Protocol.inputEvent(G2Protocol.bytes(0x08, 0x03)))
        assertEquals(G2Protocol.EVT_SCROLL_BOTTOM, G2Protocol.inputEvent(G2Protocol.bytes(0x08, 0x02, 0x10, 0x01)))
        assertNull(G2Protocol.inputEvent(G2Protocol.bytes(0x08, 0x09)))
        assertNull(G2Protocol.inputEvent(G2Protocol.bytes(0x12, 0x00)))
        assertEquals(GlassesInput.SCROLL_UP, GlassesInput.ofG2(G2Protocol.EVT_SCROLL_TOP))
    }

    @Test fun audioAndTranscripts() {
        // 2 frames of audio whose first byte isn't a protobuf tag.
        val audio = ByteArray(80) { 0x07 }.also { it[0] = 0x00 }
        assertTrue(G2Protocol.looksLikeAudio(audio))
        assertFalse(G2Protocol.looksLikeAudio(ByteArray(41)))
        // field 7 { 1: "hi there", 2: true }
        val text = "hi there".toByteArray()
        val inner = G2Protocol.concat(G2Protocol.bytes(0x0A, text.size), text, G2Protocol.bytes(0x10, 0x01))
        val payload = G2Protocol.concat(G2Protocol.bytes(0x08, 0x05), G2Protocol.bytes(0x3A, inner.size), inner)
        assertFalse(G2Protocol.looksLikeAudio(payload))
        assertEquals("hi there" to true, G2Protocol.transcript(payload))
        assertNull(G2Protocol.transcript(G2Protocol.bytes(0x08, 0x01)))
    }

    @Test fun renderFragments() {
        val data = ByteArray(1100) { it.toByte() }
        val f = G2Protocol.renderFragments(data)
        assertEquals(3, f.size)
        assertArrayEquals(G2Protocol.bytes(0x15, 0x00, 0x00, 0x1C, 0x00, 0x00), f[0].copyOfRange(0, 6))
        assertEquals(6 + 503, f[0].size)
        assertArrayEquals(G2Protocol.bytes(0x15, 0x01), f[1].copyOfRange(0, 2))
        assertEquals(2 + 1100 - 2 * 503, f[2].size)
    }

    @Test fun names() {
        assertEquals(GlassesName(GlassesModel.G2, "G2_84", GlassesSide.LEFT), GlassesName.parse("Even G2_84_L_8AF0B1"))
        assertEquals(GlassesName(GlassesModel.G1, "G1_12", GlassesSide.RIGHT), GlassesName.parse("G1_12_R_A014F8"))
        assertNull(GlassesName.parse("Even R1_123456"))
        assertNull(GlassesName.parse("Pixel Buds"))
        val any = Regex(GlassesName.pattern())
        assertTrue(any.matches("Even G2_84_L_8AF0B1"))
        assertTrue(any.matches("G1_12_R_A014F8"))
        assertFalse(any.matches("Even R1_123456"))
        val right = java.util.regex.Pattern.compile(GlassesName.pattern("G2_84", GlassesSide.RIGHT))
        assertTrue(right.matcher("Even G2_84_R_8AF0B2").matches())
        assertFalse(right.matcher("Even G2_84_L_8AF0B1").matches())
        assertFalse(right.matcher("Even G2_85_R_8AF0B2").matches())
    }
}

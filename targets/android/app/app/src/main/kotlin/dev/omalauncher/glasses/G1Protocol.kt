package dev.omalauncher.glasses

import java.util.UUID
import java.util.zip.CRC32

/**
 * The Even Realities G1's BLE protocol: two Nordic UART connections (left and right arm), raw command bytes. Pure
 * bytes, JVM-tested (G1ProtocolTest). Ported from the user's bluetooth/protocol/G1Protocol.java and
 * bluetooth/g1/G1BluetoothModule.java (itself after Even's EvenDemoApp and MentraOS/AugmentOS): text 0x4E, the
 * 576x136 1-bit BMP sent as 0x15 fragments + 0x20 end + 0x16 CRC32, heartbeat 0x25 every 8 s, touch/wear events 0xF5,
 * microphone 0x0E (right arm) with LC3 audio 0xF1 (not decoded here).
 */
object G1Protocol {
    val NUS_SERVICE: UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    /** Write commands here. */
    val NUS_RX: UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    /** Data and events, notified. */
    val NUS_TX: UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")

    const val CMD_BRIGHTNESS = 0x01
    const val CMD_MICROPHONE = 0x0E
    const val CMD_IMAGE_DATA = 0x15
    const val CMD_IMAGE_CRC = 0x16
    /** Exit the current feature: clears the display. */
    const val CMD_EXIT = 0x18
    const val CMD_IMAGE_END = 0x20
    const val CMD_HEARTBEAT = 0x25
    const val CMD_BATTERY = 0x2C
    const val CMD_TEXT = 0x4E
    const val CMD_MIC_DATA = 0xF1
    const val CMD_EVENT = 0xF5

    const val WIDTH = 576
    const val HEIGHT = 136
    const val IMAGE_CHUNK = 194
    const val IMAGE_ADDRESS = 0x00001C00
    const val BMP_HEADER = 62
    const val HEARTBEAT_MS = 8_000L
    const val IMAGE_PACKET_DELAY_MS = 50L

    /** Screen status for a page in the middle (NEW_CONTENT | TEXT_SHOW) and for the last one (NEW_CONTENT | AI_COMPLETE). */
    const val STATUS_TEXT_SHOW = 0x71
    const val STATUS_AI_COMPLETE = 0x41
    const val CHARS_PER_LINE = 40
    const val LINES_PER_SCREEN = 5

    fun heartbeat(seq: Int): ByteArray {
        val s = (seq and 0xFF).toByte()
        return byteArrayOf(CMD_HEARTBEAT.toByte(), 0x06, 0x00, s, 0x04, s)
    }

    /** A text page: [0x4E, seq 0, 1 packet, packet 0, status, char pos 0 0, page (1-based), pages, text...]. */
    fun text(
        status: Int,
        page: Int,
        pages: Int,
        text: ByteArray,
    ): ByteArray {
        val c = ByteArray(9 + text.size)
        c[0] = CMD_TEXT.toByte()
        c[1] = 0
        c[2] = 1
        c[3] = 0
        c[4] = status.toByte()
        c[5] = 0
        c[6] = 0
        c[7] = page.toByte()
        c[8] = pages.toByte()
        System.arraycopy(text, 0, c, 9, text.size)
        return c
    }

    /** The text packets for [text]: paged ([pages]), the last page marked complete. */
    fun textPages(text: String): List<ByteArray> {
        val pages = pages(text)
        return pages.mapIndexed { i, p ->
            text(if (i == pages.size - 1) STATUS_AI_COMPLETE else STATUS_TEXT_SHOW, i + 1, pages.size, p.toByteArray(Charsets.UTF_8))
        }
    }

    /** [text] in pages of 5 lines of 40 characters, words wrapped, a too-long word cut with "...". */
    fun pages(text: String): List<String> {
        val pages = ArrayList<String>()
        var page = StringBuilder()
        var line = StringBuilder()
        var lines = 0
        for (word in text.split(" ")) {
            val test = if (line.isEmpty()) word else "$line $word"
            if (test.length > CHARS_PER_LINE) {
                if (line.isNotEmpty()) {
                    page.append(line).append('\n')
                    lines++
                    if (lines >= LINES_PER_SCREEN) {
                        pages += page.toString().trim()
                        page = StringBuilder()
                        lines = 0
                    }
                    line = StringBuilder(word)
                } else {
                    line = StringBuilder(word.substring(0, minOf(word.length, CHARS_PER_LINE - 3)) + "...")
                }
            } else {
                line = StringBuilder(test)
            }
        }
        if (line.isNotEmpty()) page.append(line)
        if (page.isNotEmpty()) pages += page.toString().trim()
        return pages.ifEmpty { listOf("") }
    }

    fun microphone(on: Boolean) = byteArrayOf(CMD_MICROPHONE.toByte(), if (on) 1 else 0)

    fun clear() = byteArrayOf(CMD_EXIT.toByte())

    fun crc32(data: ByteArray): Long = CRC32().apply { update(data) }.value

    /**
     * A 1-bit BMP of [white] (row-major, top row first, true = lit) - packTo1BitBmp: 62-byte header (file, DIB, a
     * black/white palette), rows bottom-up, padded to 4 bytes, 1 = white.
     */
    fun bmp(
        white: BooleanArray,
        width: Int,
        height: Int,
    ): ByteArray {
        val rowBytes = (width + 31) / 32 * 4
        val pixels = rowBytes * height
        val size = BMP_HEADER + pixels
        val b = ByteArray(size)
        fun le32(
            at: Int,
            v: Int,
        ) {
            b[at] = v.toByte()
            b[at + 1] = (v shr 8).toByte()
            b[at + 2] = (v shr 16).toByte()
            b[at + 3] = (v shr 24).toByte()
        }
        b[0] = 'B'.code.toByte()
        b[1] = 'M'.code.toByte()
        le32(2, size)
        le32(10, BMP_HEADER)
        le32(14, 40)
        le32(18, width)
        le32(22, height)
        b[26] = 1 // planes
        b[28] = 1 // bits per pixel
        le32(34, pixels)
        b[38] = 0x13
        b[39] = 0x0B
        b[42] = 0x13
        b[43] = 0x0B
        b[46] = 2 // palette colors
        // Palette: black, white.
        b[58] = 0xFF.toByte()
        b[59] = 0xFF.toByte()
        b[60] = 0xFF.toByte()
        for (y in 0 until height) {
            val src = height - 1 - y
            val row = BMP_HEADER + y * rowBytes
            for (x in 0 until width) {
                if (white[src * width + x]) {
                    val i = row + x / 8
                    b[i] = (b[i].toInt() or (1 shl (7 - x % 8))).toByte()
                }
            }
        }
        return b
    }

    /** Every pixel byte after the header inverted - what the G1 wants (as MentraOS does). */
    fun invertPixels(bmp: ByteArray): ByteArray {
        if (bmp.size <= BMP_HEADER) return bmp
        val out = bmp.copyOf()
        for (i in BMP_HEADER until out.size) out[i] = out[i].toInt().inv().toByte()
        return out
    }

    /**
     * The packets that send [bmp] (already inverted) to both arms (sendG1Bitmap): 0x15 fragments of 194 bytes (the
     * first with the 4-byte little-endian display address), the end 0x20 0D 0E, then 0x16 with the CRC32 of address +
     * image, little-endian. Each goes 50 ms after the one before.
     */
    fun imagePackets(
        bmp: ByteArray,
        address: Int = IMAGE_ADDRESS,
    ): List<ByteArray> {
        val addr = byteArrayOf(address.toByte(), (address shr 8).toByte(), (address shr 16).toByte(), (address shr 24).toByte())
        val out = ArrayList<ByteArray>()
        var i = 0
        var index = 0
        while (i < bmp.size) {
            val chunk = bmp.copyOfRange(i, minOf(i + IMAGE_CHUNK, bmp.size))
            out +=
                if (index == 0) {
                    byteArrayOf(CMD_IMAGE_DATA.toByte(), 0) + addr + chunk
                } else {
                    byteArrayOf(CMD_IMAGE_DATA.toByte(), (index and 0xFF).toByte()) + chunk
                }
            i += IMAGE_CHUNK
            index++
        }
        out += byteArrayOf(CMD_IMAGE_END.toByte(), 0x0D, 0x0E)
        val crc = crc32(addr + bmp)
        out += byteArrayOf(CMD_IMAGE_CRC.toByte(), crc.toByte(), (crc shr 8).toByte(), (crc shr 16).toByte(), (crc shr 24).toByte())
        return out
    }

    /**
     * A device event (0xF5 + payload). The firmware reuses 0x00-0x06 for touch and for state; read here as the module's
     * primary meaning: 0 tap, 1 double tap, 2 head up, 3 head down, 4/5 silent mode, 6 worn, 7 not worn, ...
     */
    fun event(payload: ByteArray): GlassesEvent? {
        if (payload.isEmpty()) return null
        val level = if (payload.size >= 2) payload[1].toInt() and 0xFF else -1
        return when (payload[0].toInt() and 0xFF) {
            0x00 -> GlassesEvent.Input(GlassesInput.CLICK)
            0x01 -> GlassesEvent.Input(GlassesInput.DOUBLE_CLICK)
            0x02 -> GlassesEvent.Input(GlassesInput.HEAD_UP)
            0x03 -> GlassesEvent.Input(GlassesInput.HEAD_DOWN)
            0x06 -> GlassesEvent.Worn(true)
            0x07 -> GlassesEvent.Worn(false)
            0x0A -> if (level >= 0) GlassesEvent.Battery(level, case = false) else null
            0x0F -> if (level >= 0) GlassesEvent.Battery(level, case = true) else null
            0x1E -> GlassesEvent.Input(GlassesInput.DASHBOARD_SHOW)
            0x1F -> GlassesEvent.Input(GlassesInput.DASHBOARD_CLOSE)
            else -> null
        }
    }
}

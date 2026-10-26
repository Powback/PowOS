package dev.omalauncher.glasses

import java.io.ByteArrayOutputStream
import java.util.UUID

/**
 * The Even Realities G2's BLE protocol: packet building and parsing, nothing that talks to Android - so every byte
 * here is checked by JVM tests (G2ProtocolTest).
 *
 * Ported from the user's hardware-tested BLE work (android-app-dev, webview-bridge-gradle:
 * bluetooth/g2/G2BluetoothModule.java and bluetooth/protocol/G2Protocol.java) - the same bytes, in the same order,
 * with the same delays. What was verified on real glasses there: connect, the 7-packet auth (g2-auth-complete.png), the
 * heartbeat that keeps the link up after it. The teleprompter text sequence is the one the community reference
 * (even-g2-protocol, teleprompter.py) confirmed on hardware. Everything else is marked: [Unverified] parts are guesses
 * from reverse engineering, used only behind a flag (docs/GLASSES.md "What's verified").
 *
 * Packet: [AA][type][seq][len][pkt_total][pkt_serial][svc_hi][svc_lo][protobuf payload][crc_lo][crc_hi], len = payload
 * + 2 (the CRC), CRC-16/CCITT (init 0xFFFF, poly 0x1021) over the payload only, little-endian.
 */
object G2Protocol {
    val SERVICE: UUID = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e5450")
    /** Phone -> glasses commands (write without response). */
    val WRITE: UUID = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e5401")
    /** Glasses -> phone responses and events (notify). */
    val NOTIFY: UUID = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e5402")
    /** The display rendering service (not the main one): 0x6401 write, 0x6402 notify. */
    val DISPLAY_SERVICE: UUID = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e6450")
    val DISPLAY_WRITE: UUID = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e6401")
    val DISPLAY_NOTIFY: UUID = UUID.fromString("00002760-08c2-11e1-9073-0e8ac72e6402")
    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    const val MAGIC = 0xAA
    const val TYPE_COMMAND = 0x21
    const val TYPE_RESPONSE = 0x12

    // Service ids (high byte; the low byte is 0x20 for data, 0x00 for control).
    const val SVC_AUTH = 0x80
    const val SVC_SYNC_INFO = 0x01
    const val SVC_NOTIFICATION = 0x02
    const val SVC_MODULE_CONFIG = 0x03
    const val SVC_DISPLAY_WAKE = 0x04
    const val SVC_TELEPROMPTER = 0x06
    const val SVC_DASHBOARD = 0x07
    const val SVC_NAVIGATION = 0x08
    const val SVC_DEVICE_INFO = 0x09
    const val SVC_MENU = 0x0A
    const val SVC_CONVERSATE = 0x0B
    const val SVC_QUICKLIST = 0x0C
    const val SVC_DEV_CFG = 0x0D
    const val SVC_DISPLAY_CONFIG = 0x0E
    const val SVC_G2_SETTING = 0x10
    const val SVC_CONVERSATE2 = 0x11
    const val SVC_TRANSLATE = 0x12
    const val SVC_EVEN_AI = 0x13
    const val SVC_GLASSES_CASE = 0x15
    const val SVC_RING = 0x16
    const val SVC_HEALTH = 0x17
    const val SVC_DATA_LO = 0x20
    const val SVC_CTRL_LO = 0x00

    /**
     * Services whose packets the module routed to their own (raw) events - everything else of type 0x12 outside auth
     * was tried as an input event (tryDecodeG2InputEvent). Kept as the module had it: an input event is recognised
     * by *not* being one of these.
     */
    val KNOWN_SERVICES =
        setOf(
            SVC_NAVIGATION, SVC_MENU, SVC_G2_SETTING, SVC_SYNC_INFO, SVC_MODULE_CONFIG, SVC_NOTIFICATION, SVC_TELEPROMPTER,
            SVC_DASHBOARD, SVC_DEVICE_INFO, SVC_QUICKLIST, SVC_DEV_CFG, SVC_TRANSLATE, SVC_EVEN_AI, SVC_GLASSES_CASE,
            SVC_RING, SVC_HEALTH,
        )

    /** The display: 576x288, 4-bit greyscale (16 shades of green). */
    const val CANVAS_WIDTH = 576
    const val CANVAS_HEIGHT = 288

    /** Image fragments on 0x6401 at MTU 512 (G2Protocol.RENDER_FRAGMENT_SIZE). [Unverified] framing. */
    const val RENDER_FRAGMENT_SIZE = 503

    /** The auth packets' transaction id (from reverse engineering; meaning unknown). */
    val TRANSACTION_ID = byteArrayOf(0xE8.toByte(), -1, -1, -1, -1, -1, -1, -1, -1, 0x01)

    const val AUTH_PACKET_DELAY_MS = 100L
    const val POST_AUTH_DELAY_MS = 500L
    /** Auth used seqs 1-7: the session's own start at 8. */
    const val FIRST_SEQ = 8
    /** The glasses drop the link ~1.5 s after auth without traffic: the first heartbeat goes this soon. */
    const val FIRST_HEARTBEAT_MS = 500L
    const val HEARTBEAT_MS = 15_000L

    // Input events (the Even Hub SDK's OsEventTypeList), field 1 of the event's protobuf; proto3 omits 0 (a click).
    const val EVT_CLICK = 0
    const val EVT_SCROLL_TOP = 1
    const val EVT_SCROLL_BOTTOM = 2
    const val EVT_DOUBLE_CLICK = 3
    const val EVT_FG_ENTER = 4
    const val EVT_FG_EXIT = 5
    const val EVT_ABNORMAL_EXIT = 6
    const val SCROLL_THROTTLE_MS = 300L

    /**
     * The microphone's frames on Conversate (0x0B-20 / 0x11-20): the module's 40 bytes per 10 ms frame, labelled
     * "PCM S16LE 16 kHz mono". [Unverified]: 10 ms of that PCM would be 320 bytes - 40 bytes per 10 ms is LC3's
     * 32 kbit/s. Kept as the module had it; docs/GLASSES.md lists it as open.
     */
    const val AUDIO_FRAME_BYTES = 40

    /** Display configuration blob for service 0x0E-20 (from Even Realities' reference). */
    private const val DISPLAY_CONFIG_HEX =
        "0801121308021090" + "4E1D00E094442500" + "000000280030001213" +
            "0803100D0F1D0040" + "8D44250000000028" + "0030001212080410" +
            "001D0000884225" + "00000000280030" + "001212080510001D" +
            "00009242250000" + "A242280030001212" + "080610001D0000C6" +
            "42250000C4422800" + "30001800"

    /** CRC-16/CCITT: init 0xFFFF, polynomial 0x1021, over [data]. */
    fun crc16(data: ByteArray): Int {
        var crc = 0xFFFF
        for (b in data) {
            crc = crc xor ((b.toInt() and 0xFF) shl 8)
            repeat(8) {
                crc = if (crc and 0x8000 != 0) (crc shl 1) xor 0x1021 else crc shl 1
                crc = crc and 0xFFFF
            }
        }
        return crc
    }

    /** A protobuf varint. */
    fun varint(value: Int): ByteArray {
        val out = ByteArrayOutputStream()
        var v = value
        while (v ushr 7 != 0) {
            out.write((v and 0x7F) or 0x80)
            v = v ushr 7
        }
        out.write(v and 0x7F)
        return out.toByteArray()
    }

    /** The varint at [offset] of [data]: (value, offset after it), or null if it's truncated or too long. */
    fun readVarint(
        data: ByteArray,
        offset: Int,
    ): Pair<Int, Int>? {
        var value = 0
        var shift = 0
        var i = offset
        while (i < data.size) {
            val b = data[i++].toInt() and 0xFF
            value = value or ((b and 0x7F) shl shift)
            if (b and 0x80 == 0) return value to i
            shift += 7
            if (shift >= 35) return null
        }
        return null
    }

    fun concat(vararg parts: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        for (p in parts) out.write(p)
        return out.toByteArray()
    }

    fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    fun hex(s: String) = ByteArray(s.length / 2) { ((Character.digit(s[it * 2], 16) shl 4) + Character.digit(s[it * 2 + 1], 16)).toByte() }

    /** A whole command packet: header, [payload], CRC. */
    fun packet(
        seq: Int,
        svcHi: Int,
        svcLo: Int,
        payload: ByteArray,
    ): ByteArray {
        val crc = crc16(payload)
        val p = ByteArray(8 + payload.size + 2)
        p[0] = MAGIC.toByte()
        p[1] = TYPE_COMMAND.toByte()
        p[2] = (seq and 0xFF).toByte()
        p[3] = (payload.size + 2).toByte()
        p[4] = 0x01 // packets in the message
        p[5] = 0x01 // this packet's serial
        p[6] = svcHi.toByte()
        p[7] = svcLo.toByte()
        System.arraycopy(payload, 0, p, 8, payload.size)
        p[p.size - 2] = (crc and 0xFF).toByte()
        p[p.size - 1] = ((crc shr 8) and 0xFF).toByte()
        return p
    }

    /** [packet] with the CRC of its payload (everything after the 8-byte header) appended. */
    fun withCrc(packet: ByteArray): ByteArray {
        val crc = crc16(packet.copyOfRange(8, packet.size))
        return concat(packet, bytes(crc and 0xFF, (crc shr 8) and 0xFF))
    }

    /**
     * The 7 auth packets (sendG2AuthHandshake, after teleprompter.py's build_auth_packets), sent 100 ms apart right
     * after service discovery; [now] is the Unix time in seconds, in packets 3 and 7.
     */
    fun authPackets(now: Int): List<ByteArray> {
        val ts = varint(now)
        fun timeSync(
            seq: Int,
            type: Int,
        ): ByteArray {
            val payload = concat(bytes(0x08, 0x80, 0x01, 0x10, type, 0x82, 0x08, 0x11, 0x08), ts, bytes(0x10), TRANSACTION_ID)
            return withCrc(concat(bytes(0xAA, 0x21, seq, payload.size + 2, 0x01, 0x01, 0x80, 0x20), payload))
        }
        return listOf(
            // 1: capability query (0x80-00)
            withCrc(bytes(0xAA, 0x21, 0x01, 0x0C, 0x01, 0x01, 0x80, 0x00, 0x08, 0x04, 0x10, 0x0C, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04)),
            // 2: capability response request (0x80-20)
            withCrc(bytes(0xAA, 0x21, 0x02, 0x0A, 0x01, 0x01, 0x80, 0x20, 0x08, 0x05, 0x10, 0x0E, 0x22, 0x02, 0x08, 0x02)),
            // 3: time sync + transaction id
            timeSync(0x03, 0x0F),
            // 4, 5: capability exchange
            withCrc(bytes(0xAA, 0x21, 0x04, 0x0C, 0x01, 0x01, 0x80, 0x00, 0x08, 0x04, 0x10, 0x10, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04)),
            withCrc(bytes(0xAA, 0x21, 0x05, 0x0C, 0x01, 0x01, 0x80, 0x00, 0x08, 0x04, 0x10, 0x11, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04)),
            // 6: final capability
            withCrc(bytes(0xAA, 0x21, 0x06, 0x0A, 0x01, 0x01, 0x80, 0x20, 0x08, 0x05, 0x10, 0x12, 0x22, 0x02, 0x08, 0x01)),
            // 7: final time sync + transaction id
            timeSync(0x07, 0x13),
        )
    }

    /** Keep-alive (auth service 0x80-00, type 4). */
    fun heartbeat(
        seq: Int,
        msgId: Int,
    ) = packet(seq, SVC_AUTH, SVC_CTRL_LO, concat(bytes(0x08, 0x04, 0x10), varint(msgId)))

    /** Display configuration (0x0E-20): sent before the teleprompter's init. */
    fun displayConfig(
        seq: Int,
        msgId: Int,
    ) = packet(seq, SVC_DISPLAY_CONFIG, SVC_DATA_LO, concat(bytes(0x08, 0x02, 0x10), varint(msgId), bytes(0x22, 0x6A), hex(DISPLAY_CONFIG_HEX)))

    /** Teleprompter init (0x06-20, type 1): content height scaled from [totalLines]; [manual]: the wearer scrolls. */
    fun teleprompterInit(
        seq: Int,
        msgId: Int,
        totalLines: Int,
        manual: Boolean,
    ): ByteArray {
        // Reference: 140 lines -> content height 2665.
        val contentHeight = maxOf(1, totalLines * 2665 / 140)
        val display =
            concat(
                bytes(0x08, 0x01, 0x10, 0x00, 0x18, 0x00, 0x20, 0x8B, 0x02),
                bytes(0x28), varint(contentHeight),
                bytes(0x30, 0xE6, 0x01), // line height 230
                bytes(0x38, 0x8E, 0x0A), // viewport 1294
                bytes(0x40, 0x05, 0x48, if (manual) 0x00 else 0x01), // font size, mode
            )
        val settings = concat(bytes(0x08, 0x01, 0x12, display.size), display)
        return packet(seq, SVC_TELEPROMPTER, SVC_DATA_LO, concat(bytes(0x08, 0x01, 0x10), varint(msgId), bytes(0x1A, settings.size), settings))
    }

    /** A content page (0x06-20, type 3): up to 10 lines; the text goes with a leading newline. */
    fun contentPage(
        seq: Int,
        msgId: Int,
        page: Int,
        text: String,
    ): ByteArray {
        val t = ("\n" + text).toByteArray(Charsets.UTF_8)
        val inner = concat(bytes(0x08), varint(page), bytes(0x10, 0x0A), bytes(0x1A), varint(t.size), t)
        return packet(seq, SVC_TELEPROMPTER, SVC_DATA_LO, concat(bytes(0x08, 0x03, 0x10), varint(msgId), bytes(0x2A), varint(inner.size), inner))
    }

    /** The mid-stream marker (0x06-20, type 255), after the first 10 pages. */
    fun marker(
        seq: Int,
        msgId: Int,
    ) = packet(seq, SVC_TELEPROMPTER, SVC_DATA_LO, concat(bytes(0x08, 0xFF, 0x01, 0x10), varint(msgId), bytes(0x6A, 0x04, 0x08, 0x00, 0x10, 0x06)))

    /** The sync trigger (0x80-00, type 14): renders, after pages 10-11. */
    fun sync(
        seq: Int,
        msgId: Int,
    ) = packet(seq, SVC_AUTH, SVC_CTRL_LO, concat(bytes(0x08, 0x0E, 0x10), varint(msgId), bytes(0x6A, 0x00)))

    /**
     * [text] word-wrapped to [charsPerLine] in pages of [linesPerPage] lines, each ending " \n", at least 14 pages
     * (the reference's minimum for reliable rendering) - g2FormatTextToPages, as it was.
     */
    fun pages(
        text: String,
        charsPerLine: Int = 25,
        linesPerPage: Int = 10,
    ): List<String> {
        val src = text.replace("\\n", "\n")
        val wrapped = ArrayList<String>()
        for (line in src.split("\n")) {
            if (line.trim().isEmpty()) {
                wrapped += ""
                continue
            }
            var current = StringBuilder()
            // Java's String.split drops trailing empty strings; Kotlin's keeps them.
            for (word in line.split(Regex("\\s+")).dropLastWhile { it.isEmpty() }) {
                if (current.length + word.length + 1 > charsPerLine && current.isNotEmpty()) {
                    wrapped += current.toString().trim()
                    current = StringBuilder()
                }
                current.append(word).append(' ')
            }
            if (current.toString().trim().isNotEmpty()) wrapped += current.toString().trim()
        }
        if (wrapped.isEmpty()) wrapped += src
        while (wrapped.size < linesPerPage) wrapped += " "
        val pages = ArrayList<String>()
        var i = 0
        while (i < wrapped.size) {
            val lines = ArrayList(wrapped.subList(i, minOf(i + linesPerPage, wrapped.size)))
            while (lines.size < linesPerPage) lines += " "
            pages += lines.joinToString("") { "$it\n" } + " \n"
            i += linesPerPage
        }
        while (pages.size < 14) pages += " \n".repeat(linesPerPage) + " \n"
        return pages
    }

    /** One step of a sequence: a packet, then this long before the next. */
    class Step(
        val packet: ByteArray,
        val delayMs: Long,
    )

    /**
     * The whole teleprompter sequence for [text] from sequence number [seq] (sendG2TeleprompterSequence): display config,
     * 300 ms, init, 500 ms, pages 0-9 (100 ms each), marker, pages 10-11, sync, the rest. Message ids from 0x14, as the
     * reference. Returns the steps and the next free sequence number.
     */
    fun teleprompter(
        text: String,
        seq: Int,
        manual: Boolean = true,
    ): Pair<List<Step>, Int> {
        val pages = pages(text)
        val totalLines = text.replace("\\n", "\n").split("\n").size
        val steps = ArrayList<Step>()
        var s = seq and 0xFF
        var msg = 0x14
        fun add(
            p: ByteArray,
            delay: Long,
        ) {
            steps += Step(p, delay)
            s = (s + 1) and 0xFF
            msg++
        }
        add(displayConfig(s, msg), 300)
        add(teleprompterInit(s, msg, totalLines, manual), 500)
        for (i in 0 until minOf(10, pages.size)) add(contentPage(s, msg, i, pages[i]), 100)
        add(marker(s, msg), 100)
        for (i in 10 until minOf(12, pages.size)) add(contentPage(s, msg, i, pages[i]), 100)
        add(sync(s, msg), 100)
        for (i in 12 until pages.size) add(contentPage(s, msg, i, pages[i]), 100)
        return steps to s
    }

    /** Display wake (0x04-20) before image data. [Unverified] as part of the image path. */
    fun displayWake(
        seq: Int,
        msgId: Int,
    ): ByteArray {
        val settings = bytes(0x08, 0x01, 0x10, 0x01, 0x18, 0x05, 0x28, 0x01)
        return packet(seq, SVC_DISPLAY_WAKE, SVC_DATA_LO, concat(bytes(0x08, 0x01, 0x10), varint(msgId), bytes(0x1A, settings.size), settings))
    }

    /**
     * 4-bit greyscale pixels as fragments for 0x6401: the first [0x15 00 00 1C 00 00 ...], then [0x15 index ...].
     * [Unverified]: the module derived this from the G1's bitmap framing; the G2's real render-channel format was never
     * reverse-engineered. Only used with the "g2Raster" option on.
     */
    fun renderFragments(gray4: ByteArray): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        var offset = 0
        var index = 0
        while (offset < gray4.size) {
            val prefix = if (index == 0) bytes(0x15, 0x00, 0x00, 0x1C, 0x00, 0x00) else bytes(0x15, index and 0xFF)
            val len = minOf(RENDER_FRAGMENT_SIZE, gray4.size - offset)
            out += concat(prefix, gray4.copyOfRange(offset, offset + len))
            offset += len
            index++
        }
        return out
    }

    /** Microphone on/off (Conversate 0x0B-20, type 1 open / 0 close). */
    fun conversate(
        seq: Int,
        msgId: Int,
        on: Boolean,
    ) = packet(seq, SVC_CONVERSATE, SVC_DATA_LO, concat(bytes(0x08, if (on) 0x01 else 0x00, 0x10), varint(msgId)))

    /** A packet from the glasses: its header's fields and its payload (CRC stripped). */
    class Incoming(
        val type: Int,
        val seq: Int,
        val svcHi: Int,
        val svcLo: Int,
        val payload: ByteArray,
    )

    /** [data] from 0x5402 as a packet, or null (too short, not 0xAA). */
    fun parse(data: ByteArray): Incoming? {
        if (data.size < 8 || data[0].toInt() and 0xFF != MAGIC) return null
        val end = maxOf(8, data.size - 2)
        return Incoming(
            data[1].toInt() and 0xFF,
            data[2].toInt() and 0xFF,
            data[6].toInt() and 0xFF,
            data[7].toInt() and 0xFF,
            if (end > 8) data.copyOfRange(8, end) else ByteArray(0),
        )
    }

    fun isConversate(p: Incoming) = (p.svcHi == SVC_CONVERSATE || p.svcHi == SVC_CONVERSATE2) && p.svcLo == SVC_DATA_LO

    /**
     * An input event's type (0-6) from a response's payload (tryDecodeG2InputEvent): empty is a click (proto3 drops
     * the zero), "08 xx" is type xx; anything else isn't an input event.
     */
    fun inputEvent(payload: ByteArray): Int? {
        val type =
            when {
                payload.isEmpty() -> EVT_CLICK
                payload.size >= 2 && payload[0].toInt() and 0xFF == 0x08 -> payload[1].toInt() and 0x7F
                else -> return null
            }
        return type.takeIf { it in EVT_CLICK..EVT_ABNORMAL_EXIT }
    }

    /**
     * Whether a Conversate payload is microphone audio (handleG2AudioData's heuristic): a whole number of frames, and
     * a first byte that isn't a protobuf tag.
     */
    fun looksLikeAudio(payload: ByteArray): Boolean {
        if (payload.isEmpty()) return false
        val first = payload[0].toInt() and 0xFF
        val tag = (first and 0x07) <= 4 && first != 0
        return payload.size % AUDIO_FRAME_BYTES == 0 && !tag
    }

    /** The on-glasses transcript in a Conversate payload (field 7: text = 1, is_final = 2), or null. */
    fun transcript(payload: ByteArray): Pair<String, Boolean>? {
        var text: String? = null
        var final = false
        var i = 0
        while (i < payload.size) {
            val tag = payload[i++].toInt() and 0xFF
            val field = tag shr 3
            when (tag and 0x07) {
                0 -> i = readVarint(payload, i)?.second ?: break
                2 -> {
                    val (len, at) = readVarint(payload, i) ?: break
                    if (at + len > payload.size) break
                    val bytes = payload.copyOfRange(at, at + len)
                    i = at + len
                    if (field != 7) continue
                    var j = 0
                    while (j < bytes.size) {
                        val t = bytes[j++].toInt() and 0xFF
                        when (t and 0x07) {
                            2 -> {
                                val (l, a) = readVarint(bytes, j) ?: break
                                if (t shr 3 == 1 && a + l <= bytes.size) text = String(bytes, a, l, Charsets.UTF_8)
                                j = a + l
                            }
                            0 -> {
                                val (v, a) = readVarint(bytes, j) ?: break
                                if (t shr 3 == 2) final = v != 0
                                j = a
                            }
                            else -> break
                        }
                    }
                }
                else -> break
            }
        }
        return text?.let { it to final }
    }
}

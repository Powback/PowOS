package dev.omalauncher.glasses

import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

/** Which glasses: their display's canvas and depth. */
enum class GlassesModel(
    val width: Int,
    val height: Int,
    /** Bits per pixel: 4 (16 greys) or 1. */
    val bits: Int,
) {
    G1(G1Protocol.WIDTH, G1Protocol.HEIGHT, 1),
    G2(G2Protocol.CANVAS_WIDTH, G2Protocol.CANVAS_HEIGHT, 4),
}

enum class GlassesSide { LEFT, RIGHT }

/** Where one arm's link is. */
enum class LinkPhase { OFF, CONNECTING, DISCOVERING, AUTHENTICATING, READY }

/** The pair's state: each arm's link, and what the arms reported. */
data class GlassesState(
    val left: LinkPhase = LinkPhase.OFF,
    val right: LinkPhase = LinkPhase.OFF,
    /** Being worn: null when the glasses don't say (the G2 has no known wear event). */
    val worn: Boolean? = null,
    /** Battery 0-100 per source ("left", "right", "case"), as reported. */
    val battery: Map<String, Int> = emptyMap(),
    val mic: Boolean = false,
    /** The last thing that went wrong, for the user. */
    val error: String? = null,
) {
    /** Ready to show something: an arm through auth (G2) or with its UART up (G1). */
    val ready get() = left == LinkPhase.READY || right == LinkPhase.READY
    val connecting get() = !ready && (left != LinkPhase.OFF || right != LinkPhase.OFF)
}

/** Input from the touch bars / ring / head. */
enum class GlassesInput(
    val id: String,
) {
    CLICK("click"),
    DOUBLE_CLICK("double"),
    SCROLL_UP("up"),
    SCROLL_DOWN("down"),
    FOREGROUND_ENTER("enter"),
    FOREGROUND_EXIT("exit"),
    ABNORMAL_EXIT("abnormal"),
    HEAD_UP("headUp"),
    HEAD_DOWN("headDown"),
    DASHBOARD_SHOW("dashboardShow"),
    DASHBOARD_CLOSE("dashboardClose"),
    ;

    companion object {
        /** A G2 input event type (G2Protocol.EVT_*). */
        fun ofG2(type: Int) =
            when (type) {
                G2Protocol.EVT_CLICK -> CLICK
                G2Protocol.EVT_SCROLL_TOP -> SCROLL_UP
                G2Protocol.EVT_SCROLL_BOTTOM -> SCROLL_DOWN
                G2Protocol.EVT_DOUBLE_CLICK -> DOUBLE_CLICK
                G2Protocol.EVT_FG_ENTER -> FOREGROUND_ENTER
                G2Protocol.EVT_FG_EXIT -> FOREGROUND_EXIT
                else -> ABNORMAL_EXIT
            }
    }
}

sealed class GlassesEvent {
    data class Input(
        val input: GlassesInput,
        val side: GlassesSide? = null,
    ) : GlassesEvent()

    data class Worn(
        val worn: Boolean,
    ) : GlassesEvent()

    data class Battery(
        val level: Int,
        val case: Boolean,
        val side: GlassesSide? = null,
    ) : GlassesEvent()

    /** Microphone data: [codec] "pcm_s16le" (G2, [Unverified] format) or "lc3" (G1, not decoded). */
    class Audio(
        val data: ByteArray,
        val codec: String,
        val sampleRate: Int,
        val side: GlassesSide?,
    ) : GlassesEvent()

    /** The glasses' own speech recognition (G2 Conversate), as it hears. */
    data class Transcript(
        val text: String,
        val final: Boolean,
    ) : GlassesEvent()
}

/** A picture for the display, already in the glasses' own format at their canvas size. */
sealed class GlassesImage {
    /** Packed 4-bit greys (G2): [Raster.gray4] of a width x height picture. */
    class Gray4(
        val width: Int,
        val height: Int,
        val data: ByteArray,
    ) : GlassesImage()

    /** A 1-bit BMP (G1): [G1Protocol.bmp], not yet inverted. */
    class Bmp1(
        val bmp: ByteArray,
    ) : GlassesImage()
}

/**
 * A pair of smart glasses as PowOS uses them: a display, input, a microphone. G2Glasses and G1Glasses are the two
 * transports (ported from the user's BLE modules); the rest of PowOS only sees this.
 *
 * Every call returns at once - sends run on the device's own threads, in order; a newer text or image replaces one
 * still waiting (a display shows the latest, not a backlog).
 */
interface GlassesDevice {
    val model: GlassesModel
    val state: StateFlow<GlassesState>
    val events: SharedFlow<GlassesEvent>

    /** Connects both arms that are known (left first), and keeps reconnecting after a drop until [disconnect]. */
    fun connect()

    fun disconnect()

    /** Shows [text] (the glasses' own text rendering). False: not ready. */
    fun showText(text: String): Boolean

    /** Shows [image]. False: not ready, or this model's image path isn't usable (see [imageVerified]). */
    fun showImage(image: GlassesImage): Boolean

    /** Blank display. */
    fun clear(): Boolean

    fun setMic(on: Boolean): Boolean

    /** Whether [showImage] uses a protocol confirmed on real glasses (G1: yes; G2: no - its render channel is a guess). */
    val imageVerified: Boolean

    /** Disconnects for good: threads stopped. */
    fun close()
}

/**
 * An arm's advertised name: "Even G2_84_L_8AF0B1" / "G1_84_R_A014F8" - the model, the pair id (both arms share it)
 * and the side (the plugin's parsing, BluetoothPlugin.connect).
 */
data class GlassesName(
    val model: GlassesModel,
    /** "G2_84" */
    val pairId: String,
    val side: GlassesSide,
) {
    companion object {
        fun parse(name: String?): GlassesName? {
            if (name == null) return null
            val n = name.removePrefix("Even ")
            val parts = n.split("_")
            if (parts.size < 3) return null
            val model =
                when (parts[0]) {
                    "G1" -> GlassesModel.G1
                    "G2" -> GlassesModel.G2
                    else -> return null
                }
            val side =
                when (parts[2]) {
                    "L" -> GlassesSide.LEFT
                    "R" -> GlassesSide.RIGHT
                    else -> return null
                }
            return GlassesName(model, "${parts[0]}_${parts[1]}", side)
        }

        /** The regex the system's pairing dialog filters names with: any arm of either model, or one [side] of [pairId]. */
        fun pattern(
            pairId: String? = null,
            side: GlassesSide? = null,
        ): String {
            val pair = pairId?.let { Regex.escape(it) } ?: "G[12]_[^_]+"
            val s = when (side) {
                GlassesSide.LEFT -> "L"
                GlassesSide.RIGHT -> "R"
                null -> "[LR]"
            }
            return "(Even )?${pair}_${s}_.*"
        }
    }
}

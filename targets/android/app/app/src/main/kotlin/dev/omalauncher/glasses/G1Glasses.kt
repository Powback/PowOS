package dev.omalauncher.glasses

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * Even Realities G1 over BLE (G1BluetoothModule.java, ported): a Nordic UART link per arm, standard BLE pairing (the
 * system's dialog on first connect), a heartbeat to both arms every 8 s, text (0x4E) and 1-bit bitmaps to both, the
 * microphone on the right arm (LC3, passed on undecoded), touch / head / wear / battery events (0xF5, 0x2C).
 *
 * Arms connect one after the other (the left first, the right once the left is set up): two at once raise two pairing
 * dialogs and Android dismisses the second. A dropped arm reconnects with Android's background connect.
 */
class G1Glasses(
    private val context: Context,
    private val leftAddress: String?,
    private val rightAddress: String?,
) : GlassesDevice {
    override val model = GlassesModel.G1
    override val state = MutableStateFlow(GlassesState())
    override val events = MutableSharedFlow<GlassesEvent>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    override val imageVerified = true

    private val thread = HandlerThread("powos-glasses-g1").apply { start() }
    private val handler = Handler(thread.looper)
    private val tx = Executors.newSingleThreadExecutor { Thread(it, "powos-glasses-g1-tx") }
    private val pending = AtomicReference<(() -> Unit)?>(null)

    @Volatile private var wanted = false

    @Volatile private var mic = false
    private var heartbeatSeq = 0

    @Volatile private var heartbeatPaused = false

    private inner class Arm(
        side: GlassesSide,
        address: String,
    ) : BleArm.Listener {
        val link = BleArm(context, address, side, handler, this)
        val side get() = link.side
        @Volatile var rx: BluetoothGattCharacteristic? = null

        fun ready() = link.gatt != null && rx != null

        /** A command, with response (the module's sendG1CommandToDevice; the ack paces the next). */
        fun command(data: ByteArray) = rx?.let { link.writeAndWait(it, data, 1_000) } ?: false

        fun noResponse(data: ByteArray) = rx?.let { link.write(it, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) } ?: false

        override fun onConnected(arm: BleArm) = phase(side, LinkPhase.DISCOVERING)

        override fun onServices(
            arm: BleArm,
            gatt: BluetoothGatt,
        ) {
            val nus = gatt.getService(G1Protocol.NUS_SERVICE)
            val txChar = nus?.getCharacteristic(G1Protocol.NUS_TX)
            rx = nus?.getCharacteristic(G1Protocol.NUS_RX)
            if (rx == null || txChar == null) {
                error("${side.name.lowercase()} arm: not a G1 (no Nordic UART service)")
                return
            }
            link.enableNotify(txChar, cccd = true)
            phase(side, LinkPhase.READY)
            startHeartbeat()
            if (wanted) other(this)?.let { o -> if (o.link.gatt == null) handler.postDelayed({ if (wanted) o.link.connect(background = false) }, 500) }
        }

        override fun onNotify(
            arm: BleArm,
            uuid: UUID,
            value: ByteArray,
        ) {
            if (uuid != G1Protocol.NUS_TX || value.isEmpty()) return
            val payload = value.copyOfRange(1, value.size)
            when (value[0].toInt() and 0xFF) {
                G1Protocol.CMD_MIC_DATA -> if (mic) events.tryEmit(GlassesEvent.Audio(payload, "lc3", 16_000, side))
                G1Protocol.CMD_EVENT -> {
                    val e = G1Protocol.event(payload) ?: return
                    when (e) {
                        is GlassesEvent.Worn -> state.update { it.copy(worn = e.worn) }
                        is GlassesEvent.Battery -> state.update { it.copy(battery = it.battery + ((if (e.case) "case" else side.name.lowercase()) to e.level)) }
                        else -> {}
                    }
                    events.tryEmit(if (e is GlassesEvent.Input) e.copy(side = side) else e)
                }
                G1Protocol.CMD_BATTERY ->
                    if (payload.size >= 3) {
                        val b = mapOf("left" to (payload[0].toInt() and 0xFF), "right" to (payload[1].toInt() and 0xFF), "case" to (payload[2].toInt() and 0xFF))
                        state.update { it.copy(battery = b) }
                    }
            }
        }

        override fun onDisconnected(
            arm: BleArm,
            wanted: Boolean,
        ) {
            rx = null
            phase(side, LinkPhase.OFF)
            if (side == GlassesSide.RIGHT) mic = false
            if (!wanted && this@G1Glasses.wanted) {
                handler.postDelayed({ if (this@G1Glasses.wanted && link.gatt == null) link.connect(background = true) }, 1_000)
            }
        }
    }

    private val arms: List<Arm> =
        listOfNotNull(leftAddress?.let { Arm(GlassesSide.LEFT, it) }, rightAddress?.let { Arm(GlassesSide.RIGHT, it) })

    private fun other(a: Arm) = arms.firstOrNull { it !== a }

    private fun ready() = arms.filter { it.ready() }

    private val heartbeat =
        object : Runnable {
            override fun run() {
                if (ready().isEmpty()) return
                if (!heartbeatPaused) {
                    val beat = G1Protocol.heartbeat(heartbeatSeq++)
                    ready().forEach { it.noResponse(beat) }
                }
                handler.postDelayed(this, G1Protocol.HEARTBEAT_MS)
            }
        }

    private fun startHeartbeat() {
        handler.removeCallbacks(heartbeat)
        handler.postDelayed(heartbeat, G1Protocol.HEARTBEAT_MS)
    }

    private fun phase(
        side: GlassesSide,
        p: LinkPhase,
    ) = state.update {
        val s = if (side == GlassesSide.LEFT) it.copy(left = p) else it.copy(right = p)
        if (p == LinkPhase.READY) s.copy(error = null) else if (side == GlassesSide.RIGHT && p == LinkPhase.OFF) s.copy(mic = false) else s
    }

    private fun error(msg: String) {
        Log.w(TAG, msg)
        state.update { it.copy(error = msg) }
    }

    /** Runs [job] on the sender now or after the one in progress, replacing anything still waiting. */
    private fun submit(job: () -> Unit) {
        if (pending.getAndSet(job) == null) {
            tx.execute {
                while (true) {
                    val next = pending.getAndSet(null) ?: break
                    runCatching(next).onFailure { Log.w(TAG, "send failed", it) }
                }
            }
        }
    }

    override fun connect() {
        wanted = true
        handler.post { arms.firstOrNull()?.takeIf { it.link.gatt == null }?.link?.connect(background = false) }
    }

    override fun disconnect() {
        wanted = false
        handler.post {
            handler.removeCallbacks(heartbeat)
            arms.forEach { it.link.disconnect() }
        }
    }

    override fun showText(text: String): Boolean {
        if (ready().isEmpty()) return false
        // The first screen (5 lines of 40): the glasses surface lays its text out to fit one.
        val first = G1Protocol.textPages(text).first()
        submit { ready().forEach { it.command(first) } }
        return true
    }

    override fun showImage(image: GlassesImage): Boolean {
        if (image !is GlassesImage.Bmp1 || ready().isEmpty()) return false
        val packets = G1Protocol.imagePackets(G1Protocol.invertPixels(image.bmp))
        submit {
            // The heartbeat waits while the bitmap goes (g1DisplayBitmap stopped it): its writes would interleave.
            heartbeatPaused = true
            try {
                for (p in packets) {
                    val sent = ready().map { it.noResponse(p) }
                    Thread.sleep(G1Protocol.IMAGE_PACKET_DELAY_MS)
                    if (sent.none { it }) return@submit
                }
            } finally {
                heartbeatPaused = false
            }
        }
        return true
    }

    override fun clear(): Boolean {
        if (ready().isEmpty()) return false
        submit { ready().forEach { it.command(G1Protocol.clear()) } }
        return true
    }

    override fun setMic(on: Boolean): Boolean {
        val right = arms.firstOrNull { it.side == GlassesSide.RIGHT && it.ready() } ?: return false
        handler.post {
            mic = on
            state.update { it.copy(mic = on) }
        }
        // Not through [submit]: that slot is the display's latest content, which this mustn't replace.
        tx.execute { right.command(G1Protocol.microphone(on)) }
        return true
    }

    override fun close() {
        disconnect()
        handler.post {
            tx.shutdownNow()
            thread.quitSafely()
        }
    }

    companion object {
        private const val TAG = "PowosGlasses"
    }
}

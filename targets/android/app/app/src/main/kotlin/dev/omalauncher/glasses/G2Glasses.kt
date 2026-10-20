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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Even Realities G2 over raw BLE (G2BluetoothModule.java, ported): the two arms' links, the app-layer auth, the
 * heartbeat, the teleprompter text path, the microphone, input events. Bytes come from [G2Protocol].
 *
 * The pair (connectG2Pair): the left arm first; the right one 500 ms after the left finished auth (two at once fail
 * with "encryption already in progress"). Both get every display command, as the module sent them; either may be
 * the only one known.
 *
 * Reconnect: an arm that drops while wanted is connected again with Android's background connect (autoConnect: the
 * controller waits for its advertising - no polling, no timer), and authenticates again.
 *
 * [rasterAllowed]: [showImage] uses the [Unverified] render channel only when this is on (the "g2Raster" option).
 */
class G2Glasses(
    private val context: Context,
    private val leftAddress: String?,
    private val rightAddress: String?,
    private val rasterAllowed: () -> Boolean,
) : GlassesDevice {
    override val model = GlassesModel.G2
    override val state = MutableStateFlow(GlassesState())
    override val events = MutableSharedFlow<GlassesEvent>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    override val imageVerified = false

    private val thread = HandlerThread("powos-glasses-g2").apply { start() }
    private val handler = Handler(thread.looper)

    @Volatile private var wanted = false

    private inner class Arm(
        side: GlassesSide,
        address: String,
    ) : BleArm.Listener {
        val link = BleArm(context, address, side, handler, this)
        val side get() = link.side
        var write: BluetoothGattCharacteristic? = null
        var notify: BluetoothGattCharacteristic? = null
        var display: BluetoothGattCharacteristic? = null
        val seq = AtomicInteger(0)
        @Volatile var authed = false
        var lastScroll = 0L
        /** The display sends, one at a time, in order: text and images (each waits out its own delays). */
        val tx: ExecutorService = Executors.newSingleThreadExecutor { Thread(it, "powos-glasses-g2-${side.name.lowercase()}") }
        /** What's next to show, the newest only: a send in progress picks it up when it's done. */
        val pending = AtomicReference<(() -> Unit)?>(null)
        private val heartbeat =
            object : Runnable {
                override fun run() {
                    if (!authed || link.gatt == null) return
                    beat()
                    handler.postDelayed(this, G2Protocol.HEARTBEAT_MS)
                }
            }

        fun nextSeq() = seq.getAndIncrement() and 0xFF

        /** A heartbeat, numbered as the module numbered them: seq, and seq + 1 as its message id. */
        fun beat() = nextSeq().let { send(G2Protocol.heartbeat(it, it + 1)) }

        fun send(p: ByteArray) = write?.let { link.write(it, p, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) } ?: false

        fun ready() = authed && link.gatt != null && write != null

        override fun onConnected(arm: BleArm) = phase(side, LinkPhase.DISCOVERING)

        override fun onServices(
            arm: BleArm,
            gatt: BluetoothGatt,
        ) {
            val main = gatt.getService(G2Protocol.SERVICE)
            write = main?.getCharacteristic(G2Protocol.WRITE)
            notify = main?.getCharacteristic(G2Protocol.NOTIFY)
            display = gatt.getService(G2Protocol.DISPLAY_SERVICE)?.getCharacteristic(G2Protocol.DISPLAY_WRITE)
            val n = notify
            if (write == null || n == null) {
                error("${side.name.lowercase()} arm: not a G2 (no Even service 0x5450)")
                return
            }
            // Local notifications only: writing the CCCD now blocks the GATT queue ~30 s and fails with 133 -
            // it's written after auth, when it may work (or fail harmlessly).
            link.enableNotify(n, cccd = false)
            phase(side, LinkPhase.AUTHENTICATING)
            handler.postDelayed({ authenticate() }, 500)
        }

        /** The 7 auth packets, 100 ms apart; then the session (sendG2AuthPacketSequence). */
        private fun authenticate() {
            val packets = G2Protocol.authPackets((System.currentTimeMillis() / 1000).toInt())
            packets.forEachIndexed { i, p ->
                handler.postDelayed({ if (link.gatt != null) Log.d(TAG, "auth ${i + 1}/7 ${side}: ${send(p)}") }, i * G2Protocol.AUTH_PACKET_DELAY_MS)
            }
            handler.postDelayed({ authenticated() }, (packets.size - 1) * G2Protocol.AUTH_PACKET_DELAY_MS + G2Protocol.POST_AUTH_DELAY_MS)
        }

        private fun authenticated() {
            if (link.gatt == null) return
            seq.set(G2Protocol.FIRST_SEQ)
            authed = true
            Log.i(TAG, "auth complete $side")
            // MTU 512 for the display and the microphone, now that auth is done.
            link.requestMtu(512)
            handler.postDelayed({ notify?.let { link.writeCccd(it) } }, 1_000)
            // The glasses drop the link ~1.5 s after auth without traffic: a heartbeat at 500 ms, then every 15 s.
            handler.postDelayed({ if (authed) beat() }, G2Protocol.FIRST_HEARTBEAT_MS)
            handler.removeCallbacks(heartbeat)
            handler.postDelayed(heartbeat, G2Protocol.HEARTBEAT_MS)
            phase(side, LinkPhase.READY)
            // The other arm after this one's auth (never both at once).
            if (wanted) other(this)?.let { o -> if (o.link.gatt == null) handler.postDelayed({ if (wanted) o.link.connect(background = false) }, 500) }
        }

        override fun onNotify(
            arm: BleArm,
            uuid: UUID,
            value: ByteArray,
        ) {
            if (uuid != G2Protocol.NOTIFY) return
            val p = G2Protocol.parse(value) ?: return
            if (p.type != G2Protocol.TYPE_RESPONSE || p.svcHi == G2Protocol.SVC_AUTH) return
            when {
                G2Protocol.isConversate(p) -> audio(p.payload)
                p.svcHi in G2Protocol.KNOWN_SERVICES -> Log.d(TAG, "service 0x%02X-%02X from $side (%d bytes)".format(p.svcHi, p.svcLo, p.payload.size))
                else -> {
                    val type = G2Protocol.inputEvent(p.payload) ?: return
                    val input = GlassesInput.ofG2(type)
                    if (input == GlassesInput.SCROLL_UP || input == GlassesInput.SCROLL_DOWN) {
                        val now = System.currentTimeMillis()
                        if (now - lastScroll < G2Protocol.SCROLL_THROTTLE_MS) return
                        lastScroll = now
                    }
                    events.tryEmit(GlassesEvent.Input(input, side))
                }
            }
        }

        private fun audio(payload: ByteArray) {
            if (G2Protocol.looksLikeAudio(payload)) {
                events.tryEmit(GlassesEvent.Audio(payload, "pcm_s16le", 16_000, side))
            } else {
                G2Protocol.transcript(payload)?.let { (text, final) -> events.tryEmit(GlassesEvent.Transcript(text, final)) }
            }
        }

        override fun onDisconnected(
            arm: BleArm,
            wanted: Boolean,
        ) {
            authed = false
            handler.removeCallbacks(heartbeat)
            phase(side, LinkPhase.OFF)
            if (!wanted && this@G2Glasses.wanted) {
                // Back when it's in range again: Android's background connect, then auth again.
                handler.postDelayed({ if (this@G2Glasses.wanted && link.gatt == null) link.connect(background = true) }, 1_000)
            }
        }

        /** Runs [job] on this arm's sender now, or after the one in progress - replacing anything still waiting. */
        fun submit(job: () -> Unit) {
            if (pending.getAndSet(job) == null) {
                tx.execute {
                    while (true) {
                        val next = pending.getAndSet(null) ?: break
                        runCatching(next).onFailure { Log.w(TAG, "send failed", it) }
                    }
                }
            }
        }
    }

    private val arms: List<Arm> =
        listOfNotNull(leftAddress?.let { Arm(GlassesSide.LEFT, it) }, rightAddress?.let { Arm(GlassesSide.RIGHT, it) })

    private fun other(a: Arm) = arms.firstOrNull { it !== a }

    private fun ready() = arms.filter { it.ready() }

    private fun phase(
        side: GlassesSide,
        p: LinkPhase,
    ) = state.update {
        val s = if (side == GlassesSide.LEFT) it.copy(left = p) else it.copy(right = p)
        if (p == LinkPhase.READY) s.copy(error = null) else if (p == LinkPhase.OFF && !s.ready) s.copy(mic = false) else s
    }

    private fun error(msg: String) {
        Log.w(TAG, msg)
        state.update { it.copy(error = msg) }
    }

    override fun connect() {
        wanted = true
        // The first arm only: the second follows its auth.
        handler.post { arms.firstOrNull()?.takeIf { it.link.gatt == null }?.link?.connect(background = false) }
    }

    override fun disconnect() {
        wanted = false
        handler.post { arms.forEach { it.link.disconnect() } }
    }

    override fun showText(text: String): Boolean {
        val r = ready()
        if (r.isEmpty()) return false
        for (arm in r) {
            arm.submit {
                // Numbered as one block: a heartbeat meanwhile takes the next number after it.
                val count = G2Protocol.teleprompter(text, 0).first.size
                val start = arm.seq.getAndAdd(count)
                for (step in G2Protocol.teleprompter(text, start).first) {
                    if (!arm.ready()) return@submit
                    arm.send(step.packet)
                    Thread.sleep(step.delayMs)
                }
            }
        }
        return true
    }

    override fun showImage(image: GlassesImage): Boolean {
        if (image !is GlassesImage.Gray4 || !rasterAllowed()) return false
        val r = ready().filter { it.display != null }
        if (r.isEmpty()) return false
        for (arm in r) {
            arm.submit {
                // g2DisplayImage: wake the display, 300 ms, the pixels on 0x6401 - with response where it can (the
                // glasses' acks pace it: without them later images timed out), else paced 10 ms - then 500 ms to rest.
                val seq = arm.nextSeq()
                arm.send(G2Protocol.displayWake(seq, seq + 1))
                Thread.sleep(300)
                val ch = arm.display ?: return@submit
                val withResponse = ch.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0
                for (f in G2Protocol.renderFragments(image.data)) {
                    val ok =
                        if (withResponse) {
                            arm.link.writeAndWait(ch, f, 500)
                        } else {
                            arm.link.write(ch, f, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE).also { Thread.sleep(10) }
                        }
                    if (!ok) {
                        Log.w(TAG, "image fragment not acked: stopped")
                        return@submit
                    }
                }
                Thread.sleep(500)
            }
        }
        return true
    }

    /**
     * HACK: no "clear" / exit command is known for the G2, so blanking is an empty teleprompter page (blank lines):
     * the whole ~2.5 s text sequence for nothing. Real fix: capture the Even app closing its display (HCI log) - the
     * EvenHub shutdown (0x14-20, cmd 6) in the user's module is an unverified guess - and send that.
     */
    override fun clear() = showText(" ")

    override fun setMic(on: Boolean): Boolean {
        var ok = false
        for (arm in ready()) {
            val seq = arm.nextSeq()
            ok = arm.send(G2Protocol.conversate(seq, seq + 1, on)) || ok
        }
        if (ok) state.update { it.copy(mic = on) }
        return ok
    }

    override fun close() {
        disconnect()
        handler.post {
            arms.forEach { it.tx.shutdownNow() }
            thread.quitSafely()
        }
    }

    companion object {
        private const val TAG = "PowosGlasses"
    }
}

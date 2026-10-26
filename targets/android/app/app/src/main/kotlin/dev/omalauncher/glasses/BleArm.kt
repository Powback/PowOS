package dev.omalauncher.glasses

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.os.Handler
import android.util.Log
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * One arm's BLE link: GATT connect, service discovery, writes, notifications - the generic half of the user's
 * BluetoothPlugin.connectDevice / its GattCallback, ported with its hardware-learned timings:
 *
 * - no MTU request before discovery (onMtuChanged stalls GATT setup on some chipsets; the G2's auth fits in 20 bytes);
 * - discoverServices() 2 s after connecting, without refresh() (the glasses don't answer an over-the-air discovery;
 *   the cache answers at once), once more at 22 s if nothing came;
 * - a direct connect gives up after 30 s;
 * - a link that dropped before discovery is reconnected twice, 4 s apart (gatt.connect() on the same callback).
 *   The module's third step - removeBond() through reflection, then connect again - is left out: it silently deletes
 *   the user's system bond, and the G2 doesn't bond anyway. Giving up reports the error instead.
 *
 * Callbacks arrive on [handler]'s thread. Bluetooth permissions: the app targets SDK 28, so BLUETOOTH/BLUETOOTH_ADMIN
 * (install-time) cover connecting; Android grants the rest with them.
 */
@SuppressLint("MissingPermission")
internal class BleArm(
    private val context: Context,
    val address: String,
    val side: GlassesSide,
    private val handler: Handler,
    private val listener: Listener,
) {
    interface Listener {
        fun onConnected(arm: BleArm)

        /** Services are there: find the characteristics, start the session. */
        fun onServices(
            arm: BleArm,
            gatt: BluetoothGatt,
        )

        fun onNotify(
            arm: BleArm,
            uuid: UUID,
            value: ByteArray,
        )

        /** The link is gone; [wanted]: not asked for (a drop, a timeout, a failed discovery). */
        fun onDisconnected(
            arm: BleArm,
            wanted: Boolean,
        )
    }

    @Volatile var gatt: BluetoothGatt? = null
        private set

    @Volatile var phase = LinkPhase.OFF

    private var discovered = false
    private var discoveryFails = 0
    private var closing = false
    private var serial = 0

    /** onCharacteristicWrite's wait, for the write-with-response sends (G1 commands, G2 image fragments). */
    @Volatile private var writeLatch: CountDownLatch? = null

    @Volatile private var writeStatus = BluetoothGatt.GATT_SUCCESS

    /** Connects; [background]: Android's autoConnect, which waits for the arm to advertise (no timeout, no polling). */
    fun connect(background: Boolean) {
        if (gatt != null) return
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return fail("no Bluetooth")
        if (!adapter.isEnabled) return fail("Bluetooth is off")
        val device = runCatching { adapter.getRemoteDevice(address) }.getOrNull() ?: return fail("bad address $address")
        closing = false
        discovered = false
        phase = LinkPhase.CONNECTING
        val mine = ++serial
        Log.i(TAG, "connect $side $address background=$background bond=${device.bondState}")
        gatt =
            try {
                device.connectGatt(context, background, Callback(mine), BluetoothDevice.TRANSPORT_LE)
            } catch (e: SecurityException) {
                return fail("Bluetooth permission denied: ${e.message}")
            }
        if (!background) {
            handler.postDelayed({
                if (serial == mine && phase == LinkPhase.CONNECTING) {
                    Log.w(TAG, "connect timeout $side $address (30 s)")
                    drop(wanted = false)
                }
            }, 30_000)
        }
    }

    /** Disconnects for good (until [connect] again). */
    fun disconnect() {
        closing = true
        drop(wanted = true)
    }

    private fun fail(why: String) {
        Log.w(TAG, "$side $address: $why")
        phase = LinkPhase.OFF
        listener.onDisconnected(this, wanted = false)
    }

    private fun drop(wanted: Boolean) {
        serial++
        val g = gatt
        gatt = null
        phase = LinkPhase.OFF
        discovered = false
        writeLatch?.countDown()
        runCatching {
            g?.disconnect()
            g?.close()
        }
        listener.onDisconnected(this, wanted)
    }

    fun characteristic(
        service: UUID,
        uuid: UUID,
    ): BluetoothGattCharacteristic? = gatt?.getService(service)?.getCharacteristic(uuid)

    /** Notifications on [ch] locally; [cccd]: the remote descriptor written too. */
    fun enableNotify(
        ch: BluetoothGattCharacteristic,
        cccd: Boolean,
    ): Boolean {
        val g = gatt ?: return false
        return try {
            val ok = g.setCharacteristicNotification(ch, true)
            if (cccd) writeCccd(ch)
            ok
        } catch (e: SecurityException) {
            Log.w(TAG, "notify permission denied", e)
            false
        }
    }

    fun writeCccd(ch: BluetoothGattCharacteristic) {
        val g = gatt ?: return
        val d = ch.getDescriptor(G2Protocol.CCCD) ?: return
        runCatching {
            if (Build.VERSION.SDK_INT >= 33) {
                g.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            } else {
                @Suppress("DEPRECATION")
                d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                @Suppress("DEPRECATION")
                g.writeDescriptor(d)
            }
        }.onFailure { Log.w(TAG, "CCCD write failed (non-critical)", it) }
    }

    fun requestMtu(mtu: Int) {
        runCatching { gatt?.requestMtu(mtu) }.onFailure { Log.w(TAG, "MTU request failed (non-critical)", it) }
    }

    /** Queues a write; true if Android took it. */
    fun write(
        ch: BluetoothGattCharacteristic,
        data: ByteArray,
        type: Int,
    ): Boolean {
        val g = gatt ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= 33) {
                g.writeCharacteristic(ch, data, type) == BluetoothGatt.GATT_SUCCESS
            } else {
                @Suppress("DEPRECATION")
                ch.writeType = type
                @Suppress("DEPRECATION")
                ch.value = data
                @Suppress("DEPRECATION")
                g.writeCharacteristic(ch)
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "write permission denied", e)
            false
        }
    }

    /** A write with response, waiting up to [timeoutMs] for onCharacteristicWrite (call off the handler's thread). */
    fun writeAndWait(
        ch: BluetoothGattCharacteristic,
        data: ByteArray,
        timeoutMs: Long,
    ): Boolean {
        val latch = CountDownLatch(1)
        writeLatch = latch
        writeStatus = BluetoothGatt.GATT_SUCCESS
        if (!write(ch, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)) {
            writeLatch = null
            return false
        }
        val done = latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        writeLatch = null
        return done && writeStatus == BluetoothGatt.GATT_SUCCESS && gatt != null
    }

    private inner class Callback(
        private val mine: Int,
    ) : BluetoothGattCallback() {
        private fun live() = serial == mine

        override fun onConnectionStateChange(
            g: BluetoothGatt,
            status: Int,
            newState: Int,
        ) {
            handler.post {
                if (!live()) return@post
                Log.i(TAG, "$side $address state=$newState status=$status")
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    gatt = g
                    phase = LinkPhase.DISCOVERING
                    listener.onConnected(this@BleArm)
                    handler.postDelayed({ if (live() && !discovered) discover(g) }, 2_000)
                    handler.postDelayed({
                        if (live() && !discovered && phase == LinkPhase.DISCOVERING) {
                            Log.w(TAG, "service discovery retry $side")
                            discover(g)
                        }
                    }, 22_000)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    if (closing) return@post drop(wanted = true)
                    // Dropped before its services came: the stale-cache case - try the same GATT again, twice.
                    if (!discovered && discoveryFails < 2) {
                        discoveryFails++
                        phase = LinkPhase.CONNECTING
                        Log.w(TAG, "$side dropped before discovery (attempt $discoveryFails/3): reconnecting in 4 s")
                        handler.postDelayed({ if (live()) runCatching { g.connect() }.onFailure { drop(false) } }, 4_000)
                        return@post
                    }
                    drop(wanted = false)
                }
            }
        }

        private fun discover(g: BluetoothGatt) {
            runCatching { g.discoverServices() }.onFailure { Log.w(TAG, "discoverServices failed", it) }
        }

        override fun onMtuChanged(
            g: BluetoothGatt,
            mtu: Int,
            status: Int,
        ) {
            Log.i(TAG, "$side MTU $mtu status=$status")
            // Only before the arm is known: the post-auth MTU request lands here too, and must not re-discover.
            handler.post { if (live() && !discovered) discover(g) }
        }

        override fun onServicesDiscovered(
            g: BluetoothGatt,
            status: Int,
        ) {
            handler.post {
                if (!live() || discovered) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.w(TAG, "$side discovery failed: $status")
                    return@post
                }
                discovered = true
                discoveryFails = 0
                listener.onServices(this@BleArm, g)
            }
        }

        @Deprecated("Android 12 and older")
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
        ) {
            @Suppress("DEPRECATION")
            val v = ch.value ?: return
            changed(ch.uuid, v.copyOf())
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
        ) = changed(ch.uuid, value)

        private fun changed(
            uuid: UUID,
            value: ByteArray,
        ) {
            handler.post { if (live()) listener.onNotify(this@BleArm, uuid, value) }
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            status: Int,
        ) {
            writeStatus = status
            writeLatch?.countDown()
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            d: BluetoothGattDescriptor,
            status: Int,
        ) {
            // The G2's CCCD write often fails with 133 (a bond/LTK quirk): non-fatal, local notify is on.
            if (status != BluetoothGatt.GATT_SUCCESS) Log.w(TAG, "$side CCCD write: $status (non-fatal)")
        }
    }

    companion object {
        private const val TAG = "PowosGlasses"
    }
}

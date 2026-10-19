package dev.omalauncher.shell

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread

/**
 * Remote input (shell/ui/remote.tsx): the phone as a keyboard and mouse for a computer - real HID devices, so the
 * computer needs no software, either way:
 *
 * - USB: HID functions (a boot keyboard, a boot mouse) on the phone's own USB gadget, next to adb - the computer at
 *   the other end of the cable sees a keyboard and a mouse, in its BIOS too. Root: assets/remote-input/hidg.sh does
 *   the gadget (why it survives Android's own USB handling is there) and writes the reports to /dev/hidg*, which only
 *   root may open - a root helper rather than a sepolicy rule letting the app at a device node.
 * - Bluetooth: Android's HID device profile (BluetoothHidDevice) - the phone a keyboard + mouse a computer pairs with,
 *   reconnecting to the last one.
 *
 * One per app (pages come and go: home, a reload): the page's reports go to the target picked. Its state goes to every
 * page as "remote.state".
 */
@SuppressLint("MissingPermission") // BLUETOOTH / BLUETOOTH_ADMIN: the app targets SDK 28, Android grants the rest.
object RemoteInput {
    private const val TAG = "PowosRemote"
    private val main = Handler(Looper.getMainLooper())
    private val onMain = Executor { main.post(it) }
    private val listeners = LinkedHashSet<(JSONObject) -> Unit>()
    private lateinit var app: Context
    private val prefs get() = app.getSharedPreferences("remote-input", Context.MODE_PRIVATE)

    /** Where reports go: "usb", "bluetooth" or nowhere. */
    private var target: String? = null

    // USB: the gadget's HID functions up, the root helper writing reports, the UDC's state ("configured": a computer has it).
    private var usbOn = false
    private var usbBusy = false
    private var usbError: String? = null
    private var usbState = "unknown"
    private var usbChecked = 0L
    @Volatile private var controller: String? = null
    private var nodes: Pair<String, String>? = null
    @Volatile private var pipe: Process? = null
    /** The current helper's lines: each helper its own, so one that died can't take a line meant for the next. */
    @Volatile private var lines = LinkedBlockingQueue<String>(1024)

    // Bluetooth: the HID device profile, our app registered on it, the computer connected.
    private var hid: BluetoothHidDevice? = null
    private var proxyAsked = false
    private var registered = false
    private var host: BluetoothDevice? = null
    private var connecting: String? = null
    private var btError: String? = null

    /** Once per app: what was on last time (pref) comes back on when a page first asks - a reboot drops the gadget. */
    private var restored = false

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        target = prefs.getString("target", null)
        val filter =
            IntentFilter().apply {
                addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
                addAction(BluetoothAdapter.ACTION_SCAN_MODE_CHANGED)
                addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            }
        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(
                    c: Context,
                    i: Intent,
                ) {
                    // Bluetooth on again with ours wanted: registered again (Android dropped it with the adapter).
                    if (i.action == BluetoothAdapter.ACTION_STATE_CHANGED) {
                        val s = i.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)
                        if (s == BluetoothAdapter.STATE_ON && prefs.getBoolean("bt", false)) bluetoothUp()
                        if (s == BluetoothAdapter.STATE_OFF) {
                            registered = false
                            host = null
                            connecting = null
                        }
                    }
                    changed()
                }
            }
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED) else app.registerReceiver(receiver, filter)
    }

    /** A page's end of it (ShellBridge's "remote.*" calls): its calls, and "remote.state" while it's open. */
    class Client(
        context: Context,
        private val activity: Activity?,
        private val emit: (String, Any?) -> Unit,
    ) {
        private val listener: (JSONObject) -> Unit = { emit("remote.state", it) }

        init {
            init(context)
            listeners += listener
        }

        fun call(
            method: String,
            a: JSONArray,
        ): Any? =
            when (method) {
                "state" -> state()
                "target" -> target(a.optString(0).takeIf { !a.isNull(0) && it.isNotEmpty() })
                "off" -> off(a.getString(0))
                "discoverable" -> discoverable(activity)
                "connect" -> connect(a.getString(0))
                "disconnect" -> disconnect()
                "keys" -> keys(a.getJSONArray(0))
                "mouse" -> mouse(a.getInt(0), a.getInt(1), a.getInt(2), a.optInt(3), a.optInt(4))
                else -> throw IllegalArgumentException("no such call: remote.$method")
            }

        fun close() {
            listeners -= listener
        }
    }

    fun state(): JSONObject {
        if (!restored) {
            restored = true
            if (prefs.getBoolean("usb", false)) usbUp()
            if (prefs.getBoolean("bt", false)) bluetoothUp()
        }
        if (usbOn && System.currentTimeMillis() - usbChecked > 1500) checkUsb()
        return json()
    }

    /** Sends reports to [t], turning its side on first: the gadget's functions in, or our HID app registered. */
    fun target(t: String?): JSONObject {
        require(t == null || t == "usb" || t == "bluetooth") { "no such target: $t" }
        target = t
        prefs.edit().putString("target", t).apply()
        if (t == "usb" && !usbOn) usbUp()
        if (t == "bluetooth" && !registered) bluetoothUp()
        changed()
        return json()
    }

    /** Turns a side off: USB, the gadget as Android made it (the functions out); Bluetooth, our HID app unregistered. */
    fun off(side: String): JSONObject {
        when (side) {
            "usb" -> usbDown()
            "bluetooth" -> bluetoothDown()
            else -> throw IllegalArgumentException("no such side: $side")
        }
        if (target == side) {
            target = null
            prefs.edit().putString("target", null).apply()
        }
        changed()
        return json()
    }

    /** Keyboard reports, in order: each [modifiers, usage...] (up to 6 usages held). */
    fun keys(reports: JSONArray) {
        for (i in 0 until reports.length()) {
            val r = reports.getJSONArray(i)
            val b = ByteArray(8)
            b[0] = r.optInt(0).toByte()
            for (k in 1 until minOf(r.length(), 7)) b[k + 1] = r.optInt(k).toByte()
            send(KEYBOARD, b)
        }
    }

    /** A mouse report: buttons (1 left, 2 right, 4 middle), motion and wheels - large moves split into several. */
    fun mouse(
        buttons: Int,
        dx: Int,
        dy: Int,
        wheel: Int,
        pan: Int,
    ) {
        var x = dx
        var y = dy
        var w = wheel
        var p = pan
        do {
            val sx = x.coerceIn(-127, 127)
            val sy = y.coerceIn(-127, 127)
            val sw = w.coerceIn(-127, 127)
            val sp = p.coerceIn(-127, 127)
            send(MOUSE, byteArrayOf(buttons.toByte(), sx.toByte(), sy.toByte(), sw.toByte(), sp.toByte()))
            x -= sx
            y -= sy
            w -= sw
            p -= sp
        } while (x != 0 || y != 0 || w != 0 || p != 0)
    }

    private fun send(
        report: Int,
        bytes: ByteArray,
    ) {
        when (target) {
            "usb" -> {
                if (!usbOn) return
                ensurePipe()
                // A full queue (the computer not reading, asleep): this report goes, rather than the page waiting.
                lines.offer((if (report == KEYBOARD) "k " else "m ") + bytes.joinToString("") { "\\0%03o".format(it.toInt() and 0xff) })
            }
            "bluetooth" -> {
                val h = host ?: return
                runCatching { hid?.sendReport(h, report, bytes) }.onFailure { Log.w(TAG, "sendReport failed", it) }
            }
        }
    }

    // ---- USB ----

    /** The helper, out of the APK, where root can run it (the app's files). */
    private fun helper(): File =
        File(app.filesDir, "remote-input/hidg.sh").apply {
            parentFile?.mkdirs()
            writeBytes(app.assets.open("remote-input/hidg.sh").use { it.readBytes() })
        }

    /** Runs [command] as root: its output (stderr too) and exit code. */
    private fun su(command: String): Pair<Int, String> {
        val p = ProcessBuilder("su", "-c", command).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        return p.waitFor() to out
    }

    private fun usbUp() {
        if (usbBusy) return
        usbBusy = true
        usbError = null
        changed()
        thread(name = "remote-usb-up", isDaemon = true) {
            val result =
                runCatching {
                    val (code, out) = su("sh '${helper().absolutePath}' up")
                    val kb = out.lineSequence().firstOrNull { it.startsWith("kb /dev/") }?.substringAfter(' ')
                    val ms = out.lineSequence().firstOrNull { it.startsWith("mouse /dev/") }?.substringAfter(' ')
                    if (code != 0 || kb == null || ms == null) error(out.lineSequence().lastOrNull { it.isNotBlank() }?.removePrefix("error: ") ?: "the USB helper failed ($code)")
                    kb to ms
                }
            main.post {
                usbBusy = false
                result
                    .onSuccess {
                        nodes = it
                        usbOn = true
                        prefs.edit().putBoolean("usb", true).apply()
                        checkUsb()
                    }.onFailure {
                        Log.w(TAG, "USB HID up failed", it)
                        usbError = it.message
                        usbOn = false
                    }
                changed()
            }
        }
    }

    /** Rollback: the helper stopped, the functions out of the gadget, adb's own config untouched. */
    private fun usbDown() {
        usbOn = false
        prefs.edit().putBoolean("usb", false).apply()
        stopPipe()
        usbBusy = true
        thread(name = "remote-usb-down", isDaemon = true) {
            val (code, out) = runCatching { su("sh '${helper().absolutePath}' down") }.getOrElse { -1 to (it.message ?: "") }
            main.post {
                usbBusy = false
                nodes = null
                usbState = "off"
                usbError = if (code == 0) null else out.trim().ifEmpty { "the USB helper failed ($code)" }
                changed()
            }
        }
    }

    /** The UDC's state, off the main thread: "configured" once a computer enumerated the phone. */
    private fun checkUsb() {
        usbChecked = System.currentTimeMillis()
        thread(name = "remote-usb-state", isDaemon = true) {
            val udc = controller ?: runCatching { ProcessBuilder("getprop", "sys.usb.controller").start().inputStream.bufferedReader().readText().trim() }.getOrDefault("").also { controller = it }
            val s =
                runCatching { File("/sys/class/udc/$udc/state").readText().trim() }.getOrNull()
                    ?: runCatching { su("cat /sys/class/udc/$udc/state").second.trim() }.getOrDefault("unknown")
            main.post {
                if (s != usbState) {
                    usbState = s
                    changed()
                }
            }
        }
    }

    /** The root helper holding /dev/hidg* open, fed a line a report; started again if it's gone. */
    @Synchronized
    private fun ensurePipe() {
        if (pipe?.isAlive == true) return
        val (kb, ms) = nodes ?: return
        val p =
            runCatching { ProcessBuilder("su", "-c", "sh '${helper().absolutePath}' pipe $kb $ms").redirectErrorStream(true).start() }
                .onFailure { Log.w(TAG, "USB helper didn't start", it) }
                .getOrNull() ?: return
        val queue = LinkedBlockingQueue<String>(1024)
        lines = queue
        pipe = p
        thread(name = "remote-usb-log", isDaemon = true) { p.inputStream.bufferedReader().forEachLine { Log.i(TAG, "hidg: $it") } }
        thread(name = "remote-usb-pipe", isDaemon = true) {
            val out = p.outputStream.bufferedWriter()
            try {
                while (pipe === p) {
                    out.write(queue.take())
                    out.newLine()
                    // Several queued (a word typed at once): one flush for them all.
                    if (queue.isEmpty() || pipe !== p) out.flush()
                }
            } catch (e: Exception) {
                Log.w(TAG, "USB helper pipe closed", e)
            }
            if (pipe === p) pipe = null
        }
    }

    private fun stopPipe() {
        val p = pipe ?: return
        pipe = null
        lines.offer("q")
        main.postDelayed({ p.destroy() }, 500)
    }

    // ---- Bluetooth ----

    private fun adapter(): BluetoothAdapter? = app.getSystemService(BluetoothManager::class.java)?.adapter

    private fun bluetoothUp() {
        prefs.edit().putBoolean("bt", true).apply()
        val adapter = adapter() ?: return run { btError = "this phone has no Bluetooth" }
        btError = null
        if (!adapter.isEnabled) {
            // Android asks the user ("an app wants to turn on Bluetooth"); STATE_ON then registers (the receiver).
            runCatching { app.startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            return
        }
        val h = hid
        if (h != null) return register(h)
        if (proxyAsked) return
        proxyAsked = true
        val asked =
            adapter.getProfileProxy(
                app,
                object : BluetoothProfile.ServiceListener {
                    override fun onServiceConnected(
                        profile: Int,
                        proxy: BluetoothProfile,
                    ) {
                        proxyAsked = false
                        hid = proxy as BluetoothHidDevice
                        if (prefs.getBoolean("bt", false)) register(proxy)
                    }

                    override fun onServiceDisconnected(profile: Int) {
                        hid = null
                        registered = false
                        host = null
                        changed()
                    }
                },
                BluetoothProfile.HID_DEVICE,
            )
        if (!asked) {
            proxyAsked = false
            btError = "Android has no Bluetooth HID device profile here"
            changed()
        }
    }

    private fun register(h: BluetoothHidDevice) {
        if (registered) return
        val sdp = BluetoothHidDeviceAppSdpSettings("PowOS Remote", "PowOS phone keyboard and touchpad", "PowOS", BluetoothHidDevice.SUBCLASS1_COMBO, BT_DESCRIPTOR)
        val ok = runCatching { h.registerApp(sdp, null, null, onMain, callback) }.onFailure { Log.w(TAG, "registerApp failed", it) }.getOrDefault(false)
        if (!ok) btError = "Bluetooth wouldn't take the keyboard (another app may hold the HID device profile)"
        changed()
    }

    private val callback =
        object : BluetoothHidDevice.Callback() {
            override fun onAppStatusChanged(
                plugged: BluetoothDevice?,
                ok: Boolean,
            ) {
                Log.i(TAG, "HID app registered=$ok plugged=${plugged?.address}")
                registered = ok
                if (!ok) host = null
                // Registered: back to the computer it was last with (or the one Android says it's plugged into).
                if (ok && host == null) (plugged ?: last())?.let { connect(it.address) }
                changed()
            }

            override fun onConnectionStateChanged(
                device: BluetoothDevice,
                state: Int,
            ) {
                Log.i(TAG, "HID host ${device.address} state=$state")
                when (state) {
                    BluetoothProfile.STATE_CONNECTED -> {
                        host = device
                        connecting = null
                        prefs.edit().putString("bt.last", device.address).apply()
                    }
                    BluetoothProfile.STATE_CONNECTING -> connecting = device.address
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        if (host?.address == device.address) host = null
                        if (connecting == device.address) connecting = null
                    }
                }
                changed()
            }

            override fun onGetReport(
                device: BluetoothDevice,
                type: Byte,
                id: Byte,
                bufferSize: Int,
            ) {
                // Nothing held: an empty report of the kind asked.
                val size = if (id.toInt() == MOUSE) 5 else 8
                runCatching { hid?.replyReport(device, type, id, ByteArray(size)) }
            }

            override fun onSetReport(
                device: BluetoothDevice,
                type: Byte,
                id: Byte,
                data: ByteArray,
            ) {
                // The keyboard's LEDs (caps lock...): taken, not shown.
                runCatching { hid?.reportError(device, BluetoothHidDevice.ERROR_RSP_SUCCESS) }
            }
        }

    private fun bluetoothDown() {
        prefs.edit().putBoolean("bt", false).apply()
        runCatching { hid?.unregisterApp() }
        registered = false
        host = null
        connecting = null
    }

    private fun last(): BluetoothDevice? = prefs.getString("bt.last", null)?.let { a -> runCatching { adapter()?.getRemoteDevice(a) }.getOrNull() }

    fun connect(address: String) {
        val h = hid ?: error("Bluetooth keyboard isn't on")
        val device = adapter()?.getRemoteDevice(address) ?: error("no Bluetooth")
        connecting = address
        if (!h.connect(device)) {
            connecting = null
            btError = "couldn't reach ${device.name ?: address}"
        }
        changed()
    }

    fun disconnect() {
        host?.let { runCatching { hid?.disconnect(it) } }
        changed()
    }

    /** Asks Android to make the phone visible to computers for a while (its own dialog), for a new one to pair. */
    private fun discoverable(activity: Activity?) {
        val i = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE).putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 180)
        if (activity != null) activity.startActivity(i) else app.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    // ---- state ----

    private fun json(): JSONObject {
        val adapter = adapter()
        val hosts = JSONArray()
        val lastAddress = prefs.getString("bt.last", null)
        if (adapter?.isEnabled == true) {
            // Paired computers (and whichever it was last with): phones and headphones aren't hosts for a keyboard.
            runCatching { adapter.bondedDevices }.getOrNull().orEmpty()
                .filter { it.address == lastAddress || it.bluetoothClass?.majorDeviceClass == BluetoothClass.Device.Major.COMPUTER }
                .sortedByDescending { it.address == lastAddress }
                .forEach { d ->
                    hosts.put(
                        JSONObject()
                            .put("address", d.address)
                            .put("name", d.name ?: d.address)
                            .put("last", d.address == lastAddress)
                            .put("connected", d.address == host?.address),
                    )
                }
        }
        val usb =
            JSONObject()
                .put("on", usbOn)
                .put("busy", usbBusy)
                .put("state", if (usbOn) usbState else "off")
                .put("error", usbError ?: JSONObject.NULL)
        val bt =
            JSONObject()
                .put("available", adapter != null)
                .put("enabled", adapter?.isEnabled == true)
                .put("registered", registered)
                .put("discoverable", adapter?.scanMode == BluetoothAdapter.SCAN_MODE_CONNECTABLE_DISCOVERABLE)
                .put("name", runCatching { adapter?.name }.getOrNull() ?: JSONObject.NULL)
                .put("host", host?.let { JSONObject().put("address", it.address).put("name", it.name ?: it.address) } ?: JSONObject.NULL)
                .put("connecting", connecting ?: JSONObject.NULL)
                .put("hosts", hosts)
                .put("error", btError ?: JSONObject.NULL)
        return JSONObject().put("target", target ?: JSONObject.NULL).put("usb", usb).put("bluetooth", bt)
    }

    private fun changed() {
        if (listeners.isEmpty()) return
        val s = json()
        listeners.toList().forEach { it(s) }
    }

    private const val KEYBOARD = 1
    private const val MOUSE = 2

    /** Bluetooth's descriptor: the USB side's two (hidg.sh), as report 1 (boot keyboard) and report 2 (mouse) of one. */
    private val BT_DESCRIPTOR =
        intArrayOf(
            // Keyboard: modifiers, reserved, 6 keys; LEDs out.
            0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, KEYBOARD,
            0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
            0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
            0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
            0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
            0xc0,
            // Mouse: 5 buttons, X, Y, wheel, horizontal wheel (AC Pan).
            0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x85, MOUSE, 0x09, 0x01, 0xa1, 0x00,
            0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02,
            0x95, 0x01, 0x75, 0x03, 0x81, 0x01,
            0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
            0x05, 0x0c, 0x0a, 0x38, 0x02, 0x95, 0x01, 0x81, 0x06,
            0xc0, 0xc0,
        ).let { ints -> ByteArray(ints.size) { ints[it].toByte() } }
}

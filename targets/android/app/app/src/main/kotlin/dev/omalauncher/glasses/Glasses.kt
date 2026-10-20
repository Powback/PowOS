package dev.omalauncher.glasses

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import dev.omalauncher.App
import dev.omalauncher.shell.ShellHost
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.concurrent.thread

/**
 * The glasses as a PowOS device (docs/GLASSES.md): the paired pair, the one [GlassesDevice] connected to it, and
 * everything that uses it -
 *
 * - shell pages, through ShellBridge's "glasses.*" calls ([Client]) and "glasses.*" events;
 * - the glasses' own screen: the shell's `glasses` page (shell/glasses/), loaded off screen in a WebView of its own
 *   ([ShellHost], as the gate test's page) while the glasses are up, rendering what the glasses show;
 * - PowOS (Linux): `powos glasses` writes commands into the run dir's glasses/cmd/ and reads glasses/status.json
 *   (the same channel as agent-mail: the app's files/run is PowOS's XDG_RUNTIME_DIR, /run/powos-app);
 * - [GlassesService], the foreground service that keeps the connection while it's wanted.
 *
 * Power: nothing polls. Connected and idle, the only traffic is the protocol's heartbeat (G2 15 s, G1 8 s); a dropped
 * arm waits in Android's background connect; the display is cleared when the glasses say they're off the face (G1);
 * the surface pushes only when what it shows changed.
 */
@SuppressLint("MissingPermission")
object Glasses {
    private const val TAG = "PowosGlasses"
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var app: Context
    private val prefs get() = app.getSharedPreferences("glasses", Context.MODE_PRIVATE)

    var device: GlassesDevice? = null
        private set
    private var collectors: List<Job> = emptyList()
    private val clients = LinkedHashSet<Client>()

    /** The off-screen page that draws the glasses' screen (shell mode "glasses"), while they're up. */
    private var surface: ShellHost? = null
    private val dropSurface = Runnable { closeSurface() }

    /** The last text shown, to show again when the glasses are back on the face. */
    private var lastText: String? = null
    private var hidden = false

    private var observer: FileObserver? = null
    private val runDir get() = File(app.filesDir, "run/glasses")

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        watchCommands()
        // Paired and wanted last time (the app restarted, the phone rebooted): connect again.
        if (paired() != null && prefs.getBoolean("wanted", false)) connect()
        writeStatus()
    }

    // --- The pair -------------------------------------------------------------------------------------------------

    /** The paired pair: model, pair id, each arm's address and name. */
    data class Pair(
        val model: GlassesModel,
        val pairId: String,
        val left: String?,
        val right: String?,
        val leftName: String?,
        val rightName: String?,
    )

    fun paired(): Pair? {
        val model = prefs.getString("model", null)?.let { runCatching { GlassesModel.valueOf(it) }.getOrNull() } ?: return null
        val left = prefs.getString("left", null)
        val right = prefs.getString("right", null)
        if (left == null && right == null) return null
        return Pair(model, prefs.getString("pairId", "") ?: "", left, right, prefs.getString("leftName", null), prefs.getString("rightName", null))
    }

    /** An arm the pairing found ([GlassesPairActivity]): remembered, with its side and model from its name. */
    fun remember(
        address: String,
        name: String?,
    ): GlassesName? {
        val n = GlassesName.parse(name) ?: return null
        val e = prefs.edit()
        val current = paired()
        // Another pair than the one remembered: the old one goes.
        if (current != null && (current.pairId != n.pairId || current.model != n.model)) {
            e.remove("left").remove("right").remove("leftName").remove("rightName")
        }
        e.putString("model", n.model.name).putString("pairId", n.pairId)
        if (n.side == GlassesSide.LEFT) e.putString("left", address).putString("leftName", name) else e.putString("right", address).putString("rightName", name)
        e.apply()
        Log.i(TAG, "paired ${n.side} $address ($name)")
        // A device open for the old pair (or one arm of it): closed - the next connect opens it with the arms as now.
        closeDevice()
        changed()
        return n
    }

    /** Forgets the pair: disconnected, its companion associations dropped. */
    @Suppress("DEPRECATION") // by address: the associations were made by address (GlassesPairActivity)
    fun forget() {
        disconnect()
        val p = paired()
        prefs.edit().clear().apply()
        if (p != null) {
            runCatching {
                val cdm = app.getSystemService(CompanionDeviceManager::class.java)
                for (a in listOfNotNull(p.left, p.right)) {
                    if (Build.VERSION.SDK_INT >= 31) runCatching { cdm.stopObservingDevicePresence(a) }
                    runCatching { cdm.disassociate(a) }
                }
            }.onFailure { Log.w(TAG, "disassociate failed", it) }
        }
        changed()
    }

    /** The system's pairing flow ([GlassesPairActivity]): Android's own device picker, no location permission. */
    fun pair(activity: Activity?): String {
        val intent = Intent(app, GlassesPairActivity::class.java)
        return runCatching {
            if (activity != null) activity.startActivity(intent) else app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            "started"
        }.getOrElse {
            Log.w(TAG, "can't start pairing", it)
            "unavailable"
        }
    }

    // --- The connection -------------------------------------------------------------------------------------------

    fun connect(): Boolean {
        val p = paired() ?: return false
        prefs.edit().putBoolean("wanted", true).apply()
        val d = device ?: open(p)
        GlassesService.start(app)
        d.connect()
        changed()
        return true
    }

    fun disconnect() {
        prefs.edit().putBoolean("wanted", false).apply()
        closeDevice()
        GlassesService.stop(app)
        changed()
    }

    private fun closeDevice() {
        device?.close()
        collectors.forEach { it.cancel() }
        collectors = emptyList()
        device = null
        hidden = false
        closeSurface()
    }

    private fun open(p: Pair): GlassesDevice {
        val d =
            when (p.model) {
                GlassesModel.G2 -> G2Glasses(app, p.left, p.right) { option("g2Raster") }
                GlassesModel.G1 -> G1Glasses(app, p.left, p.right)
            }
        device = d
        collectors =
            listOf(
                scope.launch { d.state.collect { stateChanged(it) } },
                scope.launch { d.events.collect { event(it) } },
            )
        return d
    }

    private fun stateChanged(s: GlassesState) {
        // The glasses' own screen while they're up; a while after they're gone, its page goes too.
        if (s.ready) {
            main.removeCallbacks(dropSurface)
            if (surface == null) openSurface()
        } else if (surface != null) {
            main.removeCallbacks(dropSurface)
            main.postDelayed(dropSurface, 60_000)
        }
        changed()
    }

    private fun event(e: GlassesEvent) {
        when (e) {
            is GlassesEvent.Input -> broadcast("glasses.input", JSONObject().put("input", e.input.id).put("side", e.side?.name?.lowercase() ?: JSONObject.NULL))
            is GlassesEvent.Transcript -> broadcast("glasses.transcript", JSONObject().put("text", e.text).put("final", e.final))
            is GlassesEvent.Audio -> {
                val json = JSONObject().put("data", Base64.encodeToString(e.data, Base64.NO_WRAP)).put("codec", e.codec).put("rate", e.sampleRate).put("side", e.side?.name?.lowercase() ?: JSONObject.NULL)
                clients.filter { it.audio }.forEach { it.emit("glasses.audio", json) }
            }
            is GlassesEvent.Worn -> worn(e.worn)
            is GlassesEvent.Battery -> {}
        }
    }

    /** Off the face: the display cleared and nothing pushed; back on: the last text again. */
    private fun worn(on: Boolean) {
        val d = device ?: return
        if (!on && !hidden) {
            hidden = true
            d.clear()
        } else if (on && hidden) {
            hidden = false
            lastText?.let { d.showText(it) }
        }
        changed()
    }

    // --- The display ------------------------------------------------------------------------------------------------

    fun showText(text: String): Boolean {
        val d = device ?: return false
        lastText = text
        return !hidden && d.showText(text)
    }

    /** [encoded] (PNG, JPEG or a data: URL's base64) on the display: converted off the main thread. */
    fun showImage(
        encoded: String,
        dither: Boolean,
    ): Boolean {
        val d = device ?: return false
        if (hidden || !d.state.value.ready || !imageUsable(d)) return false
        thread(name = "powos-glasses-image", isDaemon = true) {
            val img = runCatching { GlassesImages.convert(GlassesImages.bytesOf(encoded), d.model, dither) }.getOrNull()
            if (img == null) Log.w(TAG, "not an image") else d.showImage(img)
        }
        return true
    }

    fun clear(): Boolean {
        lastText = null
        return device?.clear() ?: false
    }

    fun mic(on: Boolean) = device?.setMic(on) ?: false

    private fun imageUsable(d: GlassesDevice) = d.imageVerified || (d.model == GlassesModel.G2 && option("g2Raster"))

    // --- Options ----------------------------------------------------------------------------------------------------

    /** Known options: "g2Raster" - send pixels to the G2 over its [Unverified] render channel. */
    private val OPTIONS = setOf("g2Raster")

    fun option(name: String) = prefs.getBoolean("opt.$name", false)

    fun setOption(
        name: String,
        on: Boolean,
    ) {
        require(name in OPTIONS) { "no such option: $name" }
        prefs.edit().putBoolean("opt.$name", on).apply()
        changed()
    }

    // --- The glasses' screen (the shell's "glasses" page) -----------------------------------------------------------

    private fun openSurface() {
        val a = app as App
        a.runtime.start()
        surface =
            ShellHost(a, null, a.runtime, "glasses").also { h ->
                // Not in a window: given the canvas's size, so the page lays out as it would on screen.
                val m = device?.model ?: GlassesModel.G2
                val px = app.resources.displayMetrics.density
                h.web.layout(0, 0, (m.width * px).toInt(), (m.height * px).toInt())
            }
        Log.i(TAG, "surface page up")
    }

    private fun closeSurface() {
        main.removeCallbacks(dropSurface)
        surface?.destroy()
        surface = null
    }

    // --- State, to pages and to PowOS -------------------------------------------------------------------------------

    fun state(): JSONObject {
        val adapter = app.getSystemService(BluetoothManager::class.java)?.adapter
        val p = paired()
        val d = device
        val s = d?.state?.value
        fun arm(
            address: String?,
            name: String?,
            phase: LinkPhase?,
        ) = address?.let { JSONObject().put("address", it).put("name", name ?: JSONObject.NULL).put("phase", (phase ?: LinkPhase.OFF).name.lowercase()) } ?: JSONObject.NULL
        val model = p?.model
        return JSONObject()
            .put("available", adapter != null)
            .put("enabled", adapter?.isEnabled == true)
            .put("paired", p?.let { JSONObject().put("model", it.model.name).put("pairId", it.pairId) } ?: JSONObject.NULL)
            .put("wanted", prefs.getBoolean("wanted", false))
            .put("phase", when { s == null -> "off"; s.ready -> "ready"; s.connecting -> "connecting"; else -> "off" })
            .put("left", arm(p?.left, p?.leftName, s?.left))
            .put("right", arm(p?.right, p?.rightName, s?.right))
            .put("worn", s?.worn ?: JSONObject.NULL)
            .put("shown", !hidden)
            .put("battery", JSONObject((s?.battery ?: emptyMap()) as Map<*, *>))
            .put("mic", s?.mic == true)
            .put("error", s?.error ?: JSONObject.NULL)
            .put("canvas", model?.let { JSONObject().put("width", it.width).put("height", it.height).put("bits", it.bits) } ?: JSONObject.NULL)
            .put("image", JSONObject().put("verified", model == GlassesModel.G1).put("usable", model == GlassesModel.G1 || (model == GlassesModel.G2 && option("g2Raster"))))
            .put("options", JSONObject().apply { OPTIONS.forEach { put(it, option(it)) } })
    }

    private var pendingChange = false

    /** The state to every page and to PowOS's status file - once per main-thread turn. */
    private fun changed() {
        if (pendingChange) return
        pendingChange = true
        main.post {
            pendingChange = false
            val s = state()
            clients.forEach { it.emit("glasses.state", s) }
            writeStatus(s)
            GlassesService.update(app, s)
        }
    }

    private fun broadcast(
        event: String,
        payload: JSONObject,
    ) = clients.forEach { it.emit(event, payload) }

    private fun writeStatus(s: JSONObject = state()) {
        runCatching {
            val dir = runDir.apply { mkdirs() }
            val tmp = File(dir, ".status.json.tmp")
            tmp.writeText(s.put("time", System.currentTimeMillis() / 1000).toString(2) + "\n")
            tmp.setReadable(true, false)
            tmp.renameTo(File(dir, "status.json"))
        }.onFailure { Log.w(TAG, "status not written", it) }
    }

    // --- PowOS's commands (`powos glasses`) ---------------------------------------------------------------------------

    /**
     * run/glasses/cmd/<id>.json, one command each ({"op": "show", "text": ...} | clear | connect | disconnect | mic), written
     * by `powos glasses` (lib/glasses/powos-glasses) and moved into place whole; done, it's deleted and the outcome is
     * in status.json's "last". A command while the glasses' page is up goes to it ("glasses.message"), so the screen
     * has one owner; without it, straight to the glasses.
     */
    private fun watchCommands() {
        // PowOS's processes run as the app's uid on the phone (root too may write): the folder's own permissions do.
        val dir = File(runDir, "cmd").apply { mkdirs() }
        observer =
            object : FileObserver(dir, MOVED_TO or CLOSE_WRITE) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    if (path == null || !path.endsWith(".json") || path.startsWith(".")) return
                    val f = File(dir, path)
                    main.post { command(f) }
                }
            }.also { it.startWatching() }
        // Ones written while the app wasn't running.
        dir.listFiles { f -> f.name.endsWith(".json") && !f.name.startsWith(".") }?.sortedBy { it.name }?.forEach { f -> main.post { command(f) } }
    }

    private fun command(f: File) {
        if (!f.isFile) return
        val c = runCatching { JSONObject(f.readText()) }.getOrNull()
        f.delete()
        val op = c?.optString("op") ?: return
        val ok =
            when (op) {
                "show" -> {
                    val text = c.optString("text")
                    val surfaces = clients.filter { it.surface }
                    if (surfaces.isNotEmpty()) {
                        val msg = JSONObject().put("text", text).put("seconds", c.optInt("seconds", 30))
                        surfaces.forEach { it.emit("glasses.message", msg) }
                        device?.state?.value?.ready == true
                    } else {
                        showText(text)
                    }
                }
                "clear" -> clear()
                "connect" -> connect()
                "disconnect" -> disconnect().let { true }
                "mic" -> mic(c.optBoolean("on"))
                else -> false
            }
        Log.i(TAG, "powos glasses $op: $ok")
        writeStatus(state().put("last", JSONObject().put("id", f.name.removeSuffix(".json")).put("op", op).put("ok", ok)))
    }

    // --- A page's end of it (ShellBridge) ---------------------------------------------------------------------------

    /** A shell page's "glasses.*" calls, and the "glasses.*" events while it's open. */
    class Client(
        context: Context,
        private val activity: Activity?,
        private val emitter: (String, Any?) -> Unit,
    ) {
        /** This page wants the microphone's audio ("glasses.audio": a lot of events - only to pages that asked). */
        var audio = false
            private set

        /** This page draws the glasses' screen (shell/glasses/surface.tsx): PowOS's messages go to it. */
        var surface = false
            private set

        init {
            init(context)
            clients += this
        }

        fun emit(
            event: String,
            payload: Any?,
        ) = emitter(event, payload)

        fun call(
            method: String,
            a: JSONArray,
        ): Any? =
            when (method) {
                "state" -> state()
                "pair" -> pair(activity)
                "forget" -> forget().let { state() }
                "connect" -> connect()
                "disconnect" -> disconnect().let { state() }
                "showText" -> showText(a.getString(0))
                "showImage" -> showImage(a.getString(0), a.optBoolean(1, true))
                "clear" -> clear()
                "mic" -> mic(a.getBoolean(0))
                "audio" -> a.getBoolean(0).also { audio = it }
                "surface" -> a.getBoolean(0).also { surface = it }
                "reload" -> clients.filter { it.surface }.forEach { it.emit("glasses.reload", null) }
                "option" -> if (a.length() > 1 && !a.isNull(1)) setOption(a.getString(0), a.getBoolean(1)).let { option(a.getString(0)) } else option(a.getString(0))
                else -> throw IllegalArgumentException("no such call: glasses.$method")
            }

        fun close() {
            clients -= this
        }
    }

    /** Companion presence (GlassesPresenceService): a paired arm is in range again - connect if wanted. */
    fun appeared(address: String) {
        val p = paired() ?: return
        if (address != p.left && address != p.right) return
        if (prefs.getBoolean("wanted", false) && device?.state?.value?.ready != true) connect()
    }

    /** Whether Android can show its companion pairing flow here. */
    fun companionAvailable() = Build.VERSION.SDK_INT >= 31 && app.packageManager.hasSystemFeature("android.software.companion_device_setup")
}

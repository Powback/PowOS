package dev.omalauncher.system

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.view.View
import android.view.WindowInsets
import dev.omalauncher.App
import dev.omalauncher.shell.ChromeSlot
import dev.omalauncher.shell.PageWatchdog
import dev.omalauncher.shell.ShellHost
import org.json.JSONObject
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.cancel
import dev.omalauncher.widgets.runtime.MediaListener

/** System data for shell/ui/chrome.tsx. Android keeps system services; the web page owns the visible bar. */
class StatusChrome(private val context: Context, private val changed: () -> Unit, private val open: (Boolean) -> Unit) : ChromeSlot {
    private val host = ShellHost(context, null, (context.applicationContext as App).runtime, "statusbar")
    val web get() = host.web
    var ready = false
        private set
    private val scope = MainScope()
    private val data = JSONObject().put("kind", "status")
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_BATTERY_CHANGED) {
                val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                data.put("battery", if (level >= 0 && scale > 0) level * 100 / scale else JSONObject.NULL)
                data.put("charging", intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0)
            }
            publish()
        }
    }
    private val network = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(n: Network, caps: NetworkCapabilities) { web.post { connection() } }
        override fun onLost(n: Network) { web.post { connection() } }
    }
    private val watchdog = PageWatchdog(web, "PowOS status bar", skip = {
        !context.getSystemService(android.os.PowerManager::class.java).isInteractive
    }) { ready = false; web.visibility = View.INVISIBLE; changed() }

    init {
        host.bridge.chrome = this
        web.visibility = View.INVISIBLE
        @Suppress("DEPRECATION")
        context.registerReceiver(receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED).apply {
            addAction(Intent.ACTION_TIME_TICK)
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
            addAction(Intent.ACTION_LOCALE_CHANGED)
        })
        connectivity.registerDefaultNetworkCallback(network)
        connection()
        scope.launch { MediaListener.changes.collect {
            val count = runCatching { MediaListener.connected?.activeNotifications?.size }.getOrNull()
            data.put("notifications", count ?: JSONObject.NULL)
            publish()
        } }
    }
    override fun state() = data
    override fun ready() {
        ready = true
        changed()
        watchdog.start()
    }
    /**
     * The page's own controls on the strip (chrome.regions: every [data-action] element - the clock, the indicators,
     * the FPS meter), display px: the strip is touchable only there ([ShadeHost] edgeRegion).
     */
    var controls: List<android.graphics.Rect> = emptyList()
        private set

    override fun regions(regions: org.json.JSONArray) {
        val d = context.resources.displayMetrics.density
        val list =
            (0 until regions.length()).mapNotNull { i ->
                regions.optJSONObject(i)?.let { r ->
                    val x = r.optDouble("x").toFloat() * d
                    val y = r.optDouble("y").toFloat() * d
                    android.graphics.Rect(x.toInt(), y.toInt(), Math.round(x + r.optDouble("width").toFloat() * d), Math.round(y + r.optDouble("height").toFloat() * d))
                }
            }.filter { !it.isEmpty }
        web.post {
            if (list == controls) return@post
            controls = list
            web.rootView.requestLayout()
        }
    }

    /**
     * A maximised web window's bar under the strip (TB1): the title ends at [titleEnd] and the window's controls start
     * at [controlsStart] (display px; null: no merge). The page lays the clock out after the title and the indicators
     * before the controls ("mergeLeft"/"mergeRight", CSS px from each side).
     */
    private var merged: Pair<Int?, Int?> = null to null

    fun merge(
        titleEnd: Int?,
        controlsStart: Int?,
    ) {
        if (merged == titleEnd to controlsStart) return
        merged = titleEnd to controlsStart
        val d = context.resources.displayMetrics.density
        val width = context.resources.displayMetrics.widthPixels
        val left = titleEnd?.let { it / d }
        val right = controlsStart?.let { (width - it) / d }
        if (left != null) data.put("mergeLeft", left.toDouble()) else data.remove("mergeLeft")
        if (right != null) data.put("mergeRight", right.toDouble()) else data.remove("mergeRight")
        publish()
    }

    override fun action(name: String) { when (name) { "notifications" -> open(false); "controls" -> open(true) } }
    private fun connection() {
        val caps = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        val kind = when {
            caps == null -> "offline"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> null
        }
        data.put("network", kind ?: JSONObject.NULL)
        data.put("vpn", caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true)
        publish()
    }
    fun insets(insets: WindowInsets) {
        val cutout = insets.displayCutout
        val width = context.resources.displayMetrics.widthPixels
        val d = context.resources.displayMetrics.density
        val left = cutout?.boundingRects?.filter { it.left < width / 3 }?.maxOfOrNull { it.right } ?: 0
        val right = cutout?.boundingRects?.filter { it.right > width * 2 / 3 }?.maxOfOrNull { width - it.left } ?: 0
        data.put("left", (maxOf(left, cutout?.safeInsetLeft ?: 0) / d) + 8)
        data.put("right", (maxOf(right, cutout?.safeInsetRight ?: 0) / d) + 8)
        // A punch-hole in the middle third (the folded cover screen's camera) sat on the centred FPS meter, so the
        // meter "wasn't there" (the user, 2026-10-28). chrome.tsx keeps the meter left of it.
        val hole = cutout?.boundingRects?.filter { it.left >= width / 3 && it.right <= width * 2 / 3 }?.minByOrNull { it.left }
        if (hole != null) data.put("holeLeft", hole.left / d) else data.remove("holeLeft")
        publish()
    }
    private fun publish() {
        data.put("clock", android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date()))
        host.bridge.emit("chrome.changed", data)
    }
    fun destroy() {
        watchdog.stop()
        scope.cancel()
        context.unregisterReceiver(receiver)
        connectivity.unregisterNetworkCallback(network)
        host.destroy()
    }
}

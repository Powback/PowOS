package dev.omalauncher.shell

import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityOptions
import android.app.PendingIntent
import android.app.Presentation
import android.app.UiModeManager
import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.PixelFormat
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.UserHandle
import android.os.UserManager
import android.util.Log
import android.util.LruCache
import android.util.SizeF
import android.util.SparseIntArray
import android.view.Display
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.AbsListView
import android.widget.AdapterViewAnimator
import android.widget.FrameLayout
import android.widget.RemoteViews
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.graphics.toArgb
import dev.omalauncher.App
import dev.omalauncher.ui.Palette
import dev.omalauncher.widgets.Cell
import dev.omalauncher.widgets.GRID_COLUMNS
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import org.lsposed.hiddenapibypass.HiddenApiBypass
import java.io.ByteArrayOutputStream
import java.lang.reflect.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * Android app widgets - any app's AppWidgetProvider (Hue's light switch, a weather card, a music player) - as tiles on
 * the web shell's home, live: they redraw as the app updates them, and a tap on one is a tap on the widget.
 *
 * The page stays in charge (docs/NATIVE-SYSTEM-UI.md, one UI codebase): a widget is RemoteViews inflated into native
 * views, which can't be a DOM element, and a native view laid over the page would be outside it - not clipped, moved or
 * faded with its tile, not under the page's swipes and edit mode. So each widget is hosted off screen, as the widget
 * recon does it ([dev.omalauncher.widgets.recon.WidgetRecon]'s Offscreen): an AppWidgetHostView in a Presentation on a
 * private VirtualDisplay exactly the tile's size, drawn into an ImageReader. Its frames go to the page as images
 * (ShellHost serves the latest at /_appwidget/<id>, "appwidgets.frame" says when it changed); the page's touches on
 * the tile come back as MotionEvents dispatched into the hosted view, so its buttons press, ripple and click as on any
 * launcher. The tile is an <img> in the grid, moved, resized and removed like PowOS's own widgets.
 *
 * Placement is the home's: each widget's cell is in the same WidgetLayout as every other home item (key "aw:<id>"),
 * its page and provider in this class's preferences, and home.get lists them with the rest ([merge]).
 *
 * Themed as on a Pixel launcher: the system palette widgets draw with (system_accent1_0..system_neutral2_1000, and
 * Android 14's Material tokens) is PowOS's theme's, set on each hosted view (setColorResources), and the app is in
 * the theme's light or dark - widgets pick their night resources from it. The page clips each to PowOS's corners.
 *
 * Binding: PowOS doesn't hold BIND_APPWIDGET (signature|privileged: it would have to be on the system module's
 * privapp allowlist, and a privileged permission the manifest asks for that isn't there stops the phone booting), so
 * the first widget shows Android's "allow PowOS to create widgets" dialog (ACTION_APPWIDGET_BIND, [BindActivity]);
 * ticking "always allow" makes later ones silent. Then the widget's own setup screen, when it has one.
 *
 * Main thread, except what ShellHost's loader thread reads: [framePng] and [previewPng].
 */
class AppWidgets private constructor(
    context: Context,
) {
    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val awm = AppWidgetManager.getInstance(this.context)
    private val users = this.context.getSystemService(UserManager::class.java)
    private val prefs = this.context.getSharedPreferences("appwidgets", Context.MODE_PRIVATE)
    internal val host = AppWidgetHost(this.context, HOST_ID)
    private val layout get() = (context as App).runtime.widgets.layout

    /** A widget on home: its id (the system's), provider and page; its cell is the layout's. */
    private class Entry(
        val id: Int,
        val provider: ComponentName,
        /** Its profile's serial number (UserManager), so it survives reboots. */
        val profile: Long,
        var page: Int,
    )

    private val entries = ArrayList<Entry>()

    /** Widgets being added: bound (or waiting for the user to allow it), maybe set up, not on home yet. */
    private class Pending(
        val info: AppWidgetProviderInfo,
        val page: Int,
        val cell: Cell,
    )

    private val pending = HashMap<Int, Pending>()

    /** The pages' event channels (each ShellBridge's emit), and which widgets each one shows. */
    private val listeners = LinkedHashMap<(String, Any?) -> Unit, MutableSet<Int>>()

    private val renderers = HashMap<Int, Renderer>()

    /** Each widget's latest frame and its number, read by ShellHost's loader thread. */
    private val frames = ConcurrentHashMap<Int, Bitmap>()
    private val stamps = HashMap<Int, Long>()
    private var listening = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    init {
        load()
        theme()
        // PowOS's theme picked or recolored: widgets redraw in it.
        scope.launch {
            snapshotFlow { Palette.current.let { listOf(it.background, it.surface, it.foreground, it.muted, it.accent, it.border, it.isLight, it.named["color5"]).toString() } }
                .drop(1)
                .collect { theme() }
        }
        // A widget being added when the launcher died stays bound to us, owned by nothing: let it go.
        val kept = entries.map { it.id }.toSet()
        runCatching { host.appWidgetIds.filter { it !in kept }.forEach(host::deleteAppWidgetId) }
    }

    // The page's channel.

    fun listen(events: (String, Any?) -> Unit) {
        listeners.getOrPut(events) { HashSet() }
    }

    fun unlisten(events: (String, Any?) -> Unit) {
        listeners.remove(events)
        updateListening()
    }

    private fun emitAll(
        event: String,
        payload: Any?,
    ) = listeners.keys.toList().forEach { it(event, payload) }

    // Providers: the picker.

    /** Every widget the phone's apps offer for a home screen, in every profile we see. */
    private fun allProviders(): List<AppWidgetProviderInfo> =
        users.userProfiles
            .flatMap { p -> runCatching { awm.getInstalledProvidersForProfile(p) }.getOrDefault(emptyList()) }
            .filter { it.widgetCategory and AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN != 0 }

    /** A provider's name for the page: its component, and the profile's serial number after '#'. */
    private fun name(info: AppWidgetProviderInfo) = "${info.provider.flattenToString()}#${users.getSerialNumberForUser(info.profile)}"

    private fun provider(name: String): AppWidgetProviderInfo? {
        val component = ComponentName.unflattenFromString(name.substringBefore('#')) ?: return null
        val serial = name.substringAfter('#', "").toLongOrNull()
        return allProviders().firstOrNull { it.provider == component && (serial == null || users.getSerialNumberForUser(it.profile) == serial) }
    }

    /**
     * The picker's list: [{ provider, label, app, package, description, sizeDp, minDp, configure, preview }], sizes in
     * dp - the size a launcher would first give it, and the smallest it may be made.
     */
    fun providers(): JSONArray {
        val pm = context.packageManager
        val me = android.os.Process.myUserHandle()
        return JSONArray(
            allProviders().map { info ->
                val (w, h) = defaultSizeDp(info)
                val (mw, mh) = minSizeDp(info)
                val app = runCatching { pm.getApplicationLabel(pm.getApplicationInfo(info.provider.packageName, 0)).toString() }.getOrDefault(info.provider.packageName)
                JSONObject()
                    .put("provider", name(info))
                    .put("label", info.loadLabel(pm) ?: app)
                    .put("app", app)
                    .put("package", info.provider.packageName)
                    .put("work", info.profile != me)
                    .put("description", if (Build.VERSION.SDK_INT >= 31) info.loadDescription(context)?.toString() ?: JSONObject.NULL else JSONObject.NULL)
                    .put("sizeDp", JSONArray(listOf(w, h)))
                    .put("minDp", JSONArray(listOf(mw, mh)))
                    .put("configure", needsConfigure(info))
                    .put("preview", "${ShellHost.ORIGIN}/_awpreview/${Uri.encode(name(info))}")
            },
        )
    }

    // Adding one.

    /**
     * Adds [providerName]'s widget at [cell] on [page], [wDp] x [hDp] big: bound at once if Android lets us, else after
     * the user allows it, then set up in its own screen if it has one. "added" (on home now), "pending" (a screen asks
     * the user first; home.changed brings it, "appwidgets.failed" says it didn't happen) or "failed".
     */
    fun add(
        providerName: String,
        page: Int,
        cell: JSONObject,
        wDp: Double,
        hDp: Double,
    ): String {
        val info = provider(providerName) ?: error("no widget provider $providerName")
        val id = host.allocateAppWidgetId()
        pending[id] = Pending(info, page, Cell(cell.getInt("x"), cell.getInt("y"), cell.getInt("w"), cell.getInt("h")))
        val options = sizeOptions(wDp.roundToInt(), hDp.roundToInt())
        return try {
            if (awm.bindAppWidgetIdIfAllowed(id, info.profile, info.provider, options)) {
                if (needsConfigure(info)) {
                    ask(BindActivity.CONFIGURE, id, info, options)
                    "pending"
                } else {
                    added(id)
                    "added"
                }
            } else {
                ask(BindActivity.BIND, id, info, options)
                "pending"
            }
        } catch (e: Exception) {
            Log.w(TAG, "can't add ${info.provider}", e)
            answered(id, false)
            "failed"
        }
    }

    internal fun needsConfigure(id: Int) = pending[id]?.info?.let(::needsConfigure) ?: false

    private fun needsConfigure(info: AppWidgetProviderInfo) =
        info.configure != null && !(Build.VERSION.SDK_INT >= 31 && info.widgetFeatures and AppWidgetProviderInfo.WIDGET_FEATURE_CONFIGURATION_OPTIONAL != 0)

    private fun ask(
        mode: String,
        id: Int,
        info: AppWidgetProviderInfo,
        options: Bundle,
    ) {
        context.startActivity(
            Intent(context, BindActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(BindActivity.MODE, mode)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER, info.provider)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER_PROFILE, info.profile)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_OPTIONS, options),
        )
    }

    /** [BindActivity]'s answer: allowed and set up (it goes on home), or not (the id is given back). */
    internal fun answered(
        id: Int,
        ok: Boolean,
    ) {
        if (ok && id in pending) return added(id)
        val p = pending.remove(id)
        runCatching { host.deleteAppWidgetId(id) }
        emitAll("appwidgets.failed", JSONObject().put("provider", p?.let { name(it.info) } ?: JSONObject.NULL))
    }

    private fun added(id: Int) {
        val p = pending.remove(id) ?: return
        entries += Entry(id, p.info.provider, users.getSerialNumberForUser(p.info.profile), p.page)
        save()
        layout.set(key(id), p.cell)
        layout.save()
        emitAll("home.changed", null)
    }

    // On home.

    /** [snapshot] (ShellHome's home.get) with these widgets in it: items of kind "appwidget", their pages too. */
    fun merge(snapshot: JSONObject): JSONObject {
        val items = snapshot.getJSONArray("items")
        val pages = (0 until snapshot.getJSONArray("pages").length()).map { snapshot.getJSONArray("pages").getInt(it) }.toMutableSet()
        val pm = context.packageManager
        // An estimate of the grid's cells for minSize; the page has the real ones (appWidget.minDp, grid.tsx).
        val cellDp = context.resources.configuration.screenWidthDp.toDouble() / GRID_COLUMNS
        for (e in entries) {
            val info = awm.getAppWidgetInfo(e.id)
            val (mw, mh) = info?.let(::minSizeDp) ?: (1 to 1)
            val label = info?.loadLabel(pm) ?: e.provider.packageName
            items.put(
                JSONObject()
                    .put("key", key(e.id))
                    .put("kind", "appwidget")
                    .put("page", e.page)
                    // Always a sized tile (not an app's 1x1); which sides move is appWidget.resize.
                    .put("resizable", true)
                    .put("minSize", JSONArray(listOf(ceil(mw / cellDp).toInt().coerceIn(1, GRID_COLUMNS), ceil(mh / cellDp).toInt().coerceAtLeast(1))))
                    .putOpt("cell", layout.cell(key(e.id))?.let { JSONObject().put("x", it.x).put("y", it.y).put("w", it.w).put("h", it.h) })
                    .put("name", label)
                    .putOpt("error", if (info == null) "${e.provider.packageName} is gone" else null)
                    .put(
                        "appWidget",
                        JSONObject()
                            .put("id", e.id)
                            .put("provider", e.provider.flattenToString())
                            .put("package", e.provider.packageName)
                            .put("minDp", JSONArray(listOf(mw, mh)))
                            .put("resize", info?.let(::resizeAxes) ?: "both")
                            .put("reconfigurable", info != null && Build.VERSION.SDK_INT >= 31 && info.configure != null && info.widgetFeatures and AppWidgetProviderInfo.WIDGET_FEATURE_RECONFIGURABLE != 0),
                    ),
            )
            pages += e.page
        }
        return snapshot.put("pages", JSONArray(pages.sorted()))
    }

    fun owns(key: String) = key.startsWith(PREFIX)

    private fun entry(key: String) = entries.firstOrNull { key(it.id) == key }

    /** Moves or resizes one (home.place). */
    fun place(
        key: String,
        cell: JSONObject,
        page: Int,
    ) {
        val e = entry(key) ?: error("no home item $key")
        layout.set(key, Cell(cell.getInt("x"), cell.getInt("y"), cell.getInt("w"), cell.getInt("h")))
        layout.save()
        if (e.page != page) {
            e.page = page
            save()
        }
        emitAll("home.changed", null)
    }

    /** Takes one off home (home.remove): the widget is deleted, as a launcher does. */
    fun remove(key: String) {
        val e = entry(key) ?: return
        entries.remove(e)
        save()
        renderers.remove(e.id)?.close()
        frames.remove(e.id)
        listeners.values.forEach { it.remove(e.id) }
        runCatching { host.deleteAppWidgetId(e.id) }
        layout.remove(key)
        emitAll("home.changed", null)
        updateListening()
    }

    /** Opens its setup screen again (a reconfigurable widget's "settings"). */
    fun reconfigure(id: Int) {
        val info = awm.getAppWidgetInfo(id) ?: return
        context.startActivity(
            Intent(context, BindActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(BindActivity.MODE, BindActivity.RECONFIGURE)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER, info.provider),
        )
    }

    // Shown: rendered off screen, frames to the page, touches back.

    /**
     * A page shows [id] at [wDp] x [hDp] (its tile, CSS px = dp): it's drawn at that size (made again if the size
     * changed - the provider hears of it, OPTION_APPWIDGET_SIZES) and the provider's updates are listened to. Answers
     * { url: the latest frame's, if there is one; scrolls }; "appwidgets.frame" brings each next.
     */
    fun watch(
        events: (String, Any?) -> Unit,
        id: Int,
        wDp: Double,
        hDp: Double,
    ): JSONObject? {
        val e = entries.firstOrNull { it.id == id } ?: return null
        val info = awm.getAppWidgetInfo(e.id) ?: return null
        listeners.getOrPut(events) { HashSet() } += id
        updateListening()
        // Exactly the tile, in the screen's pixels (CSS px are dp here: the WebView's pixel ratio is the density), and
        // that size in dp to the provider: the widget decides what fits, as on a launcher, and the page shows the
        // frame 1:1.
        val d = context.resources.displayMetrics.density
        val w = (wDp * d).roundToInt().coerceIn(1, 4096)
        val h = (hDp * d).roundToInt().coerceIn(1, 4096)
        val r = renderers[id]
        if (r == null || r.w != w || r.h != h) {
            r?.close()
            awm.updateAppWidgetOptions(id, sizeOptions(wDp.roundToInt(), hDp.roundToInt()))
            renderers[id] = Renderer(info, w, h, bound = id) { frame(id, it) }
        }
        return JSONObject().put("url", frameUrl(id) ?: JSONObject.NULL).put("scrolls", renderers[id]?.scrolls == true)
    }

    fun unwatch(
        events: (String, Any?) -> Unit,
        id: Int,
    ) {
        listeners[events]?.remove(id)
        updateListening()
    }

    /**
     * The provider's updates come while a page shows one of its widgets, and stop with the last (as a launcher stops
     * listening when it isn't on screen); what changed meanwhile comes when it listens again.
     */
    private fun updateListening() {
        val want = listeners.values.any { it.isNotEmpty() }
        if (want == listening) return
        listening = want
        runCatching { if (want) host.startListening() else host.stopListening() }.onFailure { Log.w(TAG, "listening $want", it) }
    }

    private fun frame(
        id: Int,
        bitmap: Bitmap,
    ) {
        frames[id] = bitmap
        stamps[id] = (stamps[id] ?: 0) + 1
        val payload = JSONObject().put("id", id).put("url", frameUrl(id)).put("scrolls", renderers[id]?.scrolls == true)
        for ((events, shown) in listeners.entries.toList()) if (id in shown) events("appwidgets.frame", payload)
    }

    private fun frameUrl(id: Int) = stamps[id]?.let { "${ShellHost.ORIGIN}/_appwidget/$id?v=$it" }

    /** The latest frame of [id] as PNG (ShellHost's loader thread). */
    fun framePng(id: Int): ByteArray? = frames[id]?.let(::png)

    /**
     * A touch on the tile, at ([x], [y]) in a tile [wCss] x [hCss] CSS px big: "down", "move", "up" or "cancel" (the
     * page took the gesture: a page swipe, the tile lifted). Dispatched into the hosted view at its scale, so the
     * widget sees what a launcher's view would.
     */
    fun touch(
        id: Int,
        action: String,
        x: Double,
        y: Double,
        wCss: Double,
        hCss: Double,
    ) {
        val r = renderers[id] ?: return
        val now = SystemClock.uptimeMillis()
        if (action == "down") r.downAt = now
        val a =
            when (action) {
                "down" -> MotionEvent.ACTION_DOWN
                "move" -> MotionEvent.ACTION_MOVE
                "up" -> MotionEvent.ACTION_UP
                else -> MotionEvent.ACTION_CANCEL
            }
        val px = (x * r.w / wCss.coerceAtLeast(1.0)).toFloat()
        val py = (y * r.h / hCss.coerceAtLeast(1.0)).toFloat()
        val ev = MotionEvent.obtain(r.downAt, now, a, px, py, 0)
        ev.source = InputDevice.SOURCE_TOUCHSCREEN
        r.root.dispatchTouchEvent(ev)
        ev.recycle()
    }

    /**
     * HACK: a widget's clicks go through RemoteViews' interaction handler, and its default launches the click's
     * activity on the view's display (RemoteResponse.getLaunchOptions sets setLaunchDisplayId(view.getDisplay())) - for
     * us the private virtual display it's drawn on, where nothing can be seen (or Android refuses it). The handler
     * (RemoteViews.InteractionHandler, AppWidgetHostView.setInteractionHandler, getLaunchOptions) is hidden API, so
     * it's set through reflection, with the hidden API checks lifted for those classes, and the launch goes to the
     * phone's screen instead. Real fix: none for a launcher without the platform's own (Launcher3 is built against
     * the hidden API); a public "launch on this display" option for AppWidgetHostView would be.
     */
    private fun interactions(view: AppWidgetHostView) {
        runCatching {
            HiddenApiBypass.addHiddenApiExemptions("Landroid/widget/RemoteViews", "Landroid/appwidget/AppWidgetHostView")
            val type = Class.forName("android.widget.RemoteViews\$InteractionHandler")
            val handler =
                Proxy.newProxyInstance(type.classLoader, arrayOf(type)) { proxy, method, args ->
                    when (method.name) {
                        "onInteraction" -> click(args[0] as View, args[1] as PendingIntent, args[2])
                        "equals" -> proxy === args?.getOrNull(0)
                        "hashCode" -> System.identityHashCode(proxy)
                        else -> "AppWidgets.InteractionHandler"
                    }
                }
            AppWidgetHostView::class.java.getMethod("setInteractionHandler", type).invoke(view, handler)
        }.onFailure { Log.w(TAG, "can't set the widgets' click handler; their activities may not open", it) }
    }

    /** A click's PendingIntent, sent as RemoteViews would, but launching on the phone's screen. */
    private fun click(
        view: View,
        pendingIntent: PendingIntent,
        response: Any?,
    ): Boolean {
        // Its fill-in intent (a list item's) and options, as RemoteViews makes them.
        @Suppress("UNCHECKED_CAST")
        val launch =
            runCatching { response?.javaClass?.getMethod("getLaunchOptions", View::class.java)?.invoke(response, view) as? android.util.Pair<Intent?, ActivityOptions?> }
                .onFailure { Log.w(TAG, "getLaunchOptions", it) }
                .getOrNull()
        val options = launch?.second ?: ActivityOptions.makeBasic()
        options.setLaunchDisplayId(Display.DEFAULT_DISPLAY)
        // Android 14+: the widget's tap is the user's, so its app may open its screen (as RemoteViews allows it).
        if (Build.VERSION.SDK_INT >= 34) {
            @Suppress("DEPRECATION")
            options.setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
        }
        return runCatching {
            context.startIntentSender(pendingIntent.intentSender, launch?.first, 0, 0, 0, options.toBundle())
            true
        }.onFailure { Log.w(TAG, "widget click failed", it) }.getOrDefault(false)
    }

    private fun hasCollection(v: View): Boolean =
        v is AbsListView || v is AdapterViewAnimator || (v is ViewGroup && (0 until v.childCount).any { hasCollection(v.getChildAt(it)) })

    // The theme.

    /** The system palette in PowOS's colors, for setColorResources (Android 12+); null before. */
    private var colors: SparseIntArray? = null

    /** PowOS's theme onto the widgets: their palette, and light or dark. */
    private fun theme() {
        if (Build.VERSION.SDK_INT < 31) return
        val p = Palette.current
        colors = WidgetColors.build(context, p.background.toArgb(), p.surface.toArgb(), p.foreground.toArgb(), p.muted.toArgb(), p.accent.toArgb(), p.border.toArgb(), p.named["color5"]?.toArgb(), p.isLight)
        renderers.values.forEach { r -> colors?.let(r.view::setColorResources) }
        // Widgets choose their night resources from the app's configuration (their package context is made from it,
        // not from a context we could override), so the app follows the theme: dark theme, night mode. Only when it
        // differs from what the app has now: the system's own (most of the time the same) stays otherwise.
        val night = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        if (night == p.isLight) {
            runCatching {
                context.getSystemService(UiModeManager::class.java).setApplicationNightMode(if (p.isLight) UiModeManager.MODE_NIGHT_NO else UiModeManager.MODE_NIGHT_YES)
            }.onFailure { Log.w(TAG, "can't set the app's night mode", it) }
        }
    }

    // Previews, for the picker.

    private val previews = LruCache<String, ByteArray>(48)
    private val previewLock = Any()

    /**
     * [providerName]'s picture for the picker, PNG (ShellHost's loader thread): its preview image, else its generated
     * preview (Android 15+) or preview layout drawn off screen, else its app's icon.
     */
    fun previewPng(providerName: String): ByteArray? {
        previews.get(providerName)?.let { return it }
        synchronized(previewLock) {
            previews.get(providerName)?.let { return it }
            val info = provider(providerName) ?: return null
            val dpi = context.resources.displayMetrics.densityDpi
            val (wDp, hDp) = defaultSizeDp(info)
            val d = context.resources.displayMetrics.density
            val w = (wDp * d).roundToInt()
            val h = (hDp * d).roundToInt()
            val bitmap =
                runCatching { info.loadPreviewImage(context, dpi) }.getOrNull()?.let { bitmap(it, w, h) }
                    ?: drawn(info, w, h)
                    ?: runCatching { info.loadIcon(context, dpi) }.getOrNull()?.let { bitmap(it, w, h) }
                    ?: return null
            return png(bitmap).also { previews.put(providerName, it) }
        }
    }

    /** The provider's generated preview or preview layout, drawn off screen (on the main thread; waited for here). */
    private fun drawn(
        info: AppWidgetProviderInfo,
        w: Int,
        h: Int,
    ): Bitmap? {
        val views =
            (if (Build.VERSION.SDK_INT >= 35 && info.generatedPreviewCategories and AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN != 0) runCatching { awm.getWidgetPreview(info.provider, info.profile, AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN) }.getOrNull() else null)
                ?: if (Build.VERSION.SDK_INT >= 31 && info.previewLayout != 0) RemoteViews(info.provider.packageName, info.previewLayout) else null
                ?: return null
        var result: Bitmap? = null
        val done = CountDownLatch(1)
        main.post {
            var r: Renderer? = null
            val timeout = Runnable { r?.close(); done.countDown() }
            r =
                runCatching {
                    Renderer(info, w, h, preview = views) { frame ->
                        result = frame
                        // The first frame can be the views before their images arrive: the one after settling.
                        main.removeCallbacks(timeout)
                        main.postDelayed(timeout, PREVIEW_SETTLE_MS)
                    }
                }.onFailure { Log.w(TAG, "preview of ${info.provider}", it) }.getOrNull()
            if (r == null) done.countDown() else main.postDelayed(timeout, PREVIEW_TIMEOUT_MS)
        }
        done.await(PREVIEW_TIMEOUT_MS + 1000, TimeUnit.MILLISECONDS)
        return result
    }

    private fun bitmap(
        d: Drawable,
        maxW: Int,
        maxH: Int,
    ): Bitmap {
        val iw = d.intrinsicWidth.takeIf { it > 0 } ?: maxW
        val ih = d.intrinsicHeight.takeIf { it > 0 } ?: maxH
        val scale = minOf(1f, maxOf(maxW, 256).toFloat() / iw, maxOf(maxH, 256).toFloat() / ih)
        val b = Bitmap.createBitmap((iw * scale).roundToInt().coerceAtLeast(1), (ih * scale).roundToInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, b.width, b.height)
        d.draw(Canvas(b))
        return b
    }

    private fun png(b: Bitmap) = ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()

    /**
     * One widget drawn off screen: a private virtual display its size with a Presentation on it, so it's attached and
     * drawn exactly as on a home screen (collections load, hardware bitmaps draw) - WidgetRecon's Offscreen, kept
     * running. [bound]: the widget's id (its views are the provider's, live); else [preview] is drawn once. It's drawn
     * exactly [w] x [h] px, the tile's size in the screen's pixels, so the page shows each frame 1:1.
     */
    private inner class Renderer(
        info: AppWidgetProviderInfo,
        val w: Int,
        val h: Int,
        bound: Int? = null,
        preview: RemoteViews? = null,
        private val onFrame: (Bitmap) -> Unit,
    ) {
        private val reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3)
        private val display: VirtualDisplay =
            context.getSystemService(DisplayManager::class.java)
                .createVirtualDisplay("powos-appwidget-${bound ?: "preview"}", w, h, context.resources.displayMetrics.densityDpi, reader.surface, 0)
        private val presentation = Presentation(context, display.display)
        val root: FrameLayout
        val view: AppWidgetHostView
        var downAt = 0L

        /** Its views have a collection (a list, a grid, a stack): its drags are its own, to scroll it. */
        var scrolls = false
            private set
        private var latest: Image? = null
        private var queued = false
        private var closed = false

        init {
            presentation.window?.setBackgroundDrawable(ColorDrawable(android.graphics.Color.TRANSPARENT))
            view =
                if (bound != null) {
                    host.createView(presentation.context, bound, info).also(::interactions)
                } else {
                    AppWidgetHostView(presentation.context).apply { setAppWidget(AppWidgetManager.INVALID_APPWIDGET_ID, info) }
                }
            colors?.let { if (Build.VERSION.SDK_INT >= 31) view.setColorResources(it) }
            root = FrameLayout(presentation.context).apply { addView(view, FrameLayout.LayoutParams(w, h)) }
            // A frame each time it draws: held (one of the reader's three), turned into a bitmap at most every FRAME_MS.
            reader.setOnImageAvailableListener({ r ->
                r.acquireLatestImage()?.let { image ->
                    latest?.close()
                    latest = image
                    if (!queued) {
                        queued = true
                        main.postDelayed(::copy, FRAME_MS)
                    }
                }
            }, main)
            presentation.setContentView(root, ViewGroup.LayoutParams(w, h))
            presentation.show()
            if (preview != null) view.updateAppWidget(preview)
        }

        private fun copy() {
            queued = false
            if (closed) return
            val image = latest ?: return
            val plane = image.planes[0]
            val full = Bitmap.createBitmap(plane.rowStride / plane.pixelStride, h, Bitmap.Config.ARGB_8888)
            plane.buffer.rewind()
            full.copyPixelsFromBuffer(plane.buffer)
            scrolls = hasCollection(view)
            onFrame(if (full.width == w) full else Bitmap.createBitmap(full, 0, 0, w, h).also { full.recycle() })
        }

        fun close() {
            if (closed) return
            closed = true
            runCatching { presentation.dismiss() }
            display.release()
            latest?.close()
            latest = null
            reader.close()
        }
    }

    // Sizes.

    /**
     * A cell of the stock launcher this screen would have: 4 columns on a phone-wide screen (the cover's ~400 dp:
     * ~97 dp cells), 6 on a tablet-wide one (unfolded), never under Android's guide's 73 dp. Widgets are designed for
     * those; PowOS's own grid is finer (6 columns), so sizing them in its cells drew them cramped.
     */
    private fun stockCellDp(): Int {
        val w = context.resources.configuration.screenWidthDp
        return maxOf(CELL_DP, (w - 16) / (if (w >= 600) 6 else 4))
    }

    /**
     * The size a stock launcher would first give it, dp: its target cells (Android 12+), else the cells its minimum
     * size takes by Android's sizing guide (73 dp a cell, less 16 dp of margins), in this screen's stock cells.
     */
    private fun defaultSizeDp(info: AppWidgetProviderInfo): Pair<Int, Int> {
        val d = context.resources.displayMetrics.density
        var w = (info.minWidth / d).roundToInt()
        var h = (info.minHeight / d).roundToInt()
        var cw = ceil((w + 16) / CELL_DP.toDouble()).toInt().coerceAtLeast(1)
        var ch = ceil((h + 16) / CELL_DP.toDouble()).toInt().coerceAtLeast(1)
        if (Build.VERSION.SDK_INT >= 31) {
            if (info.targetCellWidth > 0) cw = info.targetCellWidth
            if (info.targetCellHeight > 0) ch = info.targetCellHeight
        }
        val cell = stockCellDp()
        w = maxOf(w, cell * cw - 16)
        h = maxOf(h, cell * ch - 16)
        // Some OEM widgets declare a minimum wider than the phone (OnePlus's clocks: 610 dp); a home screen clamps it.
        val screen = context.resources.configuration.smallestScreenWidthDp - 16
        return maxOf(minOf(w, screen), 40) to maxOf(minOf(h, screen * 2), 40)
    }

    /** The smallest it may be made, dp: its minimum resize size (minResizeWidth/Height), else its minimum size. */
    private fun minSizeDp(info: AppWidgetProviderInfo): Pair<Int, Int> {
        val d = context.resources.displayMetrics.density
        val screen = context.resources.configuration.smallestScreenWidthDp - 16
        val w = if (info.minResizeWidth > 0) minOf(info.minResizeWidth, info.minWidth.takeIf { it > 0 } ?: Int.MAX_VALUE) else info.minWidth
        val h = if (info.minResizeHeight > 0) minOf(info.minResizeHeight, info.minHeight.takeIf { it > 0 } ?: Int.MAX_VALUE) else info.minHeight
        return minOf((w / d).roundToInt(), screen).coerceAtLeast(1) to minOf((h / d).roundToInt(), screen * 2).coerceAtLeast(1)
    }

    /**
     * Which sides of its tile move: its resizeMode's. One that declares none still resizes both ways here: it was
     * made for a stock launcher's cells, which PowOS's (finer) aren't - kept at a stock cell's size it's a 2x2 PowOS
     * can't make smaller (Hue's switch) - and it lays out for whatever size it's given.
     */
    private fun resizeAxes(info: AppWidgetProviderInfo) =
        when (info.resizeMode and (AppWidgetProviderInfo.RESIZE_HORIZONTAL or AppWidgetProviderInfo.RESIZE_VERTICAL)) {
            AppWidgetProviderInfo.RESIZE_HORIZONTAL -> "horizontal"
            AppWidgetProviderInfo.RESIZE_VERTICAL -> "vertical"
            else -> "both"
        }

    private fun sizeOptions(
        wDp: Int,
        hDp: Int,
    ) = Bundle().apply {
        putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, wDp)
        putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, wDp)
        putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, hDp)
        putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, hDp)
        putInt(AppWidgetManager.OPTION_APPWIDGET_HOST_CATEGORY, AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN)
        if (Build.VERSION.SDK_INT >= 31) putParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, arrayListOf(SizeF(wDp.toFloat(), hDp.toFloat())))
    }

    // Saved.

    private fun load() {
        val array = runCatching { JSONArray(prefs.getString(ENTRIES, "[]")) }.getOrDefault(JSONArray())
        for (i in 0 until array.length()) {
            val o = array.optJSONObject(i) ?: continue
            val c = ComponentName.unflattenFromString(o.optString("provider")) ?: continue
            entries += Entry(o.getInt("id"), c, o.optLong("profile"), o.optInt("page", 1))
        }
    }

    private fun save() {
        val array = JSONArray(entries.map { JSONObject().put("id", it.id).put("provider", it.provider.flattenToString()).put("profile", it.profile).put("page", it.page) })
        prefs.edit().putString(ENTRIES, array.toString()).apply()
    }

    companion object {
        private const val TAG = "PowosAppWidgets"
        private const val ENTRIES = "entries"

        /** Unique within the app: the recon's host is 0x504f57 (and deletes everything bound to it). */
        const val HOST_ID = 0x504f58

        /** Home item keys: "aw:<widget id>". */
        const val PREFIX = "aw:"

        fun key(id: Int) = "$PREFIX$id"

        /** At most a frame a display frame goes to the page (a list scrolling, a ripple); it asks for each when shown. */
        private const val FRAME_MS = 16L
        private const val PREVIEW_SETTLE_MS = 400L
        private const val PREVIEW_TIMEOUT_MS = 2500L

        /** Android's widget sizing guide: a cell is about 73 dp, minus 16 dp of margins overall. */
        private const val CELL_DP = 73

        @SuppressLint("StaticFieldLeak") // The application context.
        @Volatile private var instance: AppWidgets? = null

        @Synchronized
        fun get(context: Context): AppWidgets = instance ?: AppWidgets(context).also { instance = it }
    }

    /**
     * The screens adding a widget needs the user for, over home: Android's "allow PowOS to create widgets" dialog
     * (ACTION_APPWIDGET_BIND) and the widget's own setup (its configure activity). Invisible itself; tells
     * [AppWidgets] the answer and closes.
     */
    class BindActivity : Activity() {
        private val id get() = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)

        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            // Recreated (rotation, a fold) while its screen is open: the result still comes to onActivityResult.
            if (savedInstanceState != null) return
            try {
                when (intent.getStringExtra(MODE)) {
                    BIND -> {
                        @Suppress("DEPRECATION")
                        val bind =
                            Intent(AppWidgetManager.ACTION_APPWIDGET_BIND)
                                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER, intent.getParcelableExtra<ComponentName>(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER))
                                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER_PROFILE, intent.getParcelableExtra<UserHandle>(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER_PROFILE))
                                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_OPTIONS, intent.getBundleExtra(AppWidgetManager.EXTRA_APPWIDGET_OPTIONS))
                        @Suppress("DEPRECATION")
                        startActivityForResult(bind, REQUEST_BIND)
                    }
                    CONFIGURE, RECONFIGURE -> configure()
                    else -> done(false)
                }
            } catch (e: Exception) {
                Log.w(TAG, "can't ask", e)
                done(false)
            }
        }

        private fun configure() {
            try {
                get(this).host.startAppWidgetConfigureActivityForResult(this, id, 0, REQUEST_CONFIGURE, null)
            } catch (e: Exception) {
                // Its setup isn't exported to us, or is gone: the widget goes on home as it is.
                Log.w(TAG, "can't open the widget's setup", e)
                done(true)
            }
        }

        @Deprecated("Activity result API")
        override fun onActivityResult(
            requestCode: Int,
            resultCode: Int,
            data: Intent?,
        ) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            when (requestCode) {
                REQUEST_BIND -> if (resultCode == RESULT_OK && get(this).needsConfigure(id)) configure() else done(resultCode == RESULT_OK)
                REQUEST_CONFIGURE -> done(resultCode == RESULT_OK || intent.getStringExtra(MODE) == RECONFIGURE)
            }
        }

        private fun done(ok: Boolean) {
            if (intent.getStringExtra(MODE) != RECONFIGURE) get(this).answered(id, ok)
            finish()
        }

        companion object {
            const val MODE = "mode"
            const val BIND = "bind"
            const val CONFIGURE = "configure"
            const val RECONFIGURE = "reconfigure"
            private const val REQUEST_BIND = 1
            private const val REQUEST_CONFIGURE = 2
        }
    }
}

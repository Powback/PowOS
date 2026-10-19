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
import android.os.HandlerThread
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
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.FilterInputStream
import java.io.InputStream
import java.io.SequenceInputStream
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
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
 * private VirtualDisplay exactly the tile's size, drawn into an ImageReader. Its frames go to the page as raw pixels
 * (ShellHost serves the latest at /_appwidget/<id>, "appwidgets.frame" says when it changed - [Frames]); the page's
 * touches on the tile come back as MotionEvents dispatched into the hosted view, so its buttons press, ripple and click
 * as on any launcher. The tile is a <canvas> in the grid, moved, resized and removed like PowOS's own widgets.
 *
 * Kept alive: a widget's display is made once and lives until the widget is removed or no page has shown it for
 * [RELEASE_MS]. A new tile size (the fold, the keyboard, a resize, a second home of another size) resizes the display
 * in place ([Renderer.resize]); making it again - a new display, surface and window, the widget laid out from nothing -
 * flickered, and with every fold and home recreated it happened hundreds of times an hour.
 *
 * Why images and not the widget's own surface: a SurfaceControl can be reparented under another window's surface,
 * but the page is one WebView surface whose DOM decides what is drawn where - a tile that moves with a page swipe,
 * fades, is clipped to its corners and drawn under the edit sheet can't be a separate surface without the shell
 * leaving the page (a native overlay kept in sync with the DOM every frame). So the pixels go to the page; they're
 * copied off the ImageReader once, sent uncompressed, and only when they changed.
 *
 * Placement is the home's: each widget's cell is in the same WidgetLayout as every other home item (key "aw:<id>"),
 * its page and provider in this class's preferences, and home.get lists them with the rest ([merge]).
 *
 * Themed as on a Pixel launcher: the system palette widgets draw with (system_accent1_0..system_neutral2_1000, and
 * Android 14's Material tokens) is PowOS's theme's, set on each hosted view (setColorResources), and the app is in
 * the theme's light or dark - widgets pick their night resources from it. The page clips each to PowOS's corners.
 *
 * Binding: as a privileged system app PowOS can hold BIND_APPWIDGET (signature|privileged), and then
 * bindAppWidgetIdIfAllowed succeeds and a widget is bound silently, as by the system launcher. The system module's
 * allowlist carries it (system-module/privapp-permissions.txt); the manifest requests it only once a module with that
 * entry is booted (install-app.sh refuses an APK asking for more than the mounted allowlist: the phone wouldn't boot).
 * Until then the first widget shows Android's "allow PowOS to create widgets" dialog (ACTION_APPWIDGET_BIND,
 * [BindActivity]); ticking "always allow" makes later ones silent. Then the widget's own setup screen, when it has one.
 *
 * Main thread, except the frames' thread (each [Renderer]'s ImageReader, [Frames]) and what ShellHost's loader thread
 * reads: [frameStream] and [previewPng].
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

    /** Each widget's latest frame, read by ShellHost's loader thread; kept while its renderer is let go. */
    private val frames = ConcurrentHashMap<Int, Frames>()

    /** Where frames are copied off the renderers' ImageReaders, not to take the main thread's time from the page. */
    private val frameThread = Handler(HandlerThread("PowosAppWidgetFrames").apply { start() }.looper)

    /** A widget no page shows, let go of after [RELEASE_MS] (its renderer: the display, the window). */
    private val releases = HashMap<Int, Runnable>()
    private var listening = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    init {
        // The home's own placement (a store widget, a pinned app given the first free spot) steps around these.
        layout.occupied = { page -> entries.filter { it.page == page }.mapNotNull { layout.cell(key(it.id)) } }
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
        // A widget's off-screen display gone (the system took it, its Presentation dismissed): drawn again.
        context.getSystemService(DisplayManager::class.java).registerDisplayListener(
            object : DisplayManager.DisplayListener {
                override fun onDisplayAdded(displayId: Int) {}

                override fun onDisplayChanged(displayId: Int) {}

                override fun onDisplayRemoved(displayId: Int) {
                    if (renderers.values.any { it.displayId == displayId }) heal()
                }
            },
            main,
        )
    }

    /** The apps whose widgets are on home: their tasks are kept by the switcher's clear all (system/Switcher). */
    fun providerPackages(): Set<String> = entries.map { it.provider.packageName }.toSet()

    /**
     * Every widget a page shows that lost its drawing (its display or Presentation gone - its provider's process
     * killed under it, a display torn down) is drawn again at its size; one whose binding is gone is logged (it needs
     * adding again). On home coming up, a display removed, a task removed by the switcher.
     */
    fun heal() {
        for ((id, r) in renderers.toList()) {
            if (!r.broken) continue
            Log.w(TAG, "widget $id lost its display: drawing it again")
            renderers.remove(id)
            r.close()
            if (listeners.values.none { id in it }) continue
            val info = awm.getAppWidgetInfo(id) ?: run { Log.w(TAG, "widget $id is not bound any more"); null } ?: continue
            val store = frames.getOrPut(id, ::Frames)
            renderers[id] = Renderer(info, r.w, r.h, bound = id) { image -> if (store.offer(image)) main.post { frame(id) } }
            updateShown(id)
        }
        for (e in entries) if (awm.getAppWidgetInfo(e.id) == null) Log.w(TAG, "widget ${e.id} (${e.provider.flattenToShortString()}) isn't bound to PowOS any more")
    }

    // The page's channel.

    fun listen(events: (String, Any?) -> Unit) {
        listeners.getOrPut(events) { HashSet() }
    }

    fun unlisten(events: (String, Any?) -> Unit) {
        val shown = listeners.remove(events).orEmpty()
        shown.forEach(::updateShown)
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
        // The only way a widget leaves home (nothing prunes them): said, with who asked, so a lost one can be traced.
        Log.w(TAG, "widget ${e.id} (${e.provider.flattenToShortString()}) removed from home", Throwable("home.remove"))
        entries.remove(e)
        save()
        renderers.remove(e.id)?.close()
        frames.remove(e.id)
        releases.remove(e.id)?.let(main::removeCallbacks)
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
     * A page shows [id] at [wDp] x [hDp] (its tile, CSS px = dp): it's drawn at that size (its display resized if the
     * size changed - the provider hears of it, OPTION_APPWIDGET_SIZES) and the provider's updates are listened to.
     * Answers { url: the latest frame's, if there is one; scrolls }; "appwidgets.frame" brings each next.
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
            awm.updateAppWidgetOptions(id, sizeOptions(wDp.roundToInt(), hDp.roundToInt()))
            if (r == null || !r.resize(w, h)) {
                r?.close()
                val store = frames.getOrPut(id, ::Frames)
                renderers[id] = Renderer(info, w, h, bound = id) { image -> if (store.offer(image)) main.post { frame(id) } }
            }
        }
        updateShown(id)
        return JSONObject().put("url", frameUrl(id) ?: JSONObject.NULL).put("scrolls", renderers[id]?.let { hasCollection(it.view) } == true)
    }

    fun unwatch(
        events: (String, Any?) -> Unit,
        id: Int,
    ) {
        listeners[events]?.remove(id)
        updateShown(id)
        updateListening()
    }

    /**
     * Whether any page shows [id]: its frames are copied only then (it's drawn regardless - a clock ticks on), and one
     * no page has shown for [RELEASE_MS] is let go of, its last frame kept for the tile to show when it's back.
     */
    private fun updateShown(id: Int) {
        val shown = listeners.values.any { id in it }
        renderers[id]?.shown = shown
        releases.remove(id)?.let(main::removeCallbacks)
        if (!shown && id in renderers) {
            releases[id] =
                Runnable {
                    releases.remove(id)
                    if (listeners.values.none { id in it }) renderers.remove(id)?.close()
                }.also { main.postDelayed(it, RELEASE_MS) }
        }
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

    /** A new frame of [id] (main thread): the pages showing it fetch it. */
    private fun frame(id: Int) {
        val r = renderers[id] ?: return
        val payload = JSONObject().put("id", id).put("url", frameUrl(id)).put("scrolls", hasCollection(r.view))
        for ((events, shown) in listeners.entries.toList()) if (id in shown) events("appwidgets.frame", payload)
    }

    private fun frameUrl(id: Int) = frames[id]?.stamp?.takeIf { it > 0 }?.let { "${ShellHost.ORIGIN}/_appwidget/$id?v=$it" }

    /** The latest frame of [id] for ShellHost's loader thread: [Frames.open]'s stream, [FRAME_TYPE]. */
    fun frameStream(id: Int): InputStream? = frames[id]?.open()

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
        // A finger on it: its frames at the display's pace, till a while after (a list flinging on, a ripple fading).
        r.live(now + LIVE_MS)
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

    /** Pictures made, by provider: by their size (PNG bytes), so a phone's hundred-odd widgets stay drawn once. */
    private val previews =
        object : LruCache<String, ByteArray>(PREVIEW_CACHE_BYTES) {
            override fun sizeOf(
                key: String,
                value: ByteArray,
            ) = value.size
        }
    private val previewLock = Any()

    /** The previews' renderer, one for them all (main thread): made with the first, let go of once the picker's done. */
    private var previewer: Renderer? = null
    private val dropPreviewer =
        Runnable {
            previewer?.close()
            previewer = null
        }
    private var previewDone: Runnable? = null

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
        val result = AtomicReference<Bitmap?>()
        val done = CountDownLatch(1)
        main.post {
            main.removeCallbacks(dropPreviewer)
            previewDone?.let(main::removeCallbacks)
            val timeout =
                Runnable {
                    done.countDown()
                    main.removeCallbacks(dropPreviewer)
                    main.postDelayed(dropPreviewer, PREVIEW_KEEP_MS)
                }
            val onImage: (Image) -> Unit = { image ->
                result.set(bitmap(image))
                // The first frame can be the views before their images arrive: the one after settling.
                main.removeCallbacks(timeout)
                main.postDelayed(timeout, PREVIEW_SETTLE_MS)
            }
            // One display for every preview, resized to each (a display a preview made hundreds when the picker
            // opened); a new one only when it can't be (before Android 12).
            val r =
                runCatching {
                    previewer?.takeIf { it.preview(info, views, w, h, onImage) }
                        ?: Renderer(info, w, h, preview = views, onImage = onImage).also {
                            previewer?.close()
                            previewer = it
                        }
                }.onFailure { Log.w(TAG, "preview of ${info.provider}", it) }.getOrNull()
            previewDone = timeout
            if (r == null) done.countDown() else main.postDelayed(timeout, PREVIEW_TIMEOUT_MS)
        }
        done.await(PREVIEW_TIMEOUT_MS + 1000, TimeUnit.MILLISECONDS)
        return result.get()
    }

    /** A frame as a Bitmap (a preview's). */
    private fun bitmap(image: Image): Bitmap {
        val plane = image.planes[0]
        val full = Bitmap.createBitmap(plane.rowStride / plane.pixelStride, image.height, Bitmap.Config.ARGB_8888)
        plane.buffer.rewind()
        full.copyPixelsFromBuffer(plane.buffer)
        return if (full.width == image.width) full else Bitmap.createBitmap(full, 0, 0, image.width, image.height).also { full.recycle() }
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
     *
     * Each frame the display gets is handed to [onImage] on the frames' thread - at most one every [FRAME_MS] while
     * it's [live] (a finger on it), else every [IDLE_FRAME_MS]: a widget nobody touches that animates (a clock's
     * seconds) isn't copied 60 times a second. One that doesn't draw costs nothing: no frame comes.
     */
    private inner class Renderer(
        info: AppWidgetProviderInfo,
        w: Int,
        h: Int,
        bound: Int? = null,
        preview: RemoteViews? = null,
        @Volatile private var onImage: (Image) -> Unit,
    ) {
        var w = w
            private set
        var h = h
            private set
        private val dpi = context.resources.displayMetrics.densityDpi

        /** Swapped for one of the new size by [resize]; read on the frames' thread. */
        @Volatile private var reader = reader(w, h)
        private val display: VirtualDisplay =
            context.getSystemService(DisplayManager::class.java)
                .createVirtualDisplay("powos-appwidget-${bound ?: "preview"}", w, h, dpi, reader.surface, 0)
        private val presentation = Presentation(context, display.display)

        /** Its display (for the display listener). */
        val displayId: Int = display.display.displayId

        /** It can't draw any more: closed, its Presentation dismissed, or its display gone. */
        val broken: Boolean get() = closed || !presentation.isShowing || display.display?.isValid != true
        val root: FrameLayout
        val view: AppWidgetHostView
        var downAt = 0L

        /** A page shows it: else its frames aren't copied (the latest is, once it's shown again). */
        @Volatile var shown = true
            set(value) {
                field = value
                if (value) frameThread.post { if (pending != null && !queued) copy() }
            }

        /** Until when (uptimeMillis) its frames go at the display's pace. */
        @Volatile private var liveUntil = 0L

        // The frames' thread's.
        private var pending: Image? = null
        private var queued = false
        private var copied = 0L
        private val copier = Runnable { copy() }

        @Volatile private var closed = false

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
            presentation.setContentView(root, ViewGroup.LayoutParams(w, h))
            presentation.show()
            if (preview != null) view.updateAppWidget(preview)
        }

        /** An ImageReader [w] x [h] whose frames come to [arrived], three of them (one held, one drawn, one spare). */
        private fun reader(
            w: Int,
            h: Int,
        ) = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3).apply { setOnImageAvailableListener(::arrived, frameThread) }

        private fun arrived(r: ImageReader) {
            val image = runCatching { r.acquireLatestImage() }.getOrNull() ?: return
            // A frame of the size before a resize, or after close.
            if (closed || r !== reader) return image.close()
            pending?.close()
            pending = image
            if (queued || !shown) return
            queued = true
            val gap = if (SystemClock.uptimeMillis() < liveUntil) FRAME_MS else IDLE_FRAME_MS
            frameThread.postAtTime(copier, copied + gap)
        }

        private fun copy() {
            queued = false
            val image = pending ?: return
            pending = null
            copied = SystemClock.uptimeMillis()
            try {
                if (!closed) onImage(image)
            } catch (e: Exception) {
                Log.w(TAG, "frame", e)
            } finally {
                image.close()
            }
        }

        /** Its frames at the display's pace until [until]; one waiting for its idle turn goes now. */
        fun live(until: Long) {
            val was = liveUntil
            liveUntil = until
            if (was < SystemClock.uptimeMillis()) {
                frameThread.post {
                    if (queued) {
                        frameThread.removeCallbacks(copier)
                        copy()
                    }
                }
            }
        }

        /**
         * Draws it [nw] x [nh] from now on, on the same display - resized, a new ImageReader its size, the window laid
         * out again - so nothing flickers and the widget isn't inflated again. False before Android 12, where a
         * Presentation dismisses itself when its display changes (its caller makes a new renderer then).
         */
        fun resize(
            nw: Int,
            nh: Int,
        ): Boolean {
            if (Build.VERSION.SDK_INT < 31 || closed) return false
            val old = reader
            reader = reader(nw, nh)
            display.resize(nw, nh, dpi)
            display.surface = reader.surface
            w = nw
            h = nh
            root.layoutParams =
                root.layoutParams.apply {
                    width = nw
                    height = nh
                }
            view.layoutParams = FrameLayout.LayoutParams(nw, nh)
            frameThread.post {
                // A frame of the old size, not wanted now.
                pending?.close()
                pending = null
                old.close()
            }
            return true
        }

        /** Shows [views], [info]'s preview, [nw] x [nh] from now on, its frames to [then] - false if it can't be resized. */
        fun preview(
            info: AppWidgetProviderInfo,
            views: RemoteViews,
            nw: Int,
            nh: Int,
            then: (Image) -> Unit,
        ): Boolean {
            if ((nw != w || nh != h) && !resize(nw, nh)) return false
            onImage = then
            view.setAppWidget(AppWidgetManager.INVALID_APPWIDGET_ID, info)
            view.updateAppWidget(views)
            return true
        }

        fun close() {
            if (closed) return
            closed = true
            runCatching { presentation.dismiss() }
            display.release()
            val r = reader
            frameThread.post {
                pending?.close()
                pending = null
                r.close()
            }
        }
    }

    /**
     * One widget's latest frame for the page, as raw pixels: [FRAME_TYPE], an 8-byte header (its width and height,
     * little-endian ints) and then RGBA, not premultiplied - ImageData's own layout, so the page puts it on its
     * canvas as it is. PNG cost too much a frame: a 6x3 tile took ~70 ms to encode and ~20 to decode, a list scrolling
     * at ~10 frames a second; its pixels take a few ms to copy, send and put. A frame that's the same as the one
     * shown isn't sent (a widget redrawing what it showed). Its buffers are reused: two, the one the page reads and
     * the next, more only while a page still reads an old one.
     */
    private class Frames {
        private class Frame(
            val w: Int,
            val h: Int,
            val bytes: ByteArray,
        ) {
            var readers = 0
            var retired = false
        }

        private var current: Frame? = null
        private var spare: ByteArray? = null

        /** The latest frame's number, for its URL. */
        @Volatile var stamp = 0L
            private set

        /** [image] as the latest frame (the frames' thread), unless it's the one shown: whether it's new. */
        fun offer(image: Image): Boolean {
            val w = image.width
            val h = image.height
            val row = w * 4
            val bytes = synchronized(this) { spare?.takeIf { it.size == row * h }?.also { spare = null } } ?: ByteArray(row * h)
            val plane = image.planes[0]
            val buffer = plane.buffer
            if (plane.rowStride == row) {
                buffer.rewind()
                buffer.get(bytes, 0, row * h)
            } else {
                for (y in 0 until h) {
                    buffer.position(y * plane.rowStride)
                    buffer.get(bytes, y * row, row)
                }
            }
            unpremultiply(bytes)
            synchronized(this) {
                val c = current
                if (c != null && c.w == w && c.h == h && c.bytes.contentEquals(bytes)) {
                    spare = bytes
                    return false
                }
                if (c != null) {
                    c.retired = true
                    if (c.readers == 0) spare = c.bytes
                }
                current = Frame(w, h, bytes)
                stamp++
            }
            return true
        }

        /** The latest frame, for one request (ShellHost's loader thread); its buffer is the page's till it's read. */
        @Synchronized
        fun open(): InputStream? {
            val f = current ?: return null
            f.readers++
            val header = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putInt(f.w).putInt(f.h).array()
            return object : FilterInputStream(SequenceInputStream(ByteArrayInputStream(header), ByteArrayInputStream(f.bytes))) {
                private var done = false

                override fun close() {
                    super.close()
                    synchronized(this@Frames) {
                        if (done) return
                        done = true
                        f.readers--
                        if (f.retired && f.readers == 0 && spare == null) spare = f.bytes
                    }
                }
            }
        }

        /** The display's pixels are premultiplied (alpha already in the colors); ImageData's aren't. */
        private fun unpremultiply(p: ByteArray) {
            var i = 3
            while (i < p.size) {
                val a = p[i].toInt() and 0xff
                if (a != 255 && a != 0) {
                    p[i - 3] = minOf(255, (p[i - 3].toInt() and 0xff) * 255 / a).toByte()
                    p[i - 2] = minOf(255, (p[i - 2].toInt() and 0xff) * 255 / a).toByte()
                    p[i - 1] = minOf(255, (p[i - 1].toInt() and 0xff) * 255 / a).toByte()
                }
                i += 4
            }
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

        /** Untouched, at most five frames a second (an animation nobody's touching, a player's progress). */
        private const val IDLE_FRAME_MS = 200L

        /** How long after the finger's last touch frames keep the display's pace: a fling, a ripple fading. */
        private const val LIVE_MS = 2500L

        /** A widget no page has shown this long has its display and window let go of. */
        private const val RELEASE_MS = 10 * 60_000L

        /** [Frames]' format, for ShellHost and the page (appwidget.tsx). */
        const val FRAME_TYPE = "application/x-powos-rgba"

        private const val PREVIEW_SETTLE_MS = 400L
        private const val PREVIEW_TIMEOUT_MS = 2500L

        /** The previews' renderer, kept this long after the last (the picker scrolled on, searched). */
        private const val PREVIEW_KEEP_MS = 30_000L

        /** The previews' cache, by their PNGs' bytes. */
        private const val PREVIEW_CACHE_BYTES = 16 * 1024 * 1024

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

package dev.omalauncher.widgets.recon

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Presentation
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.graphics.drawable.ColorDrawable
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.Bundle
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.os.UserManager
import android.util.Log
import android.util.SizeF
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.RemoteViews
import dev.omalauncher.R
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.roundToInt

/**
 * Recon of Android app widgets (any Play Store or system app's), so an agent can recreate one as an OWL widget that
 * looks native to the launcher: binds the provider to [ReconHost] for a few seconds, draws its widget off screen
 * at a given size, and writes `.recon/<provider>/` in the widgets dir (the guest's ~/.config/omalauncher/widgets):
 *
 * - recon.json: the provider (label, sizes, resizing, update period, configure activity), the inflated view tree
 *   ([ViewTreeDump]), the RemoteViews actions ([RemoteViewsDump]) and each update the provider sent meanwhile
 * - screenshot.png: the widget as Android draws it; images/: every picture in it; preview*.png: the provider's
 *
 * Then the widget is deleted again. Asked for by `owl-recon` in the guest ([watch]: files in .recon/inbox, like
 * owl-send) or by adb ([ReconReceiver]). Nothing the widget holds is ever sent or tapped.
 */
class WidgetRecon private constructor(
    context: Context,
) {
    private val context = context.applicationContext
    private val awm = AppWidgetManager.getInstance(this.context)
    internal val host = ReconHost(this.context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val busy = Mutex()

    /** Bind and configure prompts the user still has to answer, by widget id; see [ReconActivity]. */
    private val prompts = ConcurrentHashMap<Int, CompletableDeferred<Boolean>>()

    init {
        // A capture the launcher died in left its widget bound; this host only ever holds captures in progress.
        runCatching { host.appWidgetIds.forEach(host::deleteAppWidgetId) }
    }

    class Request(
        /** A provider as `package/class` (as [list] prints it), or a package with one widget. */
        val provider: String,
        val widthDp: Int? = null,
        val heightDp: Int? = null,
        /** How long to watch the provider's updates; the capture is taken at the end. */
        val seconds: Int = DEFAULT_SECONDS,
        /** Run the provider's configure activity first (the user fills it in on the phone). */
        val configure: Boolean = false,
        /** Don't bind: draw the provider's initial layout, without its data (no permission needed). */
        val static: Boolean = false,
    )

    class ReconError(
        message: String,
    ) : Exception(message)

    /** Every widget provider on the phone, in every profile we can see. */
    fun providers(): List<AppWidgetProviderInfo> {
        val profiles = context.getSystemService(UserManager::class.java).userProfiles
        return profiles
            .flatMap { p -> runCatching { awm.getInstalledProvidersForProfile(p) }.getOrDefault(emptyList()) }
            .sortedWith(compareBy({ it.provider.packageName }, { it.provider.className }))
    }

    /** [providers] as text, one per line, filtered by [filter] (in the component, label or app). Writes providers.json too. */
    suspend fun list(
        dir: File,
        filter: String = "",
    ): String {
        val pm = context.packageManager
        val all = providers()
        val json = JSONArray(all.map { providerJson(it) })
        withContext(Dispatchers.IO) {
            dir.mkdirs()
            File(dir, "providers.json").writeText(json.toString(2))
        }
        return all
            .map { info ->
                val app = runCatching { pm.getApplicationLabel(pm.getApplicationInfo(info.provider.packageName, 0)).toString() }.getOrDefault("")
                val label = info.loadLabel(pm).orEmpty()
                val (w, h) = defaultSizeDp(info)
                val extra = listOfNotNull(if (info.configure != null) "configure" else null, if (info.profile != Process.myUserHandle()) "other profile" else null)
                "${info.provider.flattenToShortString()}\t$label ($app)\t${w}x${h}dp" + extra.joinToString("") { "\t$it" }
            }.filter { filter.isEmpty() || it.contains(filter, ignoreCase = true) }
            .joinToString("\n")
    }

    /**
     * Captures [req]'s widget into dir/<provider>/ and returns that folder. [status] hears what it's waiting for
     * (the user's permission on the phone). Main thread.
     */
    suspend fun capture(
        dir: File,
        req: Request,
        status: (String) -> Unit = {},
    ): File =
        busy.withLock {
            val info = resolve(req.provider)
            val (defW, defH) = defaultSizeDp(info)
            val wDp = req.widthDp ?: defW
            val hDp = req.heightDp ?: defH
            if (wDp !in 16..2000 || hDp !in 16..2000) throw ReconError("size ${wDp}x${hDp}dp is out of range")
            val out = File(dir, slug(info.provider))
            withContext(Dispatchers.IO) {
                out.deleteRecursively()
                out.mkdirs()
            }
            val notes = JSONArray()
            if (req.static) {
                shoot(null, info, wDp, hDp, 0, out, notes, "no (--static)", false)
                return@withLock out
            }
            val options = sizeOptions(wDp, hDp)
            val id = host.allocateAppWidgetId()
            try {
                var bound = "silently"
                if (!awm.bindAppWidgetIdIfAllowed(id, info.profile, info.provider, options)) {
                    status("waiting for you on the phone: allow PowOS to create widgets (tick \"always allow\" so recon works without asking)")
                    if (!prompt(ReconActivity.BIND, id, info, options)) {
                        status("not allowed to bind it; capturing its layout without data instead (--static)")
                        notes.put("STATIC: the user didn't allow binding (declined or no answer in 3 minutes), so this is the provider's initial layout without its data; run again once they allow it")
                        shoot(null, info, wDp, hDp, 0, out, notes, "no (not allowed)", false)
                        return@withLock out
                    }
                    bound = "after the user allowed it"
                }
                awm.updateAppWidgetOptions(id, options)
                var configured = false
                if (info.configure != null) {
                    if (req.configure) {
                        status("waiting for you on the phone: set up the widget in ${info.loadLabel(context.packageManager)}")
                        configured = prompt(ReconActivity.CONFIGURE, id, info, options)
                        if (!configured) notes.put("the configure activity was cancelled or failed; captured unconfigured")
                    } else {
                        notes.put("this widget has a configure activity (${info.configure.flattenToShortString()}) that wasn't run; pass --configure to set it up first")
                    }
                }
                status("capturing for ${req.seconds}s")
                shoot(id, awm.getAppWidgetInfo(id) ?: info, wDp, hDp, req.seconds, out, notes, bound, configured)
            } finally {
                host.deleteAppWidgetId(id)
            }
            out
        }

    private suspend fun shoot(
        /** The bound widget, or null to draw [info]'s initial layout on its own. */
        id: Int?,
        info: AppWidgetProviderInfo,
        wDp: Int,
        hDp: Int,
        seconds: Int,
        out: File,
        notes: JSONArray,
        bound: String,
        configured: Boolean,
    ) {
        val metrics = context.resources.displayMetrics
        val wPx = (wDp * metrics.density).roundToInt()
        val hPx = (hDp * metrics.density).roundToInt()
        val images = Images(context)
        val window = Offscreen(context, wPx, hPx)
        val res = context.packageManager.getResourcesForApplication(info.provider.packageName)
        val json = JSONObject()
        if (id != null) host.startListening()
        try {
            val view =
                if (id != null) {
                    host.createView(window.context, id, info) as ReconHostView
                } else {
                    ReconHostView(window.context).apply { setAppWidget(AppWidgetManager.INVALID_APPWIDGET_ID, info) }
                }
            window.show(view)
            if (id == null) view.updateAppWidget(RemoteViews(info.provider.packageName, info.initialLayout))
            val start = SystemClock.uptimeMillis()
            // The first update, then until the provider is quiet (collections load their rows after it).
            while (id != null) {
                delay(POLL_MS)
                val now = SystemClock.uptimeMillis()
                if (now - start > (seconds + EXTRA_SECONDS) * 1000L) break
                if (view.latest == null && now - start < FIRST_UPDATE_MS) continue
                if (now - start >= seconds * 1000L && now - view.lastUpdateAt >= QUIET_MS) break
            }
            if (view.latest == null && id != null) notes.put("the provider sent no RemoteViews in time; this is its initial/loading layout")
            if (view.failed) notes.put("Android couldn't apply the provider's RemoteViews and showed its error view")
            window.frame()?.let { images.save(it, "screenshot.png") }
            val rv = view.latest?.let { RemoteViewsDump(res, images).let { d -> d.dump(it) to d } }
            rv?.second?.hidden?.takeIf { it.isNotEmpty() }?.let { notes.put("hidden API: no fields readable on ${it.joinToString()}") }
            if (id != null && rv != null && rv.first.optJSONArray("actions")?.length() == 0) {
                // Android 12+ responsive widgets keep one RemoteViews per size in mSizedRemoteViews, which is blocked.
                notes.put("the RemoteViews showed no actions (likely a responsive widget, whose per-size layouts Android hides from apps); the view tree has everything that was drawn")
            }
            json.put("views", ViewTreeDump(images, rv?.second?.byView.orEmpty()).dump(view))
            json.put("remoteViews", rv?.first ?: JSONObject.NULL)
            json.put("updates", updates(view, res, images))
            // Previews, drawn into the same view once the provider's updates no longer count.
            view.recording = false
            host.stopListening()
            val files = JSONObject().put("screenshot", "screenshot.png")
            info.loadPreviewImage(context, metrics.densityDpi)?.let { d -> images.drawable(d, wPx, hPx)?.let { files.put("previewImage", it) } }
            if (Build.VERSION.SDK_INT >= 31 && info.previewLayout != 0) {
                view.updateAppWidget(RemoteViews(info.provider.packageName, info.previewLayout))
                window.frame()?.let { images.save(it, "preview-layout.png"); files.put("previewLayout", "preview-layout.png") }
            }
            if (Build.VERSION.SDK_INT >= 35 && info.generatedPreviewCategories != 0) {
                val gen = runCatching { awm.getWidgetPreview(info.provider, info.profile, AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN) }
                gen.getOrNull()?.let {
                    view.updateAppWidget(it)
                    window.frame()?.let { f -> images.save(f, "preview-generated.png"); files.put("previewGenerated", "preview-generated.png") }
                } ?: gen.exceptionOrNull()?.let { notes.put("generated preview: ${it.message}") }
            }
            json.put("files", files)
        } finally {
            host.stopListening()
            window.close()
        }
        val night = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val head =
            JSONObject()
                .put("recon", 1)
                .put("capturedAt", SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.ROOT).format(Date()))
                .put("provider", providerJson(info))
                .put("size", JSONObject().put("widthDp", wDp).put("heightDp", hDp).put("widthPx", wPx).put("heightPx", hPx).put("density", metrics.density.toDouble()))
                .put(
                    "host",
                    JSONObject()
                        .put("bound", bound)
                        .put("configured", configured)
                        .put("nightMode", night)
                        .put("systemWidgetRadiusDp", if (Build.VERSION.SDK_INT >= 31) (context.resources.getDimension(android.R.dimen.system_app_widget_background_radius) / metrics.density).toDouble() else JSONObject.NULL),
                )
                .put("notes", notes)
        for (k in json.keys()) head.put(k, json.get(k))
        withContext(Dispatchers.IO) {
            images.write(out)
            File(out, "recon.json").writeText(head.toString(2))
        }
    }

    /** Each update: when (ms after the view was made), how many actions, and the texts it set. */
    private fun updates(
        view: ReconHostView,
        res: android.content.res.Resources,
        images: Images,
    ) = JSONArray(
        view.updates.map { (at, rv) ->
            val o = JSONObject().put("atMs", at)
            if (rv != null) {
                val d = RemoteViewsDump(res, images)
                d.dump(rv)
                o.put("set", JSONObject(d.byView.mapValues { JSONArray(it.value) }))
            }
            o
        },
    )

    private fun resolve(name: String): AppWidgetProviderInfo {
        val all = providers()
        ComponentName.unflattenFromString(name)?.let { c -> all.firstOrNull { it.provider == c }?.let { return it } }
        val ofPackage = all.filter { it.provider.packageName == name }
        return when {
            ofPackage.size == 1 -> ofPackage[0]
            ofPackage.size > 1 -> throw ReconError("$name has ${ofPackage.size} widgets; pick one:\n" + ofPackage.joinToString("\n") { it.provider.flattenToShortString() })
            else -> throw ReconError("no widget provider $name; owl-recon list shows them")
        }
    }

    /** The size a launcher would first give it: its target cells (Android 12+) or its minimum size. */
    private fun defaultSizeDp(info: AppWidgetProviderInfo): Pair<Int, Int> {
        val d = context.resources.displayMetrics.density
        var w = (info.minWidth / d).roundToInt()
        var h = (info.minHeight / d).roundToInt()
        if (Build.VERSION.SDK_INT >= 31) {
            if (info.targetCellWidth > 0) w = maxOf(w, CELL_DP * info.targetCellWidth - 16)
            if (info.targetCellHeight > 0) h = maxOf(h, CELL_DP * info.targetCellHeight - 16)
        }
        // Some OEM widgets declare a minimum wider than the phone (OnePlus's clocks: 610 dp); a home screen clamps it.
        val screen = context.resources.configuration.smallestScreenWidthDp - 16
        return maxOf(minOf(w, screen), 40) to maxOf(minOf(h, screen * 2), 40)
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

    private fun providerJson(info: AppWidgetProviderInfo): JSONObject {
        val pm = context.packageManager
        val d = context.resources.displayMetrics.density
        val res = runCatching { pm.getResourcesForApplication(info.provider.packageName) }.getOrNull()

        fun name(id: Int) = if (id == 0) JSONObject.NULL else runCatching { res?.getResourceName(id) }.getOrNull() ?: id

        fun dp(px: Int) = (px / d).roundToInt()
        val o =
            JSONObject()
                .put("provider", info.provider.flattenToShortString())
                .put("label", info.loadLabel(pm))
                .put("package", info.provider.packageName)
                .put("profile", if (info.profile == Process.myUserHandle()) "main" else info.profile.toString())
                .put("minSizeDp", "${dp(info.minWidth)}x${dp(info.minHeight)}")
                .put("minResizeDp", "${dp(info.minResizeWidth)}x${dp(info.minResizeHeight)}")
                .put("resizeMode", listOfNotNull(if (info.resizeMode and AppWidgetProviderInfo.RESIZE_HORIZONTAL != 0) "horizontal" else null, if (info.resizeMode and AppWidgetProviderInfo.RESIZE_VERTICAL != 0) "vertical" else null).joinToString("+").ifEmpty { "none" })
                .put("updatePeriodMillis", info.updatePeriodMillis)
                .put("initialLayout", name(info.initialLayout))
                .put("configure", info.configure?.flattenToShortString() ?: JSONObject.NULL)
                .put("reconfigurable", info.widgetFeatures and AppWidgetProviderInfo.WIDGET_FEATURE_RECONFIGURABLE != 0)
                .put("configurationOptional", info.widgetFeatures and AppWidgetProviderInfo.WIDGET_FEATURE_CONFIGURATION_OPTIONAL != 0)
                .put("autoAdvanceViewId", if (info.autoAdvanceViewId > 0) name(info.autoAdvanceViewId) else JSONObject.NULL)
                .put("hasPreviewImage", info.previewImage != 0)
        if (Build.VERSION.SDK_INT >= 31) {
            o.put("targetCells", "${info.targetCellWidth}x${info.targetCellHeight}")
            o.put("maxResizeDp", "${dp(info.maxResizeWidth)}x${dp(info.maxResizeHeight)}")
            o.put("previewLayout", name(info.previewLayout))
            info.loadDescription(context)?.let { o.put("description", it.toString()) }
        }
        if (Build.VERSION.SDK_INT >= 35) o.put("generatedPreviews", info.generatedPreviewCategories != 0)
        return o
    }

    /** Asks the user on the phone (bind permission, or the widget's own setup) through [ReconActivity]. */
    private suspend fun prompt(
        mode: String,
        id: Int,
        info: AppWidgetProviderInfo,
        options: Bundle,
    ): Boolean {
        val answer = CompletableDeferred<Boolean>()
        prompts[id] = answer
        val intent =
            Intent(context, ReconActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(ReconActivity.MODE, mode)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER, info.provider)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER_PROFILE, info.profile)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_OPTIONS, options)
        shown = false
        runCatching { context.startActivity(intent) }
        val nm = context.getSystemService(NotificationManager::class.java)
        // Android may not let a launcher in the background open a screen; a notification it may always post.
        scope.launch {
            delay(1500)
            if (!shown && !answer.isCompleted && nm.areNotificationsEnabled()) {
                nm.createNotificationChannel(NotificationChannel(CHANNEL, "Widget recon", NotificationManager.IMPORTANCE_HIGH))
                val open = PendingIntent.getActivity(context, id, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                val what = if (mode == ReconActivity.BIND) "Allow PowOS to read ${info.loadLabel(context.packageManager)}'s widget" else "Set up ${info.loadLabel(context.packageManager)}'s widget"
                nm.notify(
                    NOTIFICATION_ID,
                    Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_notification).setContentTitle(what)
                        .setContentText("An agent asked for a widget recon").setContentIntent(open).setAutoCancel(true).build(),
                )
            }
        }
        return try {
            withTimeoutOrNull(PROMPT_TIMEOUT_MS) { answer.await() } ?: false
        } finally {
            prompts.remove(id)
            nm.cancel(NOTIFICATION_ID)
        }
    }

    @Volatile private var shown = false

    internal fun promptShown() {
        shown = true
        context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
    }

    internal fun promptAnswered(
        id: Int,
        ok: Boolean,
    ) {
        prompts[id]?.complete(ok)
    }

    /** Runs a request on the recon's own scope, independent of any screen. */
    internal fun launch(block: suspend () -> Unit) = scope.launch { block() }

    // `owl-recon` in the guest: <id>.req in .recon/inbox, progress in <id>.status, the answer in <id>.done.

    @Suppress("unused") // Held so it isn't collected, which would stop the events.
    private var inboxObserver: FileObserver? = null

    /** Answers `owl-recon` requests dropped into [dir]/inbox; results go to [dir]/<provider>/. */
    fun watch(dir: File) {
        val inbox = File(dir, "inbox")
        inbox.deleteRecursively()
        inbox.mkdirs()
        inboxObserver =
            object : FileObserver(inbox, CLOSE_WRITE or MOVED_TO) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    if (path != null && path.endsWith(".req")) scope.launch { answer(dir, inbox, path.removeSuffix(".req")) }
                }
            }.also { it.startWatching() }
    }

    /**
     * A request: `list [filter]` or `capture`, then `key=value` lines (provider, width, height, seconds, configure).
     * The answer: `ok` or `error: ...`, then the text to print.
     */
    private suspend fun answer(
        dir: File,
        inbox: File,
        id: String,
    ) {
        val req = File(inbox, "$id.req")
        val lines = withContext(Dispatchers.IO) { runCatching { req.readLines() }.getOrNull().also { req.delete() } } ?: return

        fun reply(text: String) =
            runCatching {
                val tmp = File(inbox, ".$id.tmp")
                tmp.writeText(text + "\n")
                tmp.renameTo(File(inbox, "$id.done"))
            }
        val args = lines.drop(1).mapNotNull { l -> l.split("=", limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] } }.toMap()
        val text =
            try {
                when (lines.firstOrNull()) {
                    "list" -> "ok\n" + list(dir, args["filter"].orEmpty())
                    "capture" -> {
                        val r = request(args)
                        val out = capture(dir, r) { s -> runCatching { File(inbox, "$id.status").appendText(s + "\n") } }
                        "ok\n" + summary(out)
                    }
                    else -> "error: unknown request"
                }
            } catch (e: ReconError) {
                "error: ${e.message}"
            } catch (e: Exception) {
                Log.w(TAG, "recon failed", e)
                "error: ${e.javaClass.simpleName}: ${e.message}"
            }
        withContext(Dispatchers.IO) { reply(text) }
    }

    /** What the agent reads first: where the files are and what's notable. */
    internal fun summary(out: File): String {
        val j = runCatching { JSONObject(File(out, "recon.json").readText()) }.getOrNull() ?: return out.path
        val texts = ArrayList<String>()

        fun walk(n: JSONObject) {
            n.optString("text").takeIf { it.isNotBlank() }?.let { texts += it }
            n.optJSONArray("children")?.let { c -> for (i in 0 until c.length()) walk(c.getJSONObject(i)) }
        }
        j.optJSONObject("views")?.let(::walk)
        val notes = j.optJSONArray("notes")
        return buildString {
            append(out.name).append('\n')
            append("  texts: ").append(texts.take(12).joinToString(" | ") { it.replace('\n', ' ').take(40) }).append('\n')
            append("  images: ").append(File(out, "images").list()?.size ?: 0).append(", updates: ").append(j.optJSONArray("updates")?.length() ?: 0).append('\n')
            if (notes != null) for (i in 0 until notes.length()) append("  note: ").append(notes.getString(i)).append('\n')
        }.trimEnd()
    }

    internal fun request(args: Map<String, String>): Request {
        val provider = args["provider"]?.takeIf { it.isNotBlank() } ?: throw ReconError("no provider given")
        return Request(
            provider = provider,
            widthDp = args["width"]?.toIntOrNull(),
            heightDp = args["height"]?.toIntOrNull(),
            seconds = args["seconds"]?.toIntOrNull()?.coerceIn(1, MAX_SECONDS) ?: DEFAULT_SECONDS,
            configure = args["configure"] == "1" || args["configure"] == "true",
            static = args["static"] == "1" || args["static"] == "true",
        )
    }

    /**
     * A private virtual display the widget's size with a window on it, so the widget is attached and drawn exactly
     * as on a home screen (collections load, hardware bitmaps draw) without being on the phone's screen. Like
     * [dev.omalauncher.widgets.Previews], which does this for OWL tiles.
     */
    private class Offscreen(
        context: Context,
        private val w: Int,
        private val h: Int,
    ) {
        private val reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3)
        private var latest: Image? = null
        private val display: VirtualDisplay =
            context.getSystemService(DisplayManager::class.java)
                .createVirtualDisplay("powos-widget-recon", w, h, context.resources.displayMetrics.densityDpi, reader.surface, 0)
        private val presentation = Presentation(context, display.display)
        val context: Context get() = presentation.context
        private var view: View? = null

        init {
            reader.setOnImageAvailableListener({ r ->
                r.acquireLatestImage()?.let { image ->
                    latest?.close()
                    latest = image
                }
            }, Handler(Looper.getMainLooper()))
            presentation.window?.setBackgroundDrawable(ColorDrawable(android.graphics.Color.TRANSPARENT))
        }

        fun show(v: View) {
            view = v
            presentation.setContentView(FrameLayout(context).apply { addView(v, FrameLayout.LayoutParams(w, h)) }, ViewGroup.LayoutParams(w, h))
            presentation.show()
        }

        /** The next frame drawn after now. */
        suspend fun frame(): Bitmap? {
            latest?.close()
            latest = null
            view?.invalidate()
            view?.requestLayout()
            withTimeoutOrNull(FRAME_TIMEOUT_MS) { while (latest == null) delay(50) }
            delay(SETTLE_MS)
            val image = latest ?: return null
            val plane = image.planes[0]
            val full = Bitmap.createBitmap(plane.rowStride / plane.pixelStride, h, Bitmap.Config.ARGB_8888)
            full.copyPixelsFromBuffer(plane.buffer)
            return if (full.width == w) full else Bitmap.createBitmap(full, 0, 0, w, h).also { full.recycle() }
        }

        fun close() {
            runCatching { presentation.dismiss() }
            display.release()
            latest?.close()
            reader.close()
        }
    }

    companion object {
        private const val TAG = "widget-recon"
        private const val CHANNEL = "widget-recon"
        private const val NOTIFICATION_ID = 0x504f57
        const val DEFAULT_SECONDS = 6
        private const val MAX_SECONDS = 300
        private const val EXTRA_SECONDS = 10
        private const val POLL_MS = 100L
        private const val FIRST_UPDATE_MS = 10_000L
        private const val QUIET_MS = 1500L
        private const val FRAME_TIMEOUT_MS = 2000L
        private const val SETTLE_MS = 300L
        private const val PROMPT_TIMEOUT_MS = 180_000L

        /** Android's widget sizing guide: a cell is about 73 dp, minus 16 dp of margins overall. */
        private const val CELL_DP = 73

        /** The recon folder in the widgets dir; the guest sees ~/.config/omalauncher/widgets/.recon. */
        const val DIR = ".recon"

        fun slug(c: ComponentName) = "${c.packageName}__${c.shortClassName.removePrefix(".")}".replace(Regex("[^A-Za-z0-9._-]"), "_")

        @SuppressLint("StaticFieldLeak") // The application context.
        @Volatile private var instance: WidgetRecon? = null

        @Synchronized
        fun get(context: Context): WidgetRecon = instance ?: WidgetRecon(context).also { instance = it }
    }
}

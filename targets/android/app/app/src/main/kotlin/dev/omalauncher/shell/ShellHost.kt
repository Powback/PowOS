package dev.omalauncher.shell

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowInsets
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import dev.omalauncher.R
import dev.omalauncher.Runtime
import dev.omalauncher.ui.PtyTerminal
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.URLDecoder
import org.json.JSONArray
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The web shell (the repo's shell/, see shell/DESIGN.md) in a WebView, for whatever shows it: the launcher
 * ([ShellActivity]) and the system slots PowOS fills (the screen-off display, ...: docs/NATIVE-SYSTEM-UI.md). Each is
 * a thin host - its window, its role - around one of these; what it shows is the shell, the same code everywhere,
 * with the host API as window.powos ([ShellBridge]) - reachable from the page's own top frame only ([ShellOrigin]).
 * [mode] tells the page which screen it is (index.html?mode=).
 *
 * The page is served from [ORIGIN], a name that never reaches the network: each file comes from the override folder
 * ([overrides], where the user or an agent changes the shell - a file there wins over the shipped one) or the copy
 * the APK ships (assets/shell). Saving a file in the override folder hot-reloads it (files.changed), in every host.
 *
 * Working on the shell from a computer: a URL in [devUrlFile] (a LAN dev server) is loaded instead. Only that file
 * names it, never an intent - the bridge can launch and uninstall apps, so no other app may point it at a page.
 */
class ShellHost(
    private val context: Context,
    activity: Activity?,
    private val runtime: Runtime,
    private val mode: String? = null,
) {
    private val main = Handler(Looper.getMainLooper())
    private val overrides get() = File(context.filesDir, "shell")

    /** Where the override folder is (HotReload watches it). */
    internal val filesDir: File get() = context.filesDir
    private val devUrlFile get() = File(context.filesDir, "shell-dev-url")

    @SuppressLint("SetJavaScriptEnabled")
    val web: WebView =
        (if (mode == null) HomeWebView(context) else WebView(context)).apply {
            setBackgroundColor(Color.TRANSPARENT)
            // No View scrollbars over the page (a faint line at the right edge); the page scrolls on its own.
            isVerticalScrollBarEnabled = false
            isHorizontalScrollBarEnabled = false
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            // Its tiles kept rasterized while it's out of sight (home behind an app): a swipe up shows it from its
            // first frame, not after it's drawn again from scratch.
            settings.offscreenPreRaster = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            webViewClient = Client()
            webChromeClient =
                object : WebChromeClient() {
                    override fun onConsoleMessage(m: ConsoleMessage): Boolean {
                        Log.i(TAG, "${mode ?: "home"} ${m.messageLevel()} ${m.sourceId().substringAfterLast('/')}:${m.lineNumber()} ${m.message()}")
                        return true
                    }
                }
        }

    val bridge = ShellBridge(context, activity, runtime, web)

    /** An activity's page (home) at the panel's fastest rate while touched - or while a swipe up shows its switcher. */
    internal val highRefresh: HighRefresh? = activity?.window?.let { HighRefresh(it, web) }

    /** The page's boot: its errors and its ready (index.html's boot guard), watched by [checkBoot]. */
    private val boot = Boot()

    /** The page's own port (open, surface tiles): [ShellNative], handed only to the top frame at the page's origin. */
    private val native = ShellNative(
        context, web, devUrl()?.let { Uri.parse(it).let { u -> "${u.scheme}://${u.authority}" } } ?: ORIGIN,
        // Frame windows already have one compositor-blur owner (WindowFrame), including the clear grip at rest.
        pageGlass = mode != "windowbar" && mode != "windowgrip",
    )

    init {
        native.windowFrame = bridge::webWindowFrame
        ShellIcons.init(context.applicationContext, runtime)
        overrides.mkdirs()
        // The page's native objects, to its own top frame only (ShellOrigin: no iframe, no other origin).
        val rules = ShellOrigin.rules(devUrl())
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            listen("PowosHost", rules) { text ->
                val m = JSONArray(text)
                bridge.call(m.getInt(0), m.getString(1), m.optString(2, ""))
            }
            listen("PowosNative", rules) { text ->
                when (text) {
                    "connect" -> native.connect()
                    // The page animating with no finger on it (refresh.ts): the fastest mode while it does.
                    "boost 1" -> highRefresh?.boost(true, "page")
                    "boost 0" -> highRefresh?.boost(false, "page")
                }
            }
            listen("PowosBoot", rules) { text ->
                when (text.substringBefore(' ')) {
                    "error" -> boot.error(text.substringAfter(' ', ""))
                    "ready" -> boot.ready(text.substringAfter(' ', ""))
                }
            }
        } else {
            // Fail closed: a WebView without web message listeners gets no bridge at all (never the frame-blind
            // JavaScript interfaces). Every current Android System WebView has them (Chromium 82+).
            Log.e(TAG, "WebView without WEB_MESSAGE_LISTENER: the shell page gets no native bridge")
        }
        // Insets to the page (CSS px), as they change: the bar sits above the navigation bar, the drawer clears
        // the status bar, the keyboard's height lifts the bar.
        web.setOnApplyWindowInsetsListener { v, insets ->
            bridge.insets(insets)
            v.onApplyWindowInsets(insets)
            WindowInsets.CONSUMED
        }
        HotReload.add(this)
        val page = devUrl() ?: "$ORIGIN/index.html"
        web.loadUrl(mode?.let { "$page?mode=$it" } ?: page)
    }

    /**
     * One native object, [name] on the page (postMessage(text)), heard only from the top frame at [rules]' origins:
     * the WebView injects it only into frames at those origins, and [ShellOrigin.allowed] checks each message's
     * sender again (a same-origin srcdoc/about:blank iframe would get the object too - it is refused here).
     */
    private fun listen(
        name: String,
        rules: Set<String>,
        handle: (String) -> Unit,
    ) {
        val rulesOk = runCatching { WebViewCompat.addWebMessageListener(web, name, rules, listener(name, rules, handle)) }
        if (rulesOk.isFailure) {
            // A dev URL the WebView won't take as a rule: the shell's own origin only.
            Log.w(TAG, "$name: origin rules $rules refused (${rulesOk.exceptionOrNull()?.message}); shell origin only")
            WebViewCompat.addWebMessageListener(web, name, setOf(ShellOrigin.SHELL), listener(name, setOf(ShellOrigin.SHELL), handle))
        }
    }

    private fun listener(
        name: String,
        rules: Set<String>,
        handle: (String) -> Unit,
    ) = WebViewCompat.WebMessageListener { _, message, sourceOrigin, isMainFrame, _ ->
        val origin = sourceOrigin.toString()
        if (!ShellOrigin.allowed(origin, isMainFrame, rules)) {
            Log.w(TAG, "$name: refused a message from ${if (isMainFrame) "the top frame" else "an iframe"} at $origin")
            return@WebMessageListener
        }
        val text = message.data ?: return@WebMessageListener
        try {
            handle(text)
        } catch (e: Exception) {
            Log.w(TAG, "$name: bad message", e)
        }
    }

    /** The style's live-blur switch to the page's glass ([GlassBlur]), as it changes. */
    private val styleWatch =
        native.glass?.let { glass ->
            kotlinx.coroutines.MainScope().also { scope ->
                scope.launch { androidx.compose.runtime.snapshotFlow { runtime.style.style[dev.omalauncher.theme.Style.LIVE_BLUR] }.collect { glass.allow(it) } }
                scope.launch { androidx.compose.runtime.snapshotFlow { runtime.style.style[dev.omalauncher.theme.Style.LIQUID_GLASS] }.collect { glass.allowLiquid(it) } }
            }
        }

    /** The whole window blurred behind (the switcher's depth), beside the glass's regions; false: not this way. */
    fun wholeWindow(radiusPx: Float): Boolean = native.glass?.wholeWindow(radiusPx) ?: false

    /** The page's window surface (home's), for WallpaperBackdrop to leave out. */
    fun windowSurface(): android.view.SurfaceControl? = native.glass?.windowSurface()

    fun destroy() {
        styleWatch?.cancel()
        bootSerial++
        HotReload.remove(this)
        bridge.close()
        native.close()
        web.destroy()
    }

    /** Which load of the page this is (each navigation a new one): a late check of an earlier load does nothing. */
    private var bootSerial = 0
    private var bootReady = false
    private var bootFailed = false

    /** The first error the page reported before it was ready: what a boot failure is blamed on. */
    private var bootError: String? = null

    /**
     * index.html's boot guard: each error of the page (once per message per load) and its ready (window.__powosAlive
     * set: app.tsx rendered its screen) - to [ShellErrors], which logs it and tells the manager.
     */
    private inner class Boot {
        fun error(json: String) {
            main.post {
                val e = runCatching { org.json.JSONObject(json) }.getOrNull()
                if (e != null && !e.optBoolean("ready") && bootError == null) {
                    bootError = "${e.optString("message").take(300)}${e.optString("file").takeIf { it.isNotEmpty() }?.let { " ($it:${e.optInt("line")})" } ?: ""}"
                }
                ShellErrors.report(context, mode ?: "home", json)
            }
        }

        fun ready(page: String) {
            main.post {
                bootReady = true
                val queued = onReady.toList(); onReady.clear(); queued.forEach { it() }
            }
        }
    }

    /** Runs [f] on the main thread once the page has said it's ready (now, if it already has): an event sent before
     * that (a cold start's intent) would reach a page that isn't listening yet. */
    private val onReady = mutableListOf<() -> Unit>()
    fun whenReady(f: () -> Unit) { main.post { if (bootReady) f() else onReady.add(f) } }

    /**
     * A load started: the page has [BOOT_ERROR_MS] to be ready if it reported an error meanwhile, [BOOT_MS] if not
     * (an old page without the guard, a slow start: its window.__powosAlive is asked before it's judged). Not judged
     * with the screen off (a page may be throttled then).
     */
    private fun bootStarted() {
        val serial = ++bootSerial
        bootReady = false
        bootFailed = false
        bootError = null
        // On the main handler, not web.postDelayed: a WebView in no window (GateTest's) never runs what's posted to it.
        main.postDelayed({ checkBoot(serial, BOOT_ERROR_MS) }, BOOT_ERROR_MS)
        main.postDelayed({ checkBoot(serial, BOOT_MS) }, BOOT_MS)
    }

    private fun checkBoot(
        serial: Int,
        after: Long,
    ) {
        if (serial != bootSerial || bootReady || bootFailed) return
        if (after < BOOT_MS && bootError == null) return
        if (!context.getSystemService(android.os.PowerManager::class.java).isInteractive) {
            main.postDelayed({ checkBoot(serial, after) }, 2_000)
            return
        }
        PageWatchdog.probe(web) { alive, _ ->
            if (serial != bootSerial || bootReady || bootFailed) return@probe
            if (alive) {
                bootReady = true
                ShellErrors.markReady(context, mode ?: "home")
                return@probe
            }
            if (bootError == null && after < BOOT_SLOW_MS) {
                main.postDelayed({ checkBoot(serial, BOOT_SLOW_MS) }, BOOT_SLOW_MS - after)
                return@probe
            }
            bootFailed = true
            val cause = bootError ?: "no window.__powosAlive ${after / 1000} s after the page started loading, and no error reported"
            ShellErrors.notReady(context, mode ?: "home", "${after / 1000} s after load: $cause")
            // Broken right after a hot push: the push rolled back, every page loaded again on what was there before.
            if (ShellErrors.rollback(context, mode ?: "home", cause).isNotEmpty()) main.postDelayed({ HotReload.reloadAll() }, 300)
        }
    }

    /** The page again, from scratch (after a rollback: its modules as they are now) - only one that isn't up: a live
     * page reloads itself on the rollback's files.changed (hot.ts), or isn't affected at all (a test page's). */
    /**
     * A host whose window is kept warm hidden (the overlays: system/OverlayReload) does a shell push's reload itself:
     * true from it for a changed path means the page isn't told (its hot.ts would reload only once shown).
     */
    var filesGate: ((String) -> Boolean)? = null

    internal fun reloadIfDown() {
        if (!bootReady) web.reload()
    }

    /** The app, for what outlives a page (GateTest). */
    internal val appContext: Context get() = context.applicationContext

    private fun devUrl(): String? =
        devUrlFile.takeIf { it.isFile }?.readText()?.trim()?.takeIf { it.startsWith("http://") || it.startsWith("https://") }

    /** Serves [ORIGIN]: the shell's files, and app icons at /_icon/<key>. */
    private inner class Client : WebViewClient() {
        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest,
        ): WebResourceResponse? {
            val url = request.url
            if ("${url.scheme}://${url.host}" != ORIGIN) return null
            val path = url.path.orEmpty().trimStart('/').ifEmpty { "index.html" }
            if (path.startsWith("_icon/")) return icon(URLDecoder.decode(path.removePrefix("_icon/"), "UTF-8"))
            if (path.startsWith("_wimg/")) {
                val rest = path.removePrefix("_wimg/")
                return widgetImage(URLDecoder.decode(rest.substringBefore('/'), "UTF-8"), URLDecoder.decode(rest.substringAfter('/'), "UTF-8"))
            }
            if (path.startsWith("_font/")) return font(path.removePrefix("_font/"))
            // The wallpaper's picture, for the glass (ShellWallpaper; the URL names its revision: kept).
            if (path == "_wallpaper") {
                val jpeg = ShellWallpaper.jpeg(context) ?: return notFound()
                return WebResourceResponse("image/jpeg", null, ByteArrayInputStream(jpeg)).apply { responseHeaders = mapOf("Cache-Control" to "max-age=31536000") }
            }
            // What's playing's album art, for the control center's media card (its id from media.state).
            if (path.startsWith("_media/")) {
                val bitmap = runtime.widgets.media.art(URLDecoder.decode(path.removePrefix("_media/"), "UTF-8")) ?: return notFound()
                val png = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
                return WebResourceResponse("image/png", null, ByteArrayInputStream(png)).apply { responseHeaders = mapOf("Cache-Control" to "no-store") }
            }
            // The assistant's screenshot of the screen it was opened over (PowosAssistSession writes it).
            if (path.startsWith("_assist/")) {
                val file = File(File(context.cacheDir, "assist"), path.removePrefix("_assist/").substringAfterLast('/'))
                return if (file.isFile) WebResourceResponse("image/jpeg", null, file.inputStream()).apply { responseHeaders = mapOf("Cache-Control" to "no-store") } else notFound()
            }
            // A review image for PowOS AI's page (QaFiles: a bare name of design-qa's, never decoded, checked inside it).
            if (path.startsWith("_qa/")) return qaImage(url.encodedPath.orEmpty().substringAfter("/_qa/"))
            // An image sent to PowOS AI (its screen, the part circled, a share): the same checks, in the app's own run dir.
            if (path.startsWith("_shared/")) {
                val raw = url.encodedPath.orEmpty().substringAfter("/_shared/")
                val file = QaFiles.resolve(File(context.filesDir, QaFiles.SHARED), raw) ?: return notFound()
                val type = if (raw.endsWith(".png")) "image/png" else "image/jpeg"
                return WebResourceResponse(type, null, file.inputStream()).apply { responseHeaders = mapOf("Cache-Control" to "max-age=86400") }
            }
            // A recent task's last frame, for the switcher (on the WebView's loader thread: the snapshot is a binder call).
            if (path.startsWith("_task/")) {
                val id = path.removePrefix("_task/").toIntOrNull() ?: return notFound()
                // A web window (on its own display): its content now, as any app's card - never an empty card.
                WebWindows.cardShot(context, id)?.let { return WebResourceResponse("image/jpeg", null, ByteArrayInputStream(it)).apply { responseHeaders = mapOf("Cache-Control" to "max-age=86400") } }
                // A floating window in sight is never sent to the back, so the system's snapshot of it is from long ago
                // (its full-screen time, its size before a resize): taken now instead.
                if (dev.omalauncher.system.AppWindows.floating(context) && dev.omalauncher.system.FreeformTasks.list(context).any { it.id == id && it.visible }) {
                    dev.omalauncher.system.Tasks.capture(id)
                }
                val jpeg = dev.omalauncher.system.Tasks.snapshot(id) ?: return notFound()
                // The URL names the snapshot's version (?v=, the task's last time in front, or a fresh capture's): kept.
                return WebResourceResponse("image/jpeg", null, ByteArrayInputStream(jpeg)).apply { responseHeaders = mapOf("Cache-Control" to "max-age=86400") }
            }
            // An Android widget's latest frame (AppWidgets draws it off screen), and a widget's preview for the picker.
            if (path.startsWith("_appwidget/")) {
                val frame = path.removePrefix("_appwidget/").toIntOrNull()?.let { AppWidgets.get(context).frameStream(it) } ?: return notFound()
                return WebResourceResponse(AppWidgets.FRAME_TYPE, null, frame).apply { responseHeaders = mapOf("Cache-Control" to "no-store") }
            }
            if (path.startsWith("_awpreview/")) {
                val png = AppWidgets.get(context).previewPng(URLDecoder.decode(path.removePrefix("_awpreview/"), "UTF-8")) ?: return notFound()
                return WebResourceResponse("image/png", null, ByteArrayInputStream(png)).apply { responseHeaders = mapOf("Cache-Control" to "max-age=3600") }
            }
            // What settings' screens show: theme previews, backgrounds, store previews (ShellScreens.image).
            if (path.startsWith("_screens/")) {
                val rest = path.removePrefix("_screens/")
                val (type, bytes) = bridge.screens.image(rest.substringBefore('/'), URLDecoder.decode(rest.substringAfter('/'), "UTF-8")) ?: return notFound()
                return WebResourceResponse(type, null, ByteArrayInputStream(bytes)).apply { responseHeaders = mapOf("Cache-Control" to "max-age=3600") }
            }
            if (".." in path.split('/')) return notFound()
            // A PowOS app's own files (`powos app install`: files/apps/<id>/current/ui/), for its islands on home
            // (shell/ui/island.tsx) - the same origin as the page, so it imports them as its own modules.
            if (path.startsWith("_app/")) return appFile(path.removePrefix("_app/"))
            val stream = open(path) ?: return notFound()
            return WebResourceResponse(mime(path), "utf-8", stream).apply {
                // Always the file as it is now: an edit must show on the next load, not a cached copy.
                responseHeaders = mapOf("Cache-Control" to "no-store", "Access-Control-Allow-Origin" to ORIGIN)
            }
        }

        override fun onPageStarted(
            view: WebView,
            url: String?,
            favicon: Bitmap?,
        ) {
            super.onPageStarted(view, url, favicon)
            bootStarted()
        }

        /**
         * The shell's own pages load (its reload, for hot reload, counts as a navigation: refusing it left every edit
         * unshown); anything else doesn't - links go nowhere from home.
         */
        override fun shouldOverrideUrlLoading(
            view: WebView,
            request: WebResourceRequest,
        ) = "${request.url.scheme}://${request.url.host}" != ORIGIN
    }

    /** One file of an installed PowOS app's UI: "<app id>/<path>", never outside that app's current version. */
    private fun appFile(rest: String): WebResourceResponse {
        val id = rest.substringBefore('/')
        val name = rest.substringAfter('/', "")
        if (!APP_ID.matches(id) || name.isEmpty()) return notFound()
        val ui = File(context.filesDir, "apps/$id/current/ui")
        val file = File(ui, name)
        if (!file.isFile || !file.canonicalPath.startsWith(ui.canonicalPath + "/")) return notFound()
        return WebResourceResponse(mime(name), "utf-8", file.inputStream()).apply { responseHeaders = mapOf("Cache-Control" to "no-store") }
    }

    /** The override folder's file, else the shipped one. */
    private fun open(path: String): InputStream? {
        File(overrides, path).takeIf { it.isFile }?.let { return it.inputStream() }
        return runCatching { context.assets.open("shell/$path") }.getOrNull()
    }

    /**
     * An app's icon: by name (ShellIcons' file, which never changes - kept by the page for good), or, until it has
     * one, by key from the catalog as it is now (a 404 while it isn't drawn).
     */
    private fun icon(key: String): WebResourceResponse {
        ShellIcons.file(key)?.let { file ->
            return WebResourceResponse("image/png", null, file.inputStream()).apply {
                responseHeaders = mapOf("Cache-Control" to "public, max-age=31536000, immutable")
            }
        }
        val bitmap =
            when {
                key.startsWith("a:") -> runtime.androidApps.icons[key.removePrefix("a:")]
                key.startsWith("l:") -> runtime.linuxIcons[key.removePrefix("l:")]
                else -> null
            } ?: return notFound()
        val png = ByteArrayOutputStream().also { bitmap.asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        return WebResourceResponse("image/png", null, ByteArrayInputStream(png)).apply {
            responseHeaders = mapOf("Cache-Control" to "no-cache")
        }
    }

    /** A widget's Image src (a file, media: art, an icon), as its instance loads it for the Compose tile. */
    private fun widgetImage(
        key: String,
        src: String,
    ): WebResourceResponse {
        val engine = runtime.widgets
        val inst = engine.specs.firstOrNull { it.file.name == key }?.let(engine::instance) ?: return notFound()
        val bitmap = inst.image(src) ?: return notFound()
        val png = ByteArrayOutputStream().also { bitmap.asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        return WebResourceResponse("image/png", null, ByteArrayInputStream(png)).apply { responseHeaders = mapOf("Cache-Control" to "no-store") }
    }

    /**
     * The terminal font (PtyTerminal's copy of PowOS's file for the family named, "terminal/<family>") or the Nerd
     * Font symbols ("symbols"), for the page's terminals.
     */
    private fun font(name: String): WebResourceResponse {
        val stream =
            when {
                name == "symbols" -> context.resources.openRawResource(R.font.nerd_symbols)
                name.startsWith("terminal/") ->
                    PtyTerminal.fontFile(context, URLDecoder.decode(name.removePrefix("terminal/"), "UTF-8")) {}?.inputStream()
                else -> null
            } ?: return notFound()
        return WebResourceResponse("font/ttf", null, stream).apply { responseHeaders = mapOf("Cache-Control" to "max-age=3600", "Access-Control-Allow-Origin" to ORIGIN) }
    }

    /** When the root shell last refreshed the cache's copy of design-qa (at most every few seconds). */
    @Volatile private var qaSynced = 0L

    private fun qaImage(raw: String): WebResourceResponse {
        val type = if (raw.endsWith(".png")) "image/png" else "image/jpeg"
        val serve = { f: File -> WebResourceResponse(type, null, f.inputStream()).apply { responseHeaders = mapOf("Cache-Control" to "no-store") } }
        // Readable as it is (the app's domain may read PowOS's files): straight from the folder.
        QaFiles.resolve(File(QaFiles.DIR), raw)?.let { f -> runCatching { f.inputStream().close() }.onSuccess { return serve(f) } }
        val cache = File(context.cacheDir, "qa")
        QaFiles.resolve(cache, raw)?.let { return serve(it) }
        if (System.currentTimeMillis() - qaSynced > 5_000) {
            qaSynced = System.currentTimeMillis()
            runCatching { andro.marchy.RootShell.run(QaFiles.sync(cache), null, 20_000) }
        }
        return QaFiles.resolve(cache, raw)?.let(serve) ?: notFound()
    }

    private fun notFound() = WebResourceResponse("text/plain", "utf-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    private fun mime(path: String) =
        when (path.substringAfterLast('.').lowercase()) {
            "html" -> "text/html"
            "js", "mjs" -> "text/javascript"
            // TypeScript: the page transpiles it itself (index.html's loader).
            "ts", "tsx" -> "text/plain"
            "css" -> "text/css"
            "json" -> "application/json"
            // (WebAssembly.instantiateStreaming refuses anything else)
            "wasm" -> "application/wasm"
            "svg" -> "image/svg+xml"
            "png" -> "image/png"
            "webp" -> "image/webp"
            "woff2" -> "font/woff2"
            "ttf" -> "font/ttf"
            else -> "application/octet-stream"
        }

    companion object {
        private const val TAG = "PowosShell"

        /** A page that reported an error has this long to be ready; one that didn't, [BOOT_MS] - and if it's still not
         *  up then with no error, [BOOT_SLOW_MS]: a slow start, not a broken one (a cold boot after the battery ran out:
         *  load 13, the low-memory killer busy, a renderer restarted - five pages "not ready" at 8 s, all fine by 20 s,
         *  2026-10-21). A broken page reports its error and is judged at [BOOT_ERROR_MS] as before. */
        private const val BOOT_ERROR_MS = 3_000L
        private const val BOOT_MS = 8_000L
        private const val BOOT_SLOW_MS = 20_000L

        /** Where the page lives: never resolved, every request is answered from the app. */
        const val ORIGIN = ShellOrigin.SHELL

        /** A PowOS app's id (powos-app.json; the registry allows the same). */
        private val APP_ID = Regex("[a-z0-9.-]{1,64}")
    }
}

/**
 * Hot reload, for every page the process shows (home, the shade, the lock screen, the switcher, the assistant): one
 * watcher on the override folder, its changes to each [ShellHost] ("files.changed"). One, not one per page: FileObserver
 * keeps a single inotify watch per path in a process, so a second observer on the folder took the events from the
 * first - only the page made last reloaded.
 */
private object HotReload {
    private val main = Handler(Looper.getMainLooper())
    private val hosts = mutableSetOf<ShellHost>()
    private val watchers = mutableListOf<FileObserver>()
    private var overrides: File? = null

    fun add(host: ShellHost) {
        hosts += host
        if (overrides != null) return
        val dir = File(host.filesDir, "shell").also { overrides = it }
        watch(dir, dir, "")
        // PowOS apps' installed UIs (files/apps/<id>/current/ui): a new version or a changed file reloads the pages
        // showing their islands, as "_app/<id>/..." (the path the page loads them by, ShellHost.appFile).
        val apps = File(host.filesDir, "apps").also { it.mkdirs() }
        watch(apps, apps, "_app/")
        // The override folder deleted and made again (a reset): watch the new one - the old watchers went with it.
        watchers +=
            object : FileObserver(host.filesDir, CREATE or MOVED_TO) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    if (path == dir.name) main.post { watch(dir, dir, "") }
                }
            }.also { it.startWatching() }
    }

    fun remove(host: ShellHost) {
        hosts -= host
    }

    /** Every page that isn't up loaded again (a rollback: a dead page's hot.ts can't reload it). */
    fun reloadAll() {
        for (h in hosts.toList()) h.reloadIfDown()
    }

    /**
     * Every directory under [root] (the override folder, the apps), since FileObserver isn't recursive; a change is
     * sent as its path under [root] after [prefix]. Links aren't followed: an app's `current` points at a version dir
     * watched already (one inotify watch per inode in a process - a second observer would take the first's events).
     */
    private fun watch(
        dir: File,
        root: File,
        prefix: String,
    ) {
        val observer =
            object : FileObserver(dir, CLOSE_WRITE or MOVED_TO or DELETE or CREATE) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    val file = File(dir, path ?: return)
                    if (event and (CREATE or MOVED_TO) != 0 && file.isDirectory && !isLink(file)) {
                        main.post {
                            watch(file, root, prefix)
                            // Written before its watcher started (a push making the folder, then a file in it at once):
                            // those changes, which no watcher saw.
                            file.walkTopDown().filter { it.isFile }.forEach { changed(it, root, prefix) }
                        }
                    }
                    if (event and (CLOSE_WRITE or MOVED_TO or DELETE) != 0) main.post { changed(file, root, prefix) }
                }
            }
        observer.startWatching()
        watchers += observer
        dir.listFiles()?.filter { it.isDirectory && !isLink(it) }?.forEach { watch(it, root, prefix) }
    }

    private fun isLink(f: File) = java.nio.file.Files.isSymbolicLink(f.toPath())

    private fun changed(
        file: File,
        root: File,
        prefix: String,
    ) {
        val path = prefix + file.relativeTo(root).path
        // push.sh's commit marker: while files/shell/.pushing is there a push's files are being moved in, so their
        // changes are held and sent together when it goes - a page reloaded halfway through a push imported a module
        // not there yet (a 404, the push rolled back). A marker left behind (a push killed) is let go after
        // PUSH_HOLD_MS.
        if (prefix.isEmpty() && path == PUSHING) {
            if (file.exists()) {
                holding = true
                main.removeCallbacks(releaseLater)
                main.postDelayed(releaseLater, PUSH_HOLD_MS)
            } else {
                release.run()
            }
            return
        }
        if (holding && prefix.isEmpty()) {
            held[path] = file
            return
        }
        Log.i(TAG, "changed: $path (${hosts.size} pages)")
        // The test-only page: loaded off screen for the test (GateTest), never in a live page.
        if (path == GateTest.FILE && file.isFile) hosts.firstOrNull()?.appContext?.let(GateTest::changed)
        for (h in hosts.toList()) if (h.filesGate?.invoke(path) != true) h.bridge.emit("files.changed", mapOf("path" to path))
    }

    private const val PUSHING = ".pushing"
    private const val PUSH_HOLD_MS = 30_000L
    private var holding = false
    private val held = linkedMapOf<String, File>()
    private val release: Runnable =
        Runnable {
            main.removeCallbacks(releaseLater)
            holding = false
            val files = held.values.toList()
            held.clear()
            Log.i(TAG, "push committed: ${files.size} file(s)")
            overrides?.let { root -> files.forEach { changed(it, root, "") } }
            // A page that died at boot never runs hot.ts, so files.changed can't reload it: after every push or reset,
            // each page that isn't up loads again (APK 29878476, 2026-10-23: home stayed dead through every later push).
            reloadAll()
        }

    private val releaseLater: Runnable = Runnable { release.run() }

    private const val TAG = "PowosShell"
}

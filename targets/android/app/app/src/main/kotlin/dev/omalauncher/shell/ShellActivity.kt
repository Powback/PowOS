package dev.omalauncher.shell

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import android.os.FileObserver
import android.util.Log
import android.view.WindowInsets
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.ui.graphics.asAndroidBitmap
import dev.omalauncher.App
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.URLDecoder

/**
 * The launcher as a web UI (the repo's shell/, see shell/DESIGN.md): a full-screen WebView over the wallpaper, with
 * the host API as window.powos ([ShellBridge]).
 *
 * The page is served from [ORIGIN], a name that never reaches the network: each file comes from the override folder
 * ([overrides], where the user or an agent changes the shell - a file there wins over the shipped one) or the copy
 * the APK ships (assets/shell). Saving a file in the override folder hot-reloads it (files.changed).
 *
 * Working on the shell from a computer: a URL in [devUrlFile] (a LAN dev server) is loaded instead. Only that file
 * names it, never an intent - the bridge can launch and uninstall apps, so no other app may point it at a page.
 */
class ShellActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var bridge: ShellBridge
    private val watchers = mutableListOf<FileObserver>()

    private val runtime get() = (application as App).runtime
    private val overrides get() = File(filesDir, "shell")
    private val devUrlFile get() = File(filesDir, "shell-dev-url")

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The launcher's runtime (themes, widgets, the PowOS session), as MainActivity starts it; started once.
        runtime.start()
        overrides.mkdirs()
        window.setDecorFitsSystemWindows(false)
        web =
            WebView(this).apply {
                setBackgroundColor(Color.TRANSPARENT)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                webViewClient = Client()
                webChromeClient =
                    object : WebChromeClient() {
                        override fun onConsoleMessage(m: ConsoleMessage): Boolean {
                            Log.i(TAG, "${m.messageLevel()} ${m.sourceId().substringAfterLast('/')}:${m.lineNumber()} ${m.message()}")
                            return true
                        }
                    }
            }
        bridge = ShellBridge(this, runtime, web)
        web.addJavascriptInterface(bridge, "PowosHost")
        setContentView(web)
        // Insets to the page (CSS px), as they change: the bar sits above the navigation bar, the drawer clears
        // the status bar, the keyboard's height lifts the bar.
        web.setOnApplyWindowInsetsListener { v, insets ->
            bridge.insets(insets)
            v.onApplyWindowInsets(insets)
            WindowInsets.CONSUMED
        }
        watch(overrides)
        // The override folder deleted and made again (a reset): watch the new one - the old watchers went with it.
        watchers +=
            object : FileObserver(filesDir, CREATE or MOVED_TO) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    if (path == overrides.name) runOnUiThread { watch(overrides) }
                }
            }.also { it.startWatching() }
        web.loadUrl(devUrl() ?: "$ORIGIN/index.html")
    }

    private fun devUrl(): String? =
        devUrlFile.takeIf { it.isFile }?.readText()?.trim()?.takeIf { it.startsWith("http://") || it.startsWith("https://") }

    /** Hot reload: every directory of the override folder, since FileObserver isn't recursive. */
    private fun watch(dir: File) {
        val observer =
            object : FileObserver(dir, CLOSE_WRITE or MOVED_TO or DELETE or CREATE) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    val file = File(dir, path ?: return)
                    if (event and CREATE != 0 && file.isDirectory) runOnUiThread { watch(file) }
                    if (event and (CLOSE_WRITE or MOVED_TO or DELETE) != 0) {
                        val changed = file.relativeTo(overrides).path
                        Log.i(TAG, "changed: $changed")
                        bridge.emit("files.changed", mapOf("path" to changed))
                    }
                }
            }
        observer.startWatching()
        watchers += observer
        dir.listFiles()?.filter { it.isDirectory }?.forEach(::watch)
    }

    /**
     * Home pressed while the shell is home already (singleTask: the intent comes back here): the page closes what's
     * open and goes to the first page, as a stock launcher does.
     */
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        if (intent.hasCategory(android.content.Intent.CATEGORY_HOME)) bridge.emit("system.home", null)
    }

    /** Back goes to the page: it closes the drawer, a folder or edit mode. A home screen has nowhere to go back to. */
    @Deprecated("Back reaches the page instead", ReplaceWith(""))
    override fun onBackPressed() {
        bridge.emit("system.back", null)
    }

    // A home screen showing: widgets' sources run (they pause while no home is visible).
    override fun onStart() {
        super.onStart()
        runtime.widgets.homeStarted()
    }

    override fun onStop() {
        super.onStop()
        runtime.widgets.homeStopped()
    }

    override fun onDestroy() {
        watchers.forEach { it.stopWatching() }
        bridge.close()
        web.destroy()
        super.onDestroy()
    }

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
            if (".." in path.split('/')) return notFound()
            val stream = open(path) ?: return notFound()
            return WebResourceResponse(mime(path), "utf-8", stream).apply {
                // Always the file as it is now: an edit must show on the next load, not a cached copy.
                responseHeaders = mapOf("Cache-Control" to "no-store", "Access-Control-Allow-Origin" to ORIGIN)
            }
        }

        override fun shouldOverrideUrlLoading(
            view: WebView,
            request: WebResourceRequest,
        ) = true
    }

    /** The override folder's file, else the shipped one. */
    private fun open(path: String): InputStream? {
        File(overrides, path).takeIf { it.isFile }?.let { return it.inputStream() }
        return runCatching { assets.open("shell/$path") }.getOrNull()
    }

    private fun icon(key: String): WebResourceResponse {
        val bitmap =
            when {
                key.startsWith("a:") -> runtime.androidApps.icons[key.removePrefix("a:")]
                key.startsWith("l:") -> runtime.linuxIcons[key.removePrefix("l:")]
                else -> null
            } ?: return notFound()
        val png = ByteArrayOutputStream().also { bitmap.asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        return WebResourceResponse("image/png", null, ByteArrayInputStream(png)).apply {
            responseHeaders = mapOf("Cache-Control" to "max-age=3600")
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

    private fun notFound() = WebResourceResponse("text/plain", "utf-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    private fun mime(path: String) =
        when (path.substringAfterLast('.').lowercase()) {
            "html" -> "text/html"
            "js", "mjs" -> "text/javascript"
            // TypeScript: the page transpiles it itself (index.html's loader).
            "ts", "tsx" -> "text/plain"
            "css" -> "text/css"
            "json" -> "application/json"
            "svg" -> "image/svg+xml"
            "png" -> "image/png"
            "webp" -> "image/webp"
            "woff2" -> "font/woff2"
            else -> "application/octet-stream"
        }

    companion object {
        private const val TAG = "PowosShell"

        /** Where the page lives: never resolved, every request is answered from the app. */
        const val ORIGIN = "https://shell.powos"
    }
}

package dev.omalauncher.shell

import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * One installed `.pow` web app ([WebApps]) as a standalone window: a WebView on its URL, nothing else (the window's
 * title bar is PowOS's web window chrome). A task per app (documentLaunchMode intoExisting, keyed by the URL), so a
 * web window holds exactly one site. Links to other hosts open in the phone's browser, not in the app's window.
 */
class WebAppActivity : Activity() {
    private lateinit var web: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.dataString ?: return finish()
        val id = WebApps.idOf(url) ?: return finish()
        val app = WebApps.get(this, id)
        val color = app?.theme?.let { runCatching { Color.parseColor(it) }.getOrNull() }
        setTaskDescription(ActivityManager.TaskDescription.Builder().setLabel(app?.name ?: id).apply { if (color != null) setPrimaryColor(color) }.build())
        web = WebView(this)
        web.settings.javaScriptEnabled = true
        web.settings.domStorageEnabled = true
        web.settings.databaseEnabled = true
        web.settings.mediaPlaybackRequiresUserGesture = false
        web.webChromeClient = WebChromeClient()
        web.webViewClient =
            object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    request: WebResourceRequest,
                ): Boolean {
                    val to = request.url
                    if (to.host == id || to.host?.endsWith(".$id") == true) return false
                    // Another site (a login provider, a link out): the browser, not this app's window.
                    runCatching { startActivity(Intent(Intent.ACTION_VIEW, to).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                    return true
                }
            }
        setContentView(web)
        if (savedInstanceState == null || web.restoreState(savedInstanceState) == null) web.loadUrl(url)
    }

    @Deprecated("minSdk 30: OnBackInvokedDispatcher is API 33")
    override fun onBackPressed() {
        @Suppress("DEPRECATION")
        if (web.canGoBack()) web.goBack() else super.onBackPressed()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        web.saveState(outState)
    }

    override fun onDestroy() {
        if (::web.isInitialized) web.destroy()
        super.onDestroy()
    }

    companion object {
        /** [url]'s intent: its own document task (one per site). */
        fun intent(
            context: Context,
            url: String,
        ): Intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).setClass(context, WebAppActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
    }
}

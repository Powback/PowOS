package dev.omalauncher.shell

import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityManager
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.net.http.SslError
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.webkit.GeolocationPermissions
import android.webkit.PermissionRequest
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout

/**
 * One installed `.pow` web app ([WebApps]) as a standalone window: a WebView on its URL, nothing else (the window's
 * title bar is PowOS's web window chrome). A task per app (documentLaunchMode intoExisting, keyed by the URL), so a
 * web window holds exactly one site. Links to other hosts open in the phone's browser, not in the app's window.
 *
 * What a site may use (the user 11-25: "the apps added automatically dont have microphone permissions etc"; docs/
 * WEB_WINDOWS.md "Web app permissions"): the mic, camera, location and MIDI, each asked once per site in PowOS's own
 * dialog ([WebPermissions] the rules, [WebAppPermissions] the grants, revoked from the app's menu), then Android's
 * dialog for what PowOS itself doesn't hold yet. Only the app's own `.pow` host is ever granted. getUserMedia needs a
 * secure context: the app opens on https when its host serves a PowStation-CA cert ([PowCa], [WebAppTls]). Also: file
 * uploads (<input type=file>, Android's picker), full-screen video, autoplay (no user gesture needed).
 */
class WebAppActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var root: FrameLayout
    private lateinit var id: String
    private var label = ""

    /** One site permission ask: [kinds] wanted, [done] gets the ones granted (not called once [gone]). */
    private class Ask(val kinds: List<String>, val done: (List<String>) -> Unit) {
        var gone = false
    }

    private val asks = ArrayDeque<Ask>()
    private var asking: Ask? = null
    private var dialog: AlertDialog? = null
    private val requests = HashMap<PermissionRequest, Ask>()
    private var files: ValueCallback<Array<Uri>>? = null
    private var custom: View? = null
    private var customDone: WebChromeClient.CustomViewCallback? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.dataString ?: return finish()
        id = WebApps.idOf(url) ?: return finish()
        val app = WebApps.get(this, id)
        label = app?.name ?: id
        val color = app?.theme?.let { runCatching { Color.parseColor(it) }.getOrNull() }
        setTaskDescription(ActivityManager.TaskDescription.Builder().setLabel(label).apply { if (color != null) setPrimaryColor(color) }.build())
        web = WebView(this)
        web.settings.javaScriptEnabled = true
        web.settings.domStorageEnabled = true
        web.settings.databaseEnabled = true
        web.settings.mediaPlaybackRequiresUserGesture = false
        web.settings.setGeolocationEnabled(true)
        web.webChromeClient = Chrome()
        web.webViewClient =
            object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    request: WebResourceRequest,
                ): Boolean {
                    val to = request.url
                    if (mine(to.host)) return false
                    // Another site (a login provider, a link out): the browser, not this app's window.
                    runCatching { startActivity(Intent(Intent.ACTION_VIEW, to).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                    return true
                }

                // The PowStation CA, for this app's own .pow hosts only (PowCa): an unknown issuer and nothing else.
                @SuppressLint("WebViewClientOnReceivedSslError")
                override fun onReceivedSslError(
                    view: WebView,
                    handler: SslErrorHandler,
                    error: SslError,
                ) {
                    val host = WebAppSync.hostOf(error.url)
                    val ca = WebAppTls.ca(this@WebAppActivity)
                    if (mine(host) && error.primaryError == SslError.SSL_UNTRUSTED && ca != null && PowCa.trusts(ca, host, error.certificate.x509Certificate)) {
                        handler.proceed()
                    } else {
                        Log.w(TAG, "$id: TLS error ${error.primaryError} on ${error.url}: refused")
                        handler.cancel()
                    }
                }
            }
        root = FrameLayout(this).apply { addView(web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)) }
        setContentView(root)
        if (savedInstanceState != null && web.restoreState(savedInstanceState) != null) return
        WebAppTls.url(this, url) { to -> runOnUiThread { if (!isDestroyed) web.loadUrl(to) } }
    }

    private fun mine(host: String?) = host != null && (host == id || host.endsWith(".$id"))

    private inner class Chrome : WebChromeClient() {
        override fun onPermissionRequest(request: PermissionRequest) {
            val site = WebPermissions.siteOf(request.origin?.toString(), id)
            val kinds = request.resources.mapNotNull(WebPermissions::kindOf).distinct()
            if (site == null || kinds.isEmpty()) {
                Log.i(TAG, "$id: refused ${request.resources.joinToString()} for ${request.origin}")
                return request.deny()
            }
            val a =
                Ask(kinds) { got ->
                    requests.remove(request)
                    val res = got.mapNotNull(WebPermissions::resourceOf).filter { it in request.resources }
                    if (res.isEmpty()) request.deny() else request.grant(res.toTypedArray())
                }
            requests[request] = a
            ask(a)
        }

        override fun onPermissionRequestCanceled(request: PermissionRequest) {
            val a = requests.remove(request) ?: return
            a.gone = true
            // Still only on PowOS's dialog: take it down (Android's own can't be; its answer is simply dropped).
            if (asking === a) dialog?.cancel()
        }

        override fun onGeolocationPermissionsShowPrompt(
            origin: String?,
            callback: GeolocationPermissions.Callback,
        ) {
            if (WebPermissions.siteOf(origin, id) == null) return callback.invoke(origin, false, false)
            // retain=false: the WebView asks again on the next load, so a revoke in the app's menu takes effect.
            ask(Ask(listOf(WebPermissions.LOCATION)) { got -> callback.invoke(origin, WebPermissions.LOCATION in got, false) })
        }

        override fun onShowFileChooser(
            view: WebView,
            callback: ValueCallback<Array<Uri>>,
            params: FileChooserParams,
        ): Boolean {
            files?.onReceiveValue(null)
            files = callback
            @Suppress("DEPRECATION")
            return runCatching { startActivityForResult(params.createIntent(), FILES_REQUEST) }.onFailure {
                Log.w(TAG, "$id: no file picker: ${it.message}")
                files = null
            }.isSuccess
        }

        override fun onShowCustomView(
            view: View,
            callback: CustomViewCallback,
        ) {
            hideCustom()
            custom = view
            customDone = callback
            root.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }

        override fun onHideCustomView() = hideCustom()
    }

    /** Full-screen video's view gone (its own exit button, back). */
    private fun hideCustom() {
        custom?.let { root.removeView(it) }
        custom = null
        customDone?.onCustomViewHidden()
        customDone = null
    }

    private fun ask(a: Ask) {
        asks.addLast(a)
        if (asking == null) next()
    }

    /** The next ask: PowOS's dialog for kinds the site isn't allowed yet, then Android's for what PowOS doesn't hold. */
    private fun next() {
        val a = asks.removeFirstOrNull() ?: return run { asking = null }
        asking = a
        if (a.gone) return next()
        val plan = WebPermissions.plan(a.kinds, WebAppPermissions.of(this, id), ::held)
        if (plan.ask.isEmpty()) return request(a, plan.request)
        dialog =
            AlertDialog.Builder(this)
                .setTitle("Allow $label to use your ${WebPermissions.words(plan.ask)}?")
                .setMessage("$id asks for it. You can take it back in the app's menu on the launcher.")
                .setPositiveButton("Allow") { _, _ ->
                    WebAppPermissions.allow(this, id, plan.ask)
                    Log.i(TAG, "$id: allowed ${plan.ask}")
                    request(a, WebPermissions.plan(a.kinds, WebAppPermissions.of(this, id), ::held).request)
                }
                .setNegativeButton("Don't allow") { _, _ -> answer(a) }
                .setOnCancelListener { answer(a) }
                .show()
    }

    /** Android's own dialog for [perms] PowOS doesn't hold yet (none: answer now). */
    private fun request(
        a: Ask,
        perms: List<String>,
    ) {
        dialog = null
        if (perms.isEmpty() || a.gone) return answer(a)
        requestPermissions(perms.toTypedArray(), PERMS_REQUEST)
    }

    private fun answer(a: Ask) {
        if (asking !== a) return
        dialog = null
        val got = WebPermissions.granted(a.kinds, WebAppPermissions.of(this, id), ::held)
        if (!a.gone) a.done(got)
        asking = null
        next()
    }

    private fun held(permission: String) = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMS_REQUEST) asking?.let(::answer)
    }

    @Deprecated("a plain Activity has no result registry")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != FILES_REQUEST) return
        files?.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(resultCode, data))
        files = null
    }

    @Deprecated("minSdk 30: OnBackInvokedDispatcher is API 33")
    override fun onBackPressed() {
        @Suppress("DEPRECATION")
        when {
            custom != null -> hideCustom()
            web.canGoBack() -> web.goBack()
            else -> super.onBackPressed()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        web.saveState(outState)
    }

    override fun onDestroy() {
        dialog?.dismiss()
        files?.onReceiveValue(null)
        if (::web.isInitialized) web.destroy()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "PowosWebApp"
        private const val PERMS_REQUEST = 51
        private const val FILES_REQUEST = 52

        /** [url]'s intent: its own document task (one per site). */
        fun intent(
            context: Context,
            url: String,
        ): Intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).setClass(context, WebAppActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
    }
}

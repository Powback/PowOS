package dev.omalauncher.shell

import android.app.Activity
import android.os.Bundle
import android.util.Log

/**
 * PowApps' install/uninstall of a `.pow` web app ([WebApps]; issue #8): `startActivityForResult` with action
 * [ACTION_INSTALL] (extras name, url, icon, theme) or [ACTION_UNINSTALL] (url). Only PowApps may call it (the
 * caller's package, from startActivityForResult's calling activity), and only http(s) `.pow` URLs are taken. RESULT_OK:
 * done. No UI of its own.
 */
class WebAppInstallActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val caller = callingActivity?.packageName
        if (caller !in CALLERS) {
            Log.w(TAG, "refused ${intent.action} from ${caller ?: "an unknown caller (not startActivityForResult)"}")
            setResult(RESULT_CANCELED)
            return finish()
        }
        val url = intent.getStringExtra("url").orEmpty()
        val ok =
            when (intent.action) {
                ACTION_INSTALL -> WebApps.install(this, intent.getStringExtra("name").orEmpty(), url, intent.getStringExtra("icon").orEmpty(), intent.getStringExtra("theme").orEmpty())
                ACTION_UNINSTALL -> WebApps.idOf(url)?.let { WebApps.uninstall(this, it) } == true
                else -> false
            }
        setResult(if (ok) RESULT_OK else RESULT_CANCELED)
        finish()
    }

    companion object {
        private const val TAG = "PowosWebApps"
        const val ACTION_INSTALL = "dev.omalauncher.action.INSTALL_WEB_APP"
        const val ACTION_UNINSTALL = "dev.omalauncher.action.UNINSTALL_WEB_APP"

        /** PowApps (android-app-dev projects/powapps), release and debug. */
        private val CALLERS = setOf("com.powapps", "com.powapps.debug")
    }
}

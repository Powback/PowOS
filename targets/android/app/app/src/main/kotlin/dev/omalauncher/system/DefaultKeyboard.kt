package dev.omalauncher.system

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import dev.omalauncher.R
import dev.omalauncher.httpGet
import java.io.File

/**
 * PowOS's keyboard: the swipe keyboard (android-app-dev `projects/swipe-keyboard`, com.swipekeyboard) installed on
 * every phone PowOS runs on and made the default input method once. The source stays in android-app-dev; what the
 * phone gets is what `make build PROJECT=swipe-keyboard` last published to the PowApps store
 * (http://android.pow/apk/swipe-keyboard.apk + .ver). Unit: units/phone-android/swipe-keyboard.json.
 *
 * Always the latest build, never a pin: checked a minute after the app starts and every [PERIOD_MS] after, it takes the
 * store's version when it's newer (upgrades only, [KeyboardPlan.target]). Gated: the downloaded APK must be the
 * keyboard's package at the advertised version, carry its input method service and match the installed signer
 * ([KeyboardPlan.gate]) - else that version is recorded as failed and skipped until a newer one is published. Rollback
 * kept: the installed APK is copied to files/keyboard/rollback.apk before each update; a build that installs but whose
 * input method doesn't come up is rolled back to it (root: `pm install -d`) and skipped from then on.
 *
 * Both paths install the same way the user would get it from PowApps:
 * - rooted (PowOS as priv-app, the PowOS su): `pm install` and the secure settings written directly - no prompt;
 * - no root: Android's PackageInstaller. The first install asks the user (Android's own "install unknown apps" and
 *   install confirmation, through a notification - never an activity started from the background); later updates go
 *   through without one where Android allows it (USER_ACTION_NOT_REQUIRED: PowOS is the installer of record). The
 *   default keyboard can't be set without WRITE_SECURE_SETTINGS, so PowOS asks once, opening Android's keyboard
 *   settings.
 *
 * The default is set once per phone (prefs [KEY_DEFAULT_DONE]): a different keyboard picked after that is the user's
 * choice and stays.
 */
object DefaultKeyboard {
    const val PACKAGE = "com.swipekeyboard"
    const val IME = "com.swipekeyboard/.SwipeKeyboardService"
    const val STORE = "http://android.pow/apk/swipe-keyboard"

    private const val TAG = "PowosKeyboard"
    private const val PERIOD_MS = 6 * 3600_000L
    private const val FIRST_DELAY_MS = 60_000L
    private const val PREFS = "default-keyboard"
    private const val KEY_FAILED = "failed"
    private const val KEY_DEFAULT_DONE = "defaultDone"
    private const val KEY_ASKED_INSTALL = "askedInstall"
    private const val KEY_PENDING = "pending"
    private const val ACTION_RESULT = "com.powos.app.KEYBOARD_INSTALL_RESULT"
    private const val CHANNEL = "keyboard"
    private const val NOTE_ID = 0x4b42

    @Volatile private var started = false

    /** Starts the checks (App.onCreate); in the main process only (the engine's ":restart" runs App too). */
    fun start(context: Context) {
        if (started || android.app.Application.getProcessName() != context.packageName) return
        started = true
        val app = context.applicationContext
        val filter = IntentFilter(ACTION_RESULT)
        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(
                    c: Context,
                    intent: Intent,
                ) = installResult(app, intent)
            }
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED) else app.registerReceiver(receiver, filter)
        Thread({
            Thread.sleep(FIRST_DELAY_MS)
            while (true) {
                runCatching { check(app) }.onFailure { Log.w(TAG, "check failed", it) }
                Thread.sleep(PERIOD_MS)
            }
        }, "powos-keyboard").apply { isDaemon = true }.start()
    }

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun failed(c: Context): Set<Long> = prefs(c).getStringSet(KEY_FAILED, emptySet()).orEmpty().mapNotNull { it.toLongOrNull() }.toSet()

    private fun markFailed(
        c: Context,
        version: Long,
        why: String,
    ) {
        Log.w(TAG, "swipe keyboard $version refused: $why")
        prefs(c).edit().putStringSet(KEY_FAILED, failed(c).map { it.toString() }.toSet() + version.toString()).apply()
    }

    private fun installed(c: Context): PackageInfo? =
        runCatching { c.packageManager.getPackageInfo(PACKAGE, PackageManager.GET_SIGNING_CERTIFICATES) }.getOrNull()

    private fun dir(c: Context) = File(c.filesDir, "keyboard").apply { mkdirs() }

    /** One pass: update if the store has a newer build, then the default. Blocking (network, root shell). */
    @Synchronized
    fun check(c: Context) {
        val published =
            runCatching { KeyboardPlan.parseVersion(String(httpGet("$STORE.ver"))) }
                .onFailure { Log.i(TAG, "store unreachable: ${it.message}") }.getOrNull()
        val have = installed(c)
        val target = KeyboardPlan.target(have?.longVersionCode, published, failed(c))
        if (target != null) update(c, have, target)
        if (installed(c) != null) applyDefault(c)
    }

    private fun update(
        c: Context,
        have: PackageInfo?,
        target: Long,
    ) {
        val apk = File(dir(c), "swipe-keyboard-$target.apk")
        val part = File(apk.path + ".part")
        part.writeBytes(httpGet("$STORE.apk", readTimeout = 120_000))
        part.renameTo(apk)
        dir(c).listFiles()?.filter { it.name.startsWith("swipe-keyboard-") && it != apk }?.forEach { it.delete() }

        val archive =
            c.packageManager.getPackageArchiveInfo(
                apk.path,
                PackageManager.GET_SERVICES or PackageManager.GET_SIGNING_CERTIFICATES,
            )
        val hasIme = archive?.services.orEmpty().any { it.permission == Manifest.permission.BIND_INPUT_METHOD }
        val signerMatches = have?.let { sameSigner(it, archive) }
        KeyboardPlan.gate(KeyboardPlan.Archive(archive?.packageName, archive?.longVersionCode ?: 0, hasIme, signerMatches), target)?.let { why ->
            markFailed(c, target, why)
            apk.delete()
            return
        }
        // Rollback kept: the build that works now, before it's replaced.
        have?.applicationInfo?.sourceDir?.let { src -> runCatching { File(src).copyTo(File(dir(c), "rollback.apk"), overwrite = true) } }

        if (andro.marchy.RootMode.enabled()) {
            val r = andro.marchy.RootShell.run("cat '${apk.path}' | pm install -r -i ${c.packageName} -S ${apk.length()}")
            Log.i(TAG, "pm install $target: ${r.output}")
            apk.delete()
            if (r.code == 0 && r.output.contains("Success")) healthCheck(c, target) else markFailed(c, target, "pm install: ${r.output}")
        } else {
            installUnrooted(c, apk, target)
        }
    }

    private fun sameSigner(
        have: PackageInfo,
        archive: PackageInfo?,
    ): Boolean {
        val a = have.signingInfo?.apkContentsSigners?.map { it.toCharsString() }?.toSet().orEmpty()
        val b = archive?.signingInfo?.apkContentsSigners?.map { it.toCharsString() }?.toSet().orEmpty()
        return a.isNotEmpty() && a == b
    }

    private fun installUnrooted(
        c: Context,
        apk: File,
        target: Long,
    ) {
        if (!c.packageManager.canRequestPackageInstalls()) {
            // Android's "install unknown apps" for PowOS, asked once per version through a notification.
            if (prefs(c).getLong(KEY_ASKED_INSTALL, 0) != target) {
                prefs(c).edit().putLong(KEY_ASKED_INSTALL, target).apply()
                notify(
                    c,
                    "Install PowOS's keyboard",
                    "Allow PowOS to install apps, for the swipe keyboard and its updates",
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${c.packageName}")),
                )
            }
            return
        }
        val installer = c.packageManager.packageInstaller
        val params =
            PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                setAppPackageName(PACKAGE)
                if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        val id = installer.createSession(params)
        installer.openSession(id).use { s ->
            apk.inputStream().use { input -> s.openWrite("base.apk", 0, apk.length()).use { out -> input.copyTo(out); s.fsync(out) } }
            prefs(c).edit().putLong(KEY_PENDING, target).apply()
            val result =
                PendingIntent.getBroadcast(
                    c,
                    id,
                    Intent(ACTION_RESULT).setPackage(c.packageName),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
            s.commit(result.intentSender)
        }
    }

    private fun installResult(
        c: Context,
        intent: Intent,
    ) {
        val target = prefs(c).getLong(KEY_PENDING, 0)
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Android wants the user's OK (the first install): its confirmation, from a notification.
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                notify(c, "Install PowOS's keyboard", "The swipe keyboard: tap to install", confirm)
            }
            PackageInstaller.STATUS_SUCCESS -> {
                cancelNote(c)
                Thread({ runCatching { healthCheck(c, target); applyDefault(c) } }, "powos-keyboard-done").start()
            }
            PackageInstaller.STATUS_FAILURE_ABORTED -> Log.i(TAG, "install of $target declined; asked again on the next check")
            else -> if (target > 0) markFailed(c, target, "PackageInstaller status $status: ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}")
        }
        File(dir(c), "swipe-keyboard-$target.apk").delete()
    }

    /** The installed build is [target] and its input method is there; otherwise skip it and go back to the kept one. */
    private fun healthCheck(
        c: Context,
        target: Long,
    ) {
        val have = installed(c)
        val ime =
            c.packageManager.queryIntentServices(Intent("android.view.InputMethod").setPackage(PACKAGE), 0)
                .any { it.serviceInfo.permission == Manifest.permission.BIND_INPUT_METHOD }
        if (have?.longVersionCode == target && ime) {
            Log.i(TAG, "swipe keyboard $target installed")
            return
        }
        markFailed(c, target, "installed but its input method isn't there (version ${have?.longVersionCode})")
        val rollback = File(dir(c), "rollback.apk")
        if (rollback.isFile && andro.marchy.RootMode.enabled()) {
            val r = andro.marchy.RootShell.run("cat '${rollback.path}' | pm install -r -d -i ${c.packageName} -S ${rollback.length()}")
            Log.w(TAG, "rolled back to the kept build: ${r.output}")
        } else {
            // HACK: without root Android allows no downgrade (setRequestDowngrade needs INSTALL_PACKAGES); the broken
            // build stays until the next publish. Real fix: the publish gate in android-app-dev (an IME smoke test
            // before `make build PROJECT=swipe-keyboard` publishes), so a build without the service never reaches the store.
            notify(c, "Keyboard update failed", "The swipe keyboard update didn't start; PowOS takes the next build", null)
        }
    }

    private fun canWriteSecure(c: Context) =
        c.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    private fun applyDefault(c: Context) {
        val r = c.contentResolver
        val enabled = runCatching { Settings.Secure.getString(r, Settings.Secure.ENABLED_INPUT_METHODS) }.getOrNull()
        val current = runCatching { Settings.Secure.getString(r, Settings.Secure.DEFAULT_INPUT_METHOD) }.getOrNull()
        val done = prefs(c).getBoolean(KEY_DEFAULT_DONE, false)
        val state = KeyboardPlan.State(installed(c) != null, enabled, current, done, canWriteSecure(c) || andro.marchy.RootMode.enabled())
        when (val d = KeyboardPlan.default(state)) {
            KeyboardPlan.Default.None -> if (KeyboardPlan.isIme(current) && !done) markDefaultDone(c)
            is KeyboardPlan.Default.Write -> if (writeDefault(c, d).also { Log.i(TAG, "default keyboard -> ${d.default}: $it (was $current)") }) markDefaultDone(c)
            KeyboardPlan.Default.Ask -> {
                // Once: a no is the user's choice too.
                markDefaultDone(c)
                notify(
                    c,
                    "PowOS's keyboard is installed",
                    "Turn on Swipe Keyboard and pick it as your keyboard",
                    Intent(Settings.ACTION_INPUT_METHOD_SETTINGS),
                )
            }
        }
    }

    private fun markDefaultDone(c: Context) = prefs(c).edit().putBoolean(KEY_DEFAULT_DONE, true).apply()

    /** The secure settings themselves when PowOS holds WRITE_SECURE_SETTINGS, else Android's `ime` as root. */
    private fun writeDefault(
        c: Context,
        d: KeyboardPlan.Default.Write,
    ): Boolean {
        if (!canWriteSecure(c)) return andro.marchy.RootShell.run("ime enable '${d.default}' && ime set '${d.default}'").code == 0
        val r = c.contentResolver
        return runCatching {
            Settings.Secure.putString(r, Settings.Secure.ENABLED_INPUT_METHODS, d.enabled)
            Settings.Secure.putString(r, Settings.Secure.DEFAULT_INPUT_METHOD, d.default)
        }.isSuccess
    }

    private fun notify(
        c: Context,
        title: String,
        text: String,
        open: Intent?,
    ) {
        val nm = c.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Keyboard", NotificationManager.IMPORTANCE_DEFAULT))
        val b =
            Notification.Builder(c, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(text)
                .setAutoCancel(true)
        open?.let {
            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            b.setContentIntent(PendingIntent.getActivity(c, NOTE_ID, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        }
        runCatching { nm.notify(NOTE_ID, b.build()) }
    }

    private fun cancelNote(c: Context) {
        c.getSystemService(NotificationManager::class.java)?.cancel(NOTE_ID)
    }
}

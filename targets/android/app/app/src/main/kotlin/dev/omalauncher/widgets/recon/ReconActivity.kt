package dev.omalauncher.widgets.recon

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.UserHandle
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * The screens a recon needs the user for, over whatever is showing: Android's "allow PowOS to create widgets"
 * dialog (ACTION_APPWIDGET_BIND; ticking "always allow" makes later recons silent), or the widget's own setup.
 * Invisible itself; reports the answer to [WidgetRecon] and closes.
 */
class ReconActivity : Activity() {
    private val id get() = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val recon = WidgetRecon.get(this)
        recon.promptShown()
        // Recreated (rotation) while the prompt is open: its result still comes to onActivityResult.
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
                    startActivityForResult(bind, REQUEST)
                }
                CONFIGURE -> recon.host.startAppWidgetConfigureActivityForResult(this, id, 0, REQUEST, null)
                else -> done(false)
            }
        } catch (e: Exception) {
            // No such screen, or the provider's configure activity isn't exported to us.
            Log.w("widget-recon", "prompt failed", e)
            done(false)
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
        if (requestCode == REQUEST) done(resultCode == RESULT_OK)
    }

    private fun done(ok: Boolean) {
        WidgetRecon.get(this).promptAnswered(id, ok)
        finish()
    }

    companion object {
        const val MODE = "mode"
        const val BIND = "bind"
        const val CONFIGURE = "configure"
        private const val REQUEST = 1
    }
}

/**
 * Recon from adb, guarded by the DUMP permission (adb's shell has it, apps don't):
 *
 * ```
 * adb shell am broadcast -n com.powos.app/dev.omalauncher.widgets.recon.ReconReceiver --es list ''
 * adb shell am broadcast -n com.powos.app/dev.omalauncher.widgets.recon.ReconReceiver \
 *     --es provider com.google.android.deskclock/com.android.alarmclock.DigitalAppWidgetProvider [--ei width 300 --ei height 120] [--ei seconds 10] [--ez configure true] [--ez static true]
 * ```
 *
 * It returns at once; the result lands in /sdcard/Android/data/com.powos.app/files/widget-recon/ (providers.txt,
 * <provider>/, and last.txt: `ok <folder>` or `error: ...` when it's done), as well as in the guest's .recon.
 */
class ReconReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        val recon = WidgetRecon.get(context)
        val widgets = dev.omalauncher.LauncherData.widgetsDir(context)
        val dir = File(widgets, WidgetRecon.DIR)
        val external = File(context.getExternalFilesDir(null), "widget-recon")
        val args =
            buildMap {
                intent.getStringExtra("provider")?.let { put("provider", it) }
                intent.getIntExtra("width", 0).takeIf { it > 0 }?.let { put("width", it.toString()) }
                intent.getIntExtra("height", 0).takeIf { it > 0 }?.let { put("height", it.toString()) }
                intent.getIntExtra("seconds", 0).takeIf { it > 0 }?.let { put("seconds", it.toString()) }
                if (intent.getBooleanExtra("configure", false)) put("configure", "1")
                if (intent.getBooleanExtra("static", false)) put("static", "1")
            }
        val list = intent.hasExtra("list")
        val filter = intent.getStringExtra("list").orEmpty()
        recon.launch {
            val last = File(external, "last.txt")
            val result =
                try {
                    withContext(Dispatchers.IO) {
                        external.mkdirs()
                        last.delete()
                    }
                    if (list) {
                        val text = recon.list(dir, filter)
                        withContext(Dispatchers.IO) {
                            File(external, "providers.txt").writeText(text + "\n")
                            File(dir, "providers.json").copyTo(File(external, "providers.json"), overwrite = true)
                        }
                        "ok providers.txt"
                    } else {
                        val out = recon.capture(dir, recon.request(args))
                        withContext(Dispatchers.IO) {
                            val target = File(external, out.name)
                            target.deleteRecursively()
                            out.copyRecursively(target, overwrite = true)
                        }
                        "ok ${out.name}\n" + recon.summary(out)
                    }
                } catch (e: WidgetRecon.ReconError) {
                    "error: ${e.message}"
                } catch (e: Exception) {
                    Log.w("widget-recon", "recon failed", e)
                    "error: ${e.javaClass.simpleName}: ${e.message}"
                }
            withContext(Dispatchers.IO) { runCatching { last.writeText(result + "\n") } }
        }
    }
}

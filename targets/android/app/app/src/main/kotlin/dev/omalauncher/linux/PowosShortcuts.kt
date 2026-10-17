package dev.omalauncher.linux

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.util.Log
import java.io.File

/**
 * PowOS's apps as Android's own shortcuts (rooted mode): the most used ones on the PowOS icon's long-press menu, which
 * Android's search and launchers index, and any of them pinned to the phone's home screen ([requestPin]). A shortcut
 * opens its app through [dev.omalauncher.OpenPowosApp], which carries the command, so it works with the launcher not
 * started yet.
 */
object PowosShortcuts {
    private const val TAG = "PowosShortcuts"
    private const val PREFIX = "powos-app:"

    /** The PowOS icon (the desktop): its long-press menu lists them, as an app's own shortcuts. */
    private fun owner(context: Context) = ComponentName(context.packageName, "andro.marchy.MainActivity")

    private fun info(
        context: Context,
        app: LinuxApp,
    ): ShortcutInfo {
        val intent =
            Intent(Intent.ACTION_VIEW)
                .setClassName(context, "dev.omalauncher.OpenPowosApp")
                .putExtra(OPEN_ID, app.id)
                .putExtra(OPEN_NAME, app.name)
                .putExtra(OPEN_EXEC, app.exec)
                .putExtra(OPEN_TERMINAL, app.terminal)
        val icon = app.icon?.let { File(it) }?.takeIf { it.isFile }?.let { BitmapFactory.decodeFile(it.path) }
        return ShortcutInfo.Builder(context, PREFIX + app.id)
            .setShortLabel(app.name)
            .setActivity(owner(context))
            .setIntent(intent)
            .apply { if (icon != null) setIcon(Icon.createWithBitmap(icon)) }
            .build()
    }

    /** Publishes the most used of [apps] ([score] by AppUsage) and refreshes or retires pinned ones. */
    fun publish(
        context: Context,
        apps: List<LinuxApp>,
        score: (LinuxApp) -> Double,
    ) {
        val sm = context.getSystemService(ShortcutManager::class.java) ?: return
        runCatching {
            // Room left beside the static ones (Settings) on the same icon.
            val room = (sm.maxShortcutCountPerActivity - sm.manifestShortcuts.size).coerceAtLeast(0)
            sm.dynamicShortcuts = apps.sortedByDescending(score).take(room).map { info(context, it) }
            // Pinned ones follow their app (new name, icon or command), and go grey once it's uninstalled.
            val byId = apps.associateBy { PREFIX + it.id }
            val pinned = sm.pinnedShortcuts.filter { it.id.startsWith(PREFIX) }
            sm.updateShortcuts(pinned.mapNotNull { byId[it.id]?.let { app -> info(context, app) } })
            val gone = pinned.map { it.id }.filter { it !in byId }
            if (gone.isNotEmpty()) sm.disableShortcuts(gone, "Not installed in PowOS anymore")
        }.onFailure { Log.w(TAG, "publish", it) }
    }

    /** Asks the phone's launcher to pin [app] to its home screen (it shows its own confirmation). */
    fun requestPin(
        context: Context,
        app: LinuxApp,
    ): Boolean {
        val sm = context.getSystemService(ShortcutManager::class.java) ?: return false
        if (!sm.isRequestPinShortcutSupported) return false
        return runCatching { sm.requestPinShortcut(info(context, app), null) }.getOrDefault(false)
    }

    const val OPEN_ID = "powos.app.id"
    const val OPEN_NAME = "powos.app.name"
    const val OPEN_EXEC = "powos.app.exec"
    const val OPEN_TERMINAL = "powos.app.terminal"
}

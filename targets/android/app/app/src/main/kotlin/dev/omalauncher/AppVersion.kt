package dev.omalauncher

import android.content.Context

/**
 * The installed app's version and debuggability, read from the package manager. No BuildConfig (build.gradle.kts turns
 * it off): AGP writes each build's versionCode into BuildConfig.java, and a new one per build recompiled every class
 * that reads it on each warm build.
 */
object AppVersion {
    private fun info(context: Context) = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()

    fun name(context: Context): String = info(context)?.versionName ?: "?"

    fun code(context: Context): Long = info(context)?.longVersionCode ?: 0

    /** A debuggable (debug) build - BuildConfig.DEBUG's meaning, from the installed app's flags. */
    fun debuggable(context: Context): Boolean = context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
}

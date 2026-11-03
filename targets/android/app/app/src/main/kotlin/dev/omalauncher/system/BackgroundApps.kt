package dev.omalauncher.system

import android.app.ActivityManager
import android.app.WallpaperManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.provider.Settings
import android.util.Log

/**
 * The apps that run with no card in the switcher (shell/ui/recents.tsx "Running in background"): the user, 2026-11-03,
 * "I actually do have open apps, they're just running in the background ... like Termux". An Android app is listed
 * when one of its processes does real work - a foreground service (Termux's session, a music player), a started
 * service, perceptible work - but it has no task (no window to swipe away). Cached processes are not (Android ends
 * those itself, and the OPlus freezer keeps them frozen). Never: PowOS itself, system apps (preinstalled and never
 * updated), persistent ones, anything not in the drawer (no launcher entry: services, providers, the framework's
 * helpers), the keyboard, the live wallpaper, accessibility services and notification listeners in use.
 *
 * Read through ActivityManager.getRunningAppProcesses: PowOS is the recents provider, which the system lets see every
 * app's processes (ActivityTaskManagerService.isGetTasksAllowed: the recents component always is).
 */
object BackgroundApps {
    private const val TAG = "PowosBackground"

    /** ActivityManager.RunningAppProcessInfo's IMPORTANCE_* (inlined: the filter stays a plain JVM function). */
    const val IMPORTANCE_FOREGROUND_SERVICE = 125
    const val IMPORTANCE_CACHED = 400

    /** One running process: the packages it runs ([ActivityManager.RunningAppProcessInfo.pkgList]) and its importance. */
    data class Proc(
        val pkgs: List<String>,
        val importance: Int,
    )

    /** What the filter needs of an installed package. [system]: preinstalled and never updated in place. */
    data class Pkg(
        val system: Boolean,
        val persistent: Boolean,
    )

    /**
     * What else decides: PowOS's own package, the packages with a task (they have a card), the drawer's packages, and
     * those that serve the system while in use (keyboard, wallpaper, accessibility, listeners).
     */
    data class Scope(
        val own: String,
        val withTask: Set<String>,
        val launchable: Set<String>,
        val keep: Set<String>,
    )

    /**
     * The packages to list, in the order their processes came: a process doing work ([Proc.importance] from a
     * foreground service up to, not including, cached), of a drawer app with no task, not PowOS, not kept
     * ([Scope]), not system or persistent ([info]).
     */
    fun filter(
        procs: List<Proc>,
        scope: Scope,
        info: (String) -> Pkg?,
    ): List<String> =
        procs
            .asSequence()
            .filter { it.importance in IMPORTANCE_FOREGROUND_SERVICE until IMPORTANCE_CACHED }
            .flatMap { it.pkgs.asSequence() }
            .distinct()
            .filter { it != scope.own && it !in scope.withTask && it in scope.launchable && it !in scope.keep }
            .filter { p -> info(p)?.let { !it.system && !it.persistent } ?: false }
            .toList()

    /** The packages running in the background now ([filter] over the system's process list). */
    fun list(
        context: Context,
        launchable: Set<String>,
    ): List<String> {
        val am = context.getSystemService(ActivityManager::class.java)
        val procs = runCatching { am.runningAppProcesses.orEmpty() }.onFailure { Log.w(TAG, "can't list processes", it) }.getOrDefault(emptyList())
        val pm = context.packageManager
        val out =
            filter(
                procs.map { Proc(it.pkgList?.toList().orEmpty(), it.importance) },
                Scope(context.packageName, RunningApps.tasks.value.toSet(), launchable, keep(context)),
                { p ->
                    runCatching { pm.getApplicationInfo(p, 0) }.getOrNull()?.let {
                        Pkg(it.flags and ApplicationInfo.FLAG_SYSTEM != 0 && it.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP == 0, it.flags and ApplicationInfo.FLAG_PERSISTENT != 0)
                    }
                },
            )
        Log.i(TAG, "${procs.size} processes, background: ${out.joinToString()}")
        return out
    }

    /** Packages that serve the system while in use: the keyboard, the live wallpaper, accessibility, listeners. */
    private fun keep(context: Context): Set<String> {
        val r = context.contentResolver
        val comps = { name: String -> runCatching { Settings.Secure.getString(r, name) }.getOrNull().orEmpty().split(':').map { it.substringBefore('/') } }
        val wallpaper = runCatching { WallpaperManager.getInstance(context).wallpaperInfo?.packageName }.getOrNull()
        return (comps(Settings.Secure.DEFAULT_INPUT_METHOD) + comps("enabled_accessibility_services") + comps("enabled_notification_listeners") + listOfNotNull(wallpaper))
            .filter { it.isNotBlank() }
            .toSet()
    }

    private val PACKAGE = Regex("[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+")

    /**
     * Stops [pkg] as Settings' "Force stop" does: its processes, services, alarms and notifications go. False: not a
     * package name, or the stop failed. Blocking (a root shell): off the main thread.
     */
    fun stop(
        context: Context,
        pkg: String,
    ): Boolean {
        if (!PACKAGE.matches(pkg) || pkg == context.packageName) return false
        // HACK: through the root shell, not ActivityManager.forceStopPackage - that needs FORCE_STOP_PACKAGES
        // (signature|privileged), which isn't on the booted system module's privapp allowlist, and an APK requesting a
        // privileged permission the phone's allowlist lacks won't install (install-app.sh). Real fix: add
        // FORCE_STOP_PACKAGES to system-module/privapp-permissions.txt, boot that module, then call forceStopPackage.
        val r = andro.marchy.RootShell.run("am force-stop $pkg")
        Log.i(TAG, "force-stop $pkg: exit ${r.code} ${r.output.trim()}")
        return r.code == 0
    }
}

package dev.omalauncher.system

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.util.Log

/**
 * The runtime permissions an app PowOS installs itself gets right after install, on a rooted phone (`pm grant`, as
 * PowOS's root shell). The user, 11-25: "the apps added automatically dont have microphone permissions etc".
 *
 * Only from [ALLOWLIST] - an explicit list per package of what that app needs for a feature PowOS ships it for - and
 * only what its own manifest requests (never a permission it doesn't declare; `pm grant` would refuse it anyway). Not
 * rooted: nothing is granted; the app asks at first use (the swipe keyboard: its MicPermissionActivity when ✨ or the
 * mic key is first held - an input method can't show the dialog itself).
 */
object AutoGrants {
    private const val TAG = "PowosAutoGrants"

    /** Package -> the runtime permissions PowOS grants it, and why. */
    val ALLOWLIST: Map<String, List<String>> =
        mapOf(
            // The swipe keyboard (DefaultKeyboard): voice typing and the ✨ reply's spoken note (hold ✨).
            DefaultKeyboard.PACKAGE to listOf("android.permission.RECORD_AUDIO"),
        )

    /** What to `pm grant` [pkg]: allowlisted, declared by it ([requested]) and not [granted] yet. */
    fun toGrant(
        pkg: String,
        requested: Collection<String>,
        granted: (String) -> Boolean,
    ): List<String> = ALLOWLIST[pkg].orEmpty().filter { it in requested && !granted(it) }

    /** Grants [pkg] what [toGrant] says (rooted only). True: it holds all of it now (nothing was missing, or granted). */
    fun apply(
        context: Context,
        pkg: String,
    ): Boolean {
        if (pkg !in ALLOWLIST || !andro.marchy.RootMode.enabled()) return false
        val info: PackageInfo = runCatching { context.packageManager.getPackageInfo(pkg, PackageManager.GET_PERMISSIONS) }.getOrNull() ?: return false
        val requested = info.requestedPermissions.orEmpty().toList()
        val flags = info.requestedPermissionsFlags ?: IntArray(0)
        val held = requested.filterIndexed { i, _ -> ((flags.getOrNull(i) ?: 0) and PackageInfo.REQUESTED_PERMISSION_GRANTED) != 0 }.toSet()
        val todo = toGrant(pkg, requested) { it in held }
        if (todo.isEmpty()) return true
        // pkg and every permission come from ALLOWLIST (constants), never from the APK: nothing to quote.
        val r = andro.marchy.RootShell.run(todo.joinToString(" && ") { "pm grant $pkg $it" })
        Log.i(TAG, "$pkg: pm grant ${todo.joinToString()}: ${if (r.code == 0) "ok" else r.output}")
        return r.code == 0
    }
}

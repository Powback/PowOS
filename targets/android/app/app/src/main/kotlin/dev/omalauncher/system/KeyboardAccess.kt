package dev.omalauncher.system

/**
 * How the keyboard AI button gets a look at the screen on a phone without root (docs/POWAI-ASSISTANT.md §3.9). Pure
 * logic: the JVM tests drive it (KeyboardAccessTest). The keyboard (android-app-dev swipe-keyboard, ScreenAccess.java)
 * draws every step of the setup inside its own input view; PowOS only answers the probe and holds the capture.
 *
 * Two ways in, both the user's choice:
 *  - **accessibility**: [KeyboardShotService] ("PowOS keyboard screenshots"), silent, on until turned off. On Android
 *    13+ a PowOS installed from a file (Android's package installer on an APK: PowApps before 11-25, a browser download)
 *    is under "restricted settings": the toggle is blocked until the user picks Settings > Apps > PowOS > ⋮ (top
 *    right) > "Allow restricted settings" - an item Android shows only after one blocked attempt, and which some ROMs
 *    don't show at all. The probe says so ("access": "restricted"), so the keyboard can walk the user through it.
 *  - **screen share** (MediaProjection, [KeyboardShare]): Android's own consent dialog, no setting anywhere; once (one
 *    frame, then stopped) or for this session (until the user stops it, the screen locks or PowOS restarts).
 */
object KeyboardAccess {
    /**
     * The keyboard starts this ([KeyboardShareConsentActivity], invisible: only Android's consent dialog shows) for a
     * screen share; extra [EXTRA_MODE] = "once" | "session".
     */
    const val ACTION_SHARE = "com.powos.app.action.KEYBOARD_SCREEN_SHARE"
    const val EXTRA_MODE = "mode"

    /** AppOpsManager's modes (the op is "android:access_restricted_settings", OP_ACCESS_RESTRICTED_SETTINGS). */
    const val MODE_ALLOWED = 0
    const val MODE_ERRORED = 2
    const val MODE_DEFAULT = 3
    const val OP_RESTRICTED_SETTINGS = "android:access_restricted_settings"

    /** PackageInstaller.PACKAGE_SOURCE_*: the two that Android puts under restricted settings. */
    const val SOURCE_LOCAL_FILE = 3
    const val SOURCE_DOWNLOADED_FILE = 4

    /**
     * Whether Android blocks PowOS's accessibility toggle: Android 13+ only; the op's mode wins when it says (ALLOWED:
     * the user allowed it; ERRORED: blocked); otherwise (DEFAULT / unreadable, Android 15's enhanced confirmation keeps
     * DEFAULT until decided) the install source decides - a file or download install is restricted, a store / session /
     * adb install isn't.
     */
    fun restricted(
        sdk: Int,
        opMode: Int?,
        packageSource: Int?,
    ): Boolean =
        when {
            sdk < 33 -> false
            opMode == MODE_ALLOWED -> false
            opMode == MODE_ERRORED -> true
            else -> packageSource == SOURCE_LOCAL_FILE || packageSource == SOURCE_DOWNLOADED_FILE
        }

    /** The screenshot path, best first: root's screencap, the accessibility service, a granted share, live mode, none. */
    fun via(
        root: Boolean,
        accessibility: Boolean,
        share: Boolean,
        live: Boolean,
    ): String =
        when {
            root -> "root"
            accessibility -> "accessibility"
            share -> "share"
            live -> "live"
            else -> "none"
        }

    /** Why there's no way in yet (the probe's "access"): "restricted" = the toggle is blocked; "off" = just not on. */
    fun why(restricted: Boolean): String = if (restricted) "restricted" else "off"

    /** Share modes: one frame then stopped, or kept for this session. */
    enum class ShareMode { ONCE, SESSION }

    /** The keyboard's mode extra ("once" | "session"; anything else: once - the smaller grant). */
    fun mode(extra: String?): ShareMode = if (extra == "session") ShareMode.SESSION else ShareMode.ONCE

    /** How long a granted "once" share waits for the keyboard's capture before it stops on its own. */
    const val ONCE_TTL_MS = 60_000L

    /** Whether a share should stop after a grab (once), or keep going (session). */
    fun stopAfterGrab(mode: ShareMode): Boolean = mode == ShareMode.ONCE
}

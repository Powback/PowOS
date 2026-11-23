package dev.omalauncher.system

/**
 * Why WindowFrames' adopt does or doesn't make a stray full-screen app a window (board
 * inner-screen-stays-landscape-after-an-app-moves, 11-18 20:20: the camera started full screen on the unfolded inner
 * screen and NO adopt line came - nothing said which gate held it). Pure, so the decision is a JVM test
 * (AdoptGateTest); WindowFrames logs the verdict once per change.
 */
object AdoptGate {
    /** Adoption held for the whole screen: the reason, or null when stray full-screen apps are adopted now. */
    fun held(
        floating: Boolean,
        keyguard: Boolean,
        switcherOpen: Boolean,
    ): String? =
        when {
            !floating -> "not the desktop (folded, or freeform support off)"
            keyguard -> "the lock screen is showing"
            switcherOpen -> "the switcher is up"
            else -> null
        }

    /**
     * Full-screen app task skipped by adopt: the reason, or null (adopted). [own]: PowOS's own task (or no package);
     * [adopted]/[windowed]: tried once already / a window that went full screen itself; [buttonFull]: a web window's app
     * made full screen by its bar's button. OxygenOS's Open Canvas (CanvasDock.owns) is [CANVAS] before any of these.
     */
    fun skip(
        own: Boolean,
        adopted: Boolean,
        windowed: Boolean,
        buttonFull: Boolean,
    ): String? =
        when {
            own -> "PowOS's own task"
            adopted -> "adopted once already"
            windowed -> "a window that went full screen by itself"
            buttonFull -> "full screen by its web window's button"
            else -> null
        }

    /**
     * Why Open Canvas's tasks (its container, its sides: CanvasDock.owns) are never adopted: the split view itself. Adopt
     * once moved the container into a web window, off the screen (11-23 17:58:36, task 3940), and every later dock went
     * into it ("it's like hiding the app").
     */
    const val CANVAS = "OxygenOS's Open Canvas (split view)"
}

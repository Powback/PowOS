package dev.omalauncher.shell

/**
 * Back and Forward with web windows (the user, 11-01: Back out of a quick page "it's closing when returning back";
 * Chrome floating over home: "when I use the back or forward button/gesture it doesn't do anything for the given
 * window"). A Back / Forward that reaches PowOS (home's ShellActivity holds display 0's focus: the edge gesture's own
 * touch is on display 0, a title bar or home was touched last; PowOS's edge back) goes to the web window the user is
 * in, injected on its display (WebWindowsHost "key"): the app goes back / forward a page, at its root it finishes and
 * the window closes with its task. Home's page gets it only when no window is the user's. Pure, so the JVM tests drive it.
 */
object WindowKeys {
    /** The key, by android.view.KeyEvent's code (constants here so the JVM tests need no Android stubs). */
    enum class Key(val code: Int) {
        BACK(4),
        FORWARD(125),
    }

    /** A window as the keys see it: its display (-1: none yet), closed, its frame on screen, a quick page's card, Linux. */
    data class Win(
        val id: Int,
        val displayId: Int,
        val closed: Boolean,
        val shown: Boolean,
        val quick: Boolean = false,
        val linux: Boolean = false,
    )

    /**
     * The window [Key]s go to, or null (home's page): a quick page's card on screen first (it's modal: a scrim over
     * everything else), else the [focused] window (the one the user last pressed, bar or body) while it's open, on
     * screen and an Android app's with its display. HACK: a Linux window has no key path from the host yet (KWin's
     * keyboard is the VM's own), so home keeps it. Real fix: the KWin bridge's key event (Alt+Left / Alt+Right).
     */
    fun target(
        wins: List<Win>,
        focused: Int,
    ): Win? {
        val open = wins.filter { !it.closed && it.shown && !it.linux && it.displayId >= 0 }
        return open.lastOrNull { it.quick } ?: open.firstOrNull { it.id == focused }
    }

    /** The display maker's line that presses [key] (down, up) on display [displayId]. */
    fun line(
        displayId: Int,
        key: Key,
    ): String = "key $displayId ${key.code}"

    /** android.view.KeyEvent [keyCode]'s [Key], or null (not ours to route). */
    fun of(keyCode: Int): Key? = Key.entries.firstOrNull { it.code == keyCode }
}

package dev.omalauncher.system.gesture

/**
 * Who a sideways swipe from the bottom belongs to (QS1, 10-31 15:50, the user: "If I swipe left on the bottom left
 * corner of the screen, it ... activates the last app always. Like I'm trying to scroll the pages" - down at y 2353 of
 * 2440, ~32 dp up, over a web window's task that counted as "an app under the finger").
 *
 * Over a real full-screen app (or when home isn't the shown surface): the quick switch, as before. With home shown
 * (its page front, the switcher not up, no real full-screen app on display 0 - floating / web window tasks don't
 * count) the quick switch is only the system's thin gesture strip at the very bottom ([stripPx], the navigation bar's
 * inset); any sideways swipe starting above it is home's page swipe (its dock / search bar, shell/ui/gesture.ts).
 */
object SidewaysOwner {
    enum class Owner { QUICK_SWITCH, HOME_PAGE }

    fun decide(
        homeShown: Boolean,
        fullScreenApp: Boolean,
        downY: Float,
        screenBottom: Float,
        stripPx: Float,
    ): Owner {
        if (!homeShown || fullScreenApp) return Owner.QUICK_SWITCH
        return if (downY >= screenBottom - stripPx) Owner.QUICK_SWITCH else Owner.HOME_PAGE
    }
}

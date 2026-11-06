package dev.omalauncher.system.gesture

/**
 * The app a swipe from the bottom starts over ([NavGesture.began]: its window follows the finger to its card), or null
 * (home's: the switcher layer only comes up once the finger moves - homeDrag).
 *
 * SF1 (e2e-appapi round 241, 11-06 19:30, folded: "home's search didn't take the focus" at 558,2407 with a WireGuard web
 * window open on home): home's search bar sits in the gesture strip, and the topmost visible task was the web window's
 * (task 2569, on its own virtual display under home's page). The recents transition is asked for on the finger's DOWN,
 * so the tap on the bar began the switcher over that task - the page's recents.begin dropped the keyboard and blurred
 * the search it had just focused. A web window's task lives on its own display under home's page: while home is shown it
 * is home's (as for the sideways swipe, [SidewaysOwner]), never "the app under the finger". Floating (freeform) tasks on
 * display 0 and full-screen apps keep their window following the finger.
 */
object SwipeFrom {
    fun decide(
        switcherUpOverHome: Boolean,
        homeShown: Boolean,
        visible: Int?,
        webWindow: (Int) -> Boolean,
    ): Int? {
        if (switcherUpOverHome || visible == null) return null
        if (homeShown && webWindow(visible)) return null
        return visible
    }
}

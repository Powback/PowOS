package dev.omalauncher.shell

/**
 * When a page's boot (ShellHost.checkBoot) may be judged "not ready". A page only runs its frames - and app.tsx /
 * chrome.tsx only set window.__powosAlive after one - while its window is on the screen: home's activity stopped under
 * a full-screen app, an overlay kept warm GONE (the shade, Quick Tools, the pull-up panels, assist, the status bar),
 * its document hidden. 2026-11 (Broforce): a full-screen game took the screen, every shell page reloaded behind it and
 * none could draw, and the 20 s check sent "not ready" for all six at once - six high-priority shell errors to the
 * manager, each also able to roll back a hot push (ShellErrors.rollback). A covered page is not hung: it is judged
 * once it is shown again, with a fresh [ShellHost] boot allowance from then, because it only starts running then.
 */
internal object BootJudge {
    enum class Before {
        /** Screen off: a page may be throttled, its silence means nothing - ask again later. */
        WAIT_SCREEN_OFF,

        /** Its window isn't on the screen: it can't draw, so it can't be ready - ask again later. */
        WAIT_HIDDEN,

        /** On the screen again after waiting hidden: its boot clock starts now. */
        RESTART,

        /** On the screen: ask the page. */
        PROBE,
    }

    fun before(
        interactive: Boolean,
        onScreen: Boolean,
        waitedHidden: Boolean,
    ): Before =
        when {
            !interactive -> Before.WAIT_SCREEN_OFF
            !onScreen -> Before.WAIT_HIDDEN
            waitedHidden -> Before.RESTART
            else -> Before.PROBE
        }

    enum class After { READY, WAIT_HIDDEN, LATER, FAIL }

    /**
     * The page's answer: [alive] (window.__powosAlive), whether its document said it is hidden ([pageHidden]: the
     * WebView paused, or its window went away mid-probe), an error it reported while booting, and how long since
     * the load started, still inside the slow-start allowance ([beforeSlow]).
     */
    fun after(
        alive: Boolean,
        pageHidden: Boolean,
        hadError: Boolean,
        beforeSlow: Boolean,
    ): After =
        when {
            alive -> After.READY
            pageHidden -> After.WAIT_HIDDEN
            !hadError && beforeSlow -> After.LATER
            else -> After.FAIL
        }
}

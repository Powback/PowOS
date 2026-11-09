package dev.omalauncher.shell

/**
 * Whether the launcher opened by its component (its app icon, a notification, `am start -n`) hands over to the home
 * screen's instance (the .HomeShell alias) instead of showing itself.
 *
 * Only while PowOS holds the HOME role: then a home instance exists (or the HOME intent makes one in home's task) and one
 * WebView is kept. Without the role (an unrooted phone whose default home is another launcher - the razr fold,
 * 2026-11-08), the HOME intent with the alias's component is delivered to this same singleTask instance, which then
 * finished: tapping PowOS Launcher showed nothing. Then the launcher opens as an ordinary app, rooted or not.
 */
object HomeRedirect {
    fun redirects(homeIntent: Boolean, aliasOn: Boolean, isDefaultHome: Boolean): Boolean =
        !homeIntent && aliasOn && isDefaultHome
}

/**
 * What a shell instance in a home task (made as the .HomeShell alias, HOME in its task's base intent) does once
 * PowOS no longer holds the HOME role - the default home set back to the phone's launcher.
 *
 * Its task stays in the home root task above the new default home: every home gesture brought PowOS forward instead
 * of the launcher, and the system's recents (Moto's Quickstep, which draws its overview in the launcher's window)
 * came up behind it - the swipe-and-hold switcher showed PowOS's home and cancelled. The user, razr fold 2026-11-09:
 * "the switcher on the razr is buggy now for some reason". The app opened from its icon landed in that same task
 * (singleTask), so it stayed a home.
 *
 * - [STAY]: PowOS is home, the task isn't a home one, or a HOME intent picked PowOS just now (the chooser's "just once").
 * - [REOPEN]: opened as an app (its icon, a notification): out of the home task and opened again as an ordinary app.
 * - [LEAVE]: brought up with nothing asked of it (a home gesture raised the home root task): gone, the real home shows.
 */
enum class StaleHome { STAY, LEAVE, REOPEN }

fun staleHome(
    isDefaultHome: Boolean,
    inHomeTask: Boolean,
    homeIntentNow: Boolean,
    appIntentNow: Boolean,
): StaleHome =
    when {
        isDefaultHome || !inHomeTask || homeIntentNow -> StaleHome.STAY
        appIntentNow -> StaleHome.REOPEN
        else -> StaleHome.LEAVE
    }

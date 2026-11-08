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

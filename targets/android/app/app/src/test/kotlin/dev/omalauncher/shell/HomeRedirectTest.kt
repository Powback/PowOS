package dev.omalauncher.shell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** 11-08 razr fold, unrooted, Moto's launcher home: tapping PowOS Launcher redirected to HOME, finished, showed nothing. */
class HomeRedirectTest {
    @Test
    fun notTheDefaultHomeOpensRightThereRootedOrNot() {
        assertFalse(HomeRedirect.redirects(homeIntent = false, aliasOn = true, isDefaultHome = false))
        assertFalse(HomeRedirect.redirects(homeIntent = false, aliasOn = false, isDefaultHome = false))
    }

    @Test
    fun theDefaultHomeHandsOverToItsOneInstance() {
        assertTrue(HomeRedirect.redirects(homeIntent = false, aliasOn = true, isDefaultHome = true))
    }

    @Test
    fun aHomeIntentOrAnAliasOffNeverRedirects() {
        assertFalse(HomeRedirect.redirects(homeIntent = true, aliasOn = true, isDefaultHome = true))
        assertFalse(HomeRedirect.redirects(homeIntent = false, aliasOn = false, isDefaultHome = true))
    }

    /**
     * An update must never leave the package without a HOME activity (Android would hand the role to another
     * launcher): the component names stay, and the launcher's HOME alias is on by default.
     */
    @Test
    fun homeAliasesKeepTheirNamesAndTheLauncherOneIsOnByDefault() {
        val app = File("src/main/AndroidManifest.xml").readText()
        val engine = File("../engine/src/main/AndroidManifest.xml").readText()
        val shell = Regex("""<activity-alias\s[^>]*android:name="andro\.marchy\.HomeShell"[^>]*>""").find(app)?.value
            ?: error("andro.marchy.HomeShell alias missing from the app manifest")
        assertTrue("HomeShell must be enabled by default", shell.contains("""android:enabled="true""""))
        assertTrue(shell.contains("""android:targetActivity=".shell.ShellActivity""""))
        assertTrue("engine .HomeDesktop alias missing", Regex("""<activity-alias\s[^>]*android:name="\.HomeDesktop"""").containsMatchIn(engine))
        assertTrue(app.contains("""android:name=".shell.ShellActivity""""))
    }
}

/** 11-09 razr fold: default home set back to Moto's launcher, PowOS's home task stayed over it - the switcher broke. */
class StaleHomeTest {
    @Test
    fun theDefaultHomeOrAnAppTaskStays() {
        assertTrue(staleHome(isDefaultHome = true, inHomeTask = true, homeIntentNow = false, appIntentNow = false) == StaleHome.STAY)
        assertTrue(staleHome(isDefaultHome = false, inHomeTask = false, homeIntentNow = false, appIntentNow = true) == StaleHome.STAY)
    }

    @Test
    fun aHomeIntentPickingPowosJustOnceStays() {
        assertTrue(staleHome(isDefaultHome = false, inHomeTask = true, homeIntentNow = true, appIntentNow = false) == StaleHome.STAY)
    }

    @Test
    fun raisedByAHomeGestureItLeavesForTheRealHome() {
        assertTrue(staleHome(isDefaultHome = false, inHomeTask = true, homeIntentNow = false, appIntentNow = false) == StaleHome.LEAVE)
    }

    @Test
    fun openedFromItsIconItReopensAsAnApp() {
        assertTrue(staleHome(isDefaultHome = false, inHomeTask = true, homeIntentNow = false, appIntentNow = true) == StaleHome.REOPEN)
    }
}

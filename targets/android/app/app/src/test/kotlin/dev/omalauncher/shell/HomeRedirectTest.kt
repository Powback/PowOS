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

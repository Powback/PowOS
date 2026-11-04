package dev.omalauncher.shell

import dev.omalauncher.shell.GameBoost.Action
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The game CPU boost (board broforce-games-black-noise-flicker-artifacts-ove): a game in front -> boost, the same game
 * -> the lease renewed, it leaves the front / closes / the screen turns off -> everything restored; one game at a time.
 */
class GameBoostTest {
    private val bf = "steam_app_274190"

    @Test
    fun focusBoostsBlurRestores() {
        val m = GameBoost.Machine()
        assertEquals(Action.Idle, m.step(null, true))
        assertEquals(Action.Engage(bf), m.step(bf, true))
        assertEquals(Action.Renew, m.step(bf, true))
        assertEquals(Action.Restore("no game in front"), m.step(null, true))
        assertNull(m.engaged)
        assertEquals(Action.Idle, m.step(null, true))
    }

    @Test
    fun screenOffRestoresAndScreenOnBoostsAgain() {
        val m = GameBoost.Machine()
        m.step(bf, true)
        assertEquals(Action.Restore("screen off"), m.step(bf, false))
        assertEquals("nothing boosted while off", Action.Idle, m.step(bf, false))
        assertEquals(Action.Engage(bf), m.step(bf, true))
    }

    @Test
    fun anotherGameTakesItsPlace() {
        val m = GameBoost.Machine()
        m.step(bf, true)
        assertEquals(Action.Engage("supertuxkart"), m.step("supertuxkart", true))
        assertEquals("supertuxkart", m.engaged)
    }

    @Test
    fun aWebWindowGameIsInFrontWhenFullScreenOrLastPressed() {
        val game = GameBoost.WebWin(3, bf, game = true, closed = false, minimised = false, full = false)
        val kate = GameBoost.WebWin(4, "org.kde.kate", game = false, closed = false, minimised = false, full = true)
        assertEquals(bf, GameBoost.webFront(true, listOf(game, kate), focused = 3))
        assertNull("pressed elsewhere: not the one played", GameBoost.webFront(true, listOf(game, kate), focused = 4))
        assertEquals(bf, GameBoost.webFront(true, listOf(game.copy(full = true)), focused = -1))
        assertNull("home not in front (another app over it)", GameBoost.webFront(false, listOf(game.copy(full = true)), 3))
        assertNull("minimised", GameBoost.webFront(true, listOf(game.copy(minimised = true)), 3))
        assertNull("closed", GameBoost.webFront(true, listOf(game.copy(closed = true, full = true)), 3))
    }

    @Test
    fun aWindowTaskIsAGameByItsClassOrCategories() {
        val cats = mapOf("supertuxkart" to "Game;ArcadeGame;", "steam" to "Network;Game;", "org.kde.kate" to "Utility;")
        assertEquals(bf, GameBoost.front(null, bf) { cats[it] })
        assertEquals("supertuxkart", GameBoost.front(null, "supertuxkart") { cats[it] })
        assertNull("Steam itself is a launcher", GameBoost.front(null, "steam") { cats[it] })
        assertNull(GameBoost.front(null, "org.kde.kate") { cats[it] })
        assertNull(GameBoost.front(null, null) { cats[it] })
        assertEquals("the web window's game first", bf, GameBoost.front(bf, "supertuxkart") { cats[it] })
    }

    @Test
    fun onlyEngageAndRestoreCallRoot() {
        val s = "/data/user/0/com.powos.app/files/game-boost.sh"
        val l = "/data/user/0/com.powos.app/files/game-boost.lease"
        assertEquals("sh $s engage '$bf' $l", GameBoost.command(s, l, Action.Engage(bf)))
        assertEquals("sh $s engage 'a'\\''b' $l", GameBoost.command(s, l, Action.Engage("a'b")))
        assertEquals("sh $s restore", GameBoost.command(s, l, Action.Restore("screen off")))
        assertNull(GameBoost.command(s, l, Action.Renew))
        assertNull(GameBoost.command(s, l, Action.Idle))
    }

    @Test
    fun theScriptRestoresOnEveryWayOutAndKeepsThermalAlone() {
        val sh = File("src/main/assets/game-boost.sh").readText()
        assertTrue("SIGTERM restores", sh.contains("trap 'log \"\$APP: restore asked\"; restore_all; exit 0' TERM INT HUP"))
        assertTrue("a stale lease restores", sh.contains("the app's lease is"))
        assertTrue("the game gone restores", sh.contains("the game's processes are gone"))
        assertTrue("the lease age matches", sh.contains("LEASE_S=\${LEASE_S:-${GameBoost.LEASE_S}}"))
        assertTrue("a killed holder's originals are kept", sh.contains("[ -s \"\$S/freqs\" ] && return"))
        assertTrue("a top-level uclamp group", sh.contains("CPUCTL=\${GAME_BOOST_CPUCTL:-/dev/cpuctl}\nCG=\$CPUCTL/powos-game"))
        assertTrue("a thermal controller's cap is found", sh.contains("horae*|thermal*) echo \"\$c\"; return"))
        assertTrue("its cap is kept, only the min held up to it", sh.contains("[ \"\$lo\" -gt \"\$cap\" ] && lo=\$cap") && sh.contains("- kept\""))
        assertTrue("restore never writes a stale max under it", sh.contains("if [ -n \"\$th\" ]; then cap=\$(cat \$P/\$p/scaling_max_freq)"))
        assertTrue("never a cooling device or thermal-engine", !Regex("cooling_device|thermal-engine|thermal_zone").containsMatchIn(sh.substringAfter("mkdir -p \"\$S\"")))
    }

    /**
     * The vendor's game class lives exactly as long as the boost: set when a holder boosts under the vendor's thermal
     * controller, cleared in restore_all (the one exit every way out takes: SIGTERM, a stale lease, the game gone, a
     * killed holder's next engage/restore); the hook reads the same key, answers the game type for com.powos.app only.
     */
    @Test
    fun theVendorGameClassFollowsTheBoost() {
        val sh = File("src/main/assets/game-boost.sh").readText()
        assertTrue("the key matches", sh.contains("VENDOR_GAME_KEY=${GameBoost.VENDOR_GAME_KEY}\n"))
        val hold = sh.substringAfter("\nhold() {").substringBefore("\n}\n")
        assertTrue("on with the boost, under a thermal controller only", hold.contains("[ -n \"\$THERMAL\" ] && vendor_game_class \"\$APP\""))
        assertTrue("every way out of hold restores", hold.contains("restore_all; exit 0' TERM") && hold.trimEnd().endsWith("restore_all"))
        val restore = sh.substringAfter("\nrestore_all() {").substringBefore("\n}\n")
        assertTrue("off on every restore", restore.contains("vendor_game_class \"\""))
        val engage = sh.substringAfter("\n  engage)").substringBefore(";;")
        assertTrue("a killed holder's class is cleared before the next", engage.indexOf("restore_all") in 0 until engage.indexOf("setsid"))
        val off = sh.substringAfter("vendor_game_class() {").substringBefore("\n}\n")
        assertTrue("off deletes the key", off.contains("delete global \$VENDOR_GAME_KEY"))

        val hook = File("../../oplus-hook/app/src/main/java/powos/oplushook/Hook.java").readText()
        assertTrue("the hook reads the same key", hook.contains("VENDOR_GAME_KEY = \"${GameBoost.VENDOR_GAME_KEY}\""))
        assertTrue("the vendor's game type", hook.contains("APP_TYPE_GAME = ${GameBoost.VENDOR_APP_TYPE_GAME};"))
        val body = hook.substringAfter("private static void gameClassWhileBoosted").substringBefore("private static void log(")
        assertTrue("only com.powos.app", body.contains("if (!POWOS.equals(param.args[0])"))
        assertTrue("only while the key is set, never re-classing a classed app", body.contains("game != null && !game.isEmpty() && (Integer) param.getResult() <= 0"))
        assertTrue("scoped to com.oplus.battery", File("../../oplus-hook/app/src/main/res/values/arrays.xml").readText().contains("<item>com.oplus.battery</item>"))
    }
}

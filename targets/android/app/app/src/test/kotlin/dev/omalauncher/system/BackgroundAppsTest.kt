package dev.omalauncher.system

import dev.omalauncher.system.BackgroundApps.Pkg
import dev.omalauncher.system.BackgroundApps.Proc
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The switcher's "Running in background" (the user, 2026-11-03: "they're just running in the background ... like
 * Termux"): which running apps it lists - real user apps doing work with no card, never the system's own.
 */
class BackgroundAppsTest {
    private val user = Pkg(system = false, persistent = false)
    private val pkgs =
        mapOf(
            "com.termux" to user,
            "com.spotify.music" to user,
            "com.discord" to user,
            "com.cached.app" to user,
            "com.powos.app" to user,
            "com.android.systemui" to Pkg(system = true, persistent = true),
            "com.oplus.weather" to Pkg(system = true, persistent = false),
            "com.persistent.user" to Pkg(system = false, persistent = true),
            "com.google.android.youtube" to user,
            "com.swiftkey" to user,
        )
    private val launchable = pkgs.keys - "com.android.systemui"

    private fun run(
        procs: List<Proc>,
        withTask: Set<String> = emptySet(),
        keep: Set<String> = emptySet(),
    ) = BackgroundApps.filter(procs, BackgroundApps.Scope("com.powos.app", withTask, launchable, keep)) { pkgs[it] }

    @Test fun termuxsForegroundServiceIsListed() {
        assertEquals(listOf("com.termux"), run(listOf(Proc(listOf("com.termux"), BackgroundApps.IMPORTANCE_FOREGROUND_SERVICE))))
    }

    @Test fun startedServicesAndPerceptibleWorkAreListedCachedAndTopAreNot() {
        val procs =
            listOf(
                Proc(listOf("com.spotify.music"), 230), // perceptible (playing)
                Proc(listOf("com.youtube.never"), 300),
                Proc(listOf("com.google.android.youtube"), 300), // a started service
                Proc(listOf("com.cached.app"), BackgroundApps.IMPORTANCE_CACHED),
                Proc(listOf("com.discord"), 100), // in front: it has a window
            )
        assertEquals(listOf("com.spotify.music", "com.google.android.youtube"), run(procs))
    }

    @Test fun neverPowosSystemPersistentOrNotInTheDrawer() {
        val fg = BackgroundApps.IMPORTANCE_FOREGROUND_SERVICE
        val procs =
            listOf(
                Proc(listOf("com.powos.app"), fg),
                Proc(listOf("com.android.systemui"), fg),
                Proc(listOf("com.oplus.weather"), fg),
                Proc(listOf("com.persistent.user"), fg),
                Proc(listOf("com.google.android.gms"), fg), // no launcher entry, unknown to info
                Proc(listOf("com.termux"), fg),
            )
        assertEquals(listOf("com.termux"), run(procs))
    }

    @Test fun anAppWithACardOrThatServesTheSystemIsLeftOut() {
        val fg = BackgroundApps.IMPORTANCE_FOREGROUND_SERVICE
        val procs = listOf(Proc(listOf("com.spotify.music"), fg), Proc(listOf("com.swiftkey"), 200), Proc(listOf("com.termux"), fg))
        assertEquals(listOf("com.termux"), run(procs, withTask = setOf("com.spotify.music"), keep = setOf("com.swiftkey")))
    }

    @Test fun anAppWithManyProcessesIsListedOnce() {
        val procs = listOf(Proc(listOf("com.termux"), 125), Proc(listOf("com.termux"), 300))
        assertEquals(listOf("com.termux"), run(procs))
    }
}

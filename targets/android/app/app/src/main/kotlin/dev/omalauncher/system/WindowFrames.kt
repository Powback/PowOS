package dev.omalauncher.system

import android.content.Context
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.WindowManager
import androidx.compose.runtime.mutableStateOf

/**
 * PowOS's frames for the floating app windows on the unfolded home ([AppWindows], [WindowFrame]): a frame on every
 * floating window that shows and isn't covered by another, kept on the task as Android moves, raises and closes it
 * (the task stack listener, [FreeformTasks.listen]). Minimised windows ([minimise]) leave the screen and stay in the
 * dock ([running], home's page: windows.changed), which brings them back ([restore]). Lives with the recents service
 * (SystemUI bound); none while the lock screen or the switcher is up, or folded.
 */
class WindowFrames(
    service: Context,
) {
    private val display: Display = service.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
    private val context: Context = service.createDisplayContext(display).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
    private val main = Handler(Looper.getMainLooper())
    private val frames = mutableMapOf<Int, WindowFrame>()
    private var stopListening: (() -> Unit)? = null
    private var keyguard = false
    private val refreshNow = Runnable { refresh() }

    fun start(): Boolean {
        overlayGrant()
        // The system's own caption would show under PowOS's bar on every window: off (OemCaption).
        OemCaption.off(context)
        stopListening =
            FreeformTasks.listen {
                events++
                main.removeCallbacks(refreshNow)
                main.postDelayed(refreshNow, SETTLE_MS)
            }
        // Without the listener nothing is ever listed after this first read: no window gets a home page (2026-10-23).
        Log.i(TAG, "frames on, task listener ${if (stopListening != null) "on" else "MISSING"}")
        current = this
        refresh()
        return stopListening != null
    }

    /**
     * The frames are TYPE_APPLICATION_OVERLAY windows (over apps, UNDER the status bar and the shade - the recents role's
     * 2017 would sit over the shade), which need the "display over other apps" app op. It was found reset to default on
     * 2026-10-23 ("permission denied for window type 2038": no title bars at all), so it's granted again through root
     * whenever it's missing, as QuickSettings does WRITE_SETTINGS. The reset's cause: the manifest had stopped
     * declaring SYSTEM_ALERT_WINDOW (2026-10-16), so the op fell back to "default" and `appops set` didn't take (rc 0,
     * still default); declared again in AndroidManifest.xml. HACK: the user's grant done for them. Real fix: the grant
     * in PowOS's setup (Settings > display over other apps), kept.
     */
    private fun overlayGrant() {
        if (Settings.canDrawOverlays(context)) return
        Thread {
            val r = runCatching { andro.marchy.RootShell.run("appops set ${context.packageName} SYSTEM_ALERT_WINDOW allow") }.getOrNull()
            Log.i(TAG, "overlay app op was off: granted again (${r?.code ?: "no root"})")
            main.post(refreshNow)
        }.start()
    }

    /** A frame couldn't be added (WindowFrame): the app op again, at most once a minute. */
    fun frameRefused() {
        val now = android.os.SystemClock.uptimeMillis()
        if (now - lastGrant < GRANT_EVERY_MS) return
        lastGrant = now
        overlayGrant()
    }

    private var lastGrant = 0L

    fun stop() {
        stopListening?.invoke()
        stopListening = null
        main.removeCallbacks(refreshNow)
        frames.values.forEach { it.remove() }
        frames.clear()
        if (current === this) current = null
    }

    /** SystemUI's state flags: no frames over the lock screen. */
    fun systemUiState(flags: Long) {
        val k = flags and SYSUI_KEYGUARD_SHOWING != 0L && flags and SYSUI_KEYGUARD_OCCLUDED == 0L
        if (k == keyguard) return
        keyguard = k
        refresh()
    }

    /** Folded/unfolded, rotated: the frames again. */
    fun refresh() {
        val all = runCatching { FreeformTasks.list(context) }.onFailure { Log.w(TAG, "no floating windows", it) }.getOrDefault(emptyList())
        val floating = AppWindows.floating(context)
        if (adopting(floating)) return
        logChange(all, floating)
        track(all, floating)
        val show = if (keyguard || Switcher.open || !floating) emptyList() else uncovered(all.filter { it.visible && it.id !in minimised && it.id !in away })
        val ids = show.map { it.id }.toSet()
        frames.keys.filter { it !in ids }.forEach { frames.remove(it)?.remove() }
        // Bottom-most first, so a new frame's windows stack over the ones under it.
        show.asReversed().forEach { w -> frames.getOrPut(w.id) { WindowFrame(context, w.id, WindowFrame.App(w.pkg, ownTitle(w)), ::minimise, ::edge, ::maximise) }.apply { showMaximised(w.id in maximised) }.place(w.bounds) }
    }

    /**
     * Unfolded, every app is a window: an app task showing full screen - opened without PowOS's launch options (another
     * app, a system notification, `am start`), or left full screen from the folded screen - is made one at the next
     * cascaded place (FreeformTasks.toWindow). Each task once ([adopted]): one that won't float stays as it is. True when
     * one changed (the task listener's refresh follows). PowOS's own tasks (Linux windows: WindowTasks decides) never.
     */
    private fun adopting(floating: Boolean): Boolean {
        // Folded, apps are full screen by design; unfolded again, they become windows again.
        if (!floating) adopted.clear()
        return floating && !keyguard && !Switcher.open && adopt()
    }

    private fun adopt(): Boolean {
        val stray = FreeformTasks.fullScreen(context).filter { (id, pkg) -> pkg != null && pkg != context.packageName && id !in adopted }
        stray.forEach { (id, pkg) ->
            adopted.add(id)
            val ok = FreeformTasks.toWindow(context, id, AppWindows.nextBounds(context))
            Log.i(TAG, "task $id ($pkg) was full screen: ${if (ok) "now a window" else "can't float it"}")
        }
        if (stray.isEmpty()) return false
        main.removeCallbacks(refreshNow)
        main.postDelayed(refreshNow, SETTLE_MS)
        return true
    }

    /**
     * The floating windows as Android lists them (logcat PowosWindowFrames), once per change, with how many task events
     * came since: a window that shows but isn't here never gets a home page (desktops.ts places what windows.list has).
     */
    private fun logChange(
        all: List<FreeformTasks.Window>,
        floating: Boolean,
    ) {
        val now = all.joinToString(" ") { "${it.id}:${it.pkg}${if (it.visible) "" else "(hidden)"}@${it.bounds.toShortString()}" }
        val key = "$floating $keyguard $now"
        if (key == logged) return
        logged = key
        Log.i(TAG, "windows (floating=$floating keyguard=$keyguard, $events task events): ${now.ifEmpty { "none" }}")
    }

    private var logged: String? = null
    @Volatile private var events = 0

    /** A PowOS (Linux) window's caption for its bar: its task is PowOS's own (PowosWindowActivity), so not "PowOS". */
    private fun ownTitle(w: FreeformTasks.Window): String? = w.label.takeIf { w.pkg == context.packageName }

    /** The per-window state kept up with the listed windows ([all]; none count folded, apps aren't windows there). */
    private fun track(
        all: List<FreeformTasks.Window>,
        floating: Boolean,
    ) {
        val ids = all.map { it.id }.toSet()
        minimised.retainAll(ids)
        // Folded, the windows aren't listed but still belong to their pages: kept for the unfold.
        if (floating) away.retainAll(ids)
        // Folded, apps aren't windows: the dock shows none.
        publish(if (floating) all else emptyList())
        // PowOS's own tasks (Linux windows, PowosWindowActivity) draw KWin's buffer pixel for pixel: no density.
        dense(if (floating) all.filter { it.pkg != context.packageName } else emptyList())
        maximised.keys.retainAll { id -> all.any { it.id == id && it.bounds == maximised[id]?.second } }
    }

    /**
     * Every floating window's app at the windows' density (AppWindows.windowDpi: about its full-screen size, not the
     * phone layout blown up); a task that is no longer a window ([windows] = the floating ones; none folded) gets the
     * screen's density back, so full screen is exactly as before.
     *
     * HACK: set while the window is still opening (the first refresh after its launch), the density doesn't stick on
     * OxygenOS 16 (measured 2026-10-23: the transaction succeeds, the task still says the screen's dpi; the same call
     * 3 s later sticks). So it's read back from the task's configuration and set again until it shows, a few tries
     * apart. Real fix: set it in the launch itself - needs WM Shell's desktop mode (SystemUI's), off on this ROM.
     */
    private fun dense(windows: List<FreeformTasks.Window>) {
        val dpi = AppWindows.windowDpi(context)
        val ids = windows.map { it.id }.toSet()
        (scaled - ids).forEach { FreeformTasks.density(context, it, 0) }
        scaled.retainAll(ids)
        denseTries.keys.retainAll(ids)
        var again = false
        for (w in windows) {
            if (w.dpi == dpi) {
                scaled.add(w.id)
                continue
            }
            val n = denseTries.getOrDefault(w.id, 0)
            if (n >= DENSE_TRIES) continue
            denseTries[w.id] = n + 1
            if (FreeformTasks.density(context, w.id, dpi)) scaled.add(w.id)
            Log.i(TAG, "task ${w.id} at ${w.dpi} dpi: set $dpi (try ${n + 1})")
            again = true
        }
        if (again) main.postDelayed(refreshNow, DENSE_RETRY_MS)
    }

    /**
     * Task [id]'s window over all of the windows' area (AppWindows.area: under the status bar, above home's bottom bar)
     * - its title bar's maximise; again, back where it was. Moved or resized by hand, it's an ordinary window again.
     */
    fun maximise(id: Int) {
        val now = frames[id]?.bounds ?: FreeformTasks.list(context).firstOrNull { it.id == id }?.bounds ?: return
        val back = maximised.remove(id)
        val target = back?.first ?: AppWindows.area(context)
        if (back == null) maximised[id] = Rect(now) to Rect(target)
        FreeformTasks.raise(context, id)
        FreeformTasks.resize(id, target)
        main.removeCallbacks(refreshNow)
        main.postDelayed(refreshNow, SETTLE_MS)
    }

    /** The windows (top-most first) whose title bar isn't under a window above them: a covered bar would float over it. */
    private fun uncovered(windows: List<FreeformTasks.Window>): List<FreeformTasks.Window> {
        val bar = (WindowFrame.BAR_DP * context.resources.displayMetrics.density).toInt()
        return windows.filterIndexed { i, w ->
            val strip = Rect(w.bounds.left, w.bounds.top - bar, w.bounds.right, w.bounds.top)
            windows.take(i).none { Rect.intersects(it.bounds, strip) }
        }
    }

    /** Task [id]'s window let go at the screen's [side] edge: home takes it to the next page (shell windows.edge). */
    private fun edge(
        id: Int,
        side: Int,
    ) {
        edges.value = Edge(id, side, (edges.value?.seq ?: 0) + 1)
    }

    /** Task [id]'s window off the screen, into the dock. */
    fun minimise(id: Int) {
        if (!FreeformTasks.minimise(context, id)) return
        minimised.add(id)
        refresh()
    }

    /**
     * Home's pages are desktops (shell ui/desktops.ts): [hide] are the windows of the other pages. Those leave the
     * screen as a minimise does (the task keeps running, no frame); the ones no longer in it come back, bottom-most
     * first so the stack keeps its order. A window the user minimised stays minimised. Folded (apps full screen):
     * nothing. On the main thread, like [refresh].
     */
    fun desktop(hide: Set<Int>): Boolean {
        if (!AppWindows.floating(context)) return false
        main.post { showOnly(hide) }
        return true
    }

    private fun showOnly(hide: Set<Int>) {
        val back = away - hide
        away.clear()
        away.addAll(hide)
        // All of them, not only the new: after a fold and unfold Android may have raised them again.
        hide.forEach { FreeformTasks.minimise(context, it) }
        running.value.asReversed().filter { it.id in back && it.id !in minimised }.forEach { FreeformTasks.raise(context, it.id) }
        main.removeCallbacks(refreshNow)
        main.postDelayed(refreshNow, SETTLE_MS)
    }

    /** Task [id]'s window back where it was, on top (a tap on it in the dock; home goes to its page, windows.raised). */
    fun restore(id: Int): Boolean {
        minimised.remove(id)
        away.remove(id)
        val ok = FreeformTasks.raise(context, id) || Tasks.open(context, id)
        main.postDelayed(refreshNow, SETTLE_MS)
        return ok
    }

    /** [pkg]'s floating window back (a tap on its app anywhere on home), if it has one and apps float: its task, or null. */
    fun restoreApp(pkg: String): Int? {
        if (!AppWindows.floating(context)) return null
        val w = running.value.firstOrNull { it.pkg == pkg } ?: return null
        return w.id.takeIf { restore(it) }
    }

    private fun publish(all: List<FreeformTasks.Window>) {
        val pm = context.packageManager
        val next =
            all.map { w ->
                val label = w.pkg?.let { p -> runCatching { pm.getApplicationLabel(pm.getApplicationInfo(p, 0)).toString() }.getOrNull() }
                Running(w.id, w.pkg, label ?: w.pkg.orEmpty(), w.id in minimised, w.id in away, w.bounds.takeIf { w.visible })
            }
        if (next != running.value) running.value = next
    }

    /** A window let go at a screen edge: [side] -1 left, 1 right; [seq] tells two drops apart. */
    data class Edge(
        val id: Int,
        val side: Int,
        val seq: Int,
    )

    /** A floating window for the dock: its task, app, name and whether it's minimised. */
    data class Running(
        val id: Int,
        val pkg: String?,
        val label: String,
        val minimised: Boolean,
        /** On another home page (desktop): out of sight until home shows that page. */
        val away: Boolean = false,
        /** Where it is on the screen (px) while it shows: home's gestures never start inside it. */
        val bounds: Rect? = null,
    )

    companion object {
        private const val TAG = "PowosWindowFrames"
        private const val SETTLE_MS = 80L
        private const val GRANT_EVERY_MS = 60_000L
        private const val DENSE_TRIES = 8
        private const val DENSE_RETRY_MS = 500L
        private const val SYSUI_KEYGUARD_SHOWING = 1L shl 6
        private const val SYSUI_KEYGUARD_OCCLUDED = 1L shl 9

        @Volatile
        var current: WindowFrames? = null
            private set

        /** Minimised windows' tasks (kept across a service rebind: the windows are still minimised). */
        private val minimised = mutableSetOf<Int>()

        /** Tasks whose density is the windows' (FreeformTasks.density): given back the screen's once not a window. */
        private val scaled = mutableSetOf<Int>()

        /** How often each window's density was set so far ([dense]: until its task says it). */
        private val denseTries = mutableMapOf<Int, Int>()

        /** Tasks [adopt] made windows (or tried to) since the last unfold: each once, so one that won't float isn't retried. */
        private val adopted = mutableSetOf<Int>()

        /** Maximised windows: task -> (its bounds before, its maximised bounds). */
        private val maximised = mutableMapOf<Int, Pair<Rect, Rect>>()

        /** Windows of the home pages not on screen ([desktop]); kept across a rebind like [minimised]. */
        private val away = mutableSetOf<Int>()

        /** The floating windows, top-most first, for the dock (home's page reads it: windows.list / windows.changed). */
        val running = mutableStateOf<List<Running>>(emptyList())

        /** The last edge drop (home's page reads it: windows.edge). */
        val edges = mutableStateOf<Edge?>(null)
    }
}

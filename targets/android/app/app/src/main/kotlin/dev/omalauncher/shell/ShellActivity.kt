package dev.omalauncher.shell

import android.app.Activity
import android.app.ActivityManager
import android.app.role.RoleManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import android.view.View
import androidx.compose.runtime.snapshotFlow
import dev.omalauncher.App
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** Home with its pull-up panel up ("apps" or "ai"): an edge gesture's (EdgeGestures). */
const val EXTRA_HOME_PANEL = "dev.omalauncher.shell.panel"

/** With [EXTRA_HOME_PANEL] "ai": words waiting in PowOS AI's field (a share to the old AI app's entry). */
const val EXTRA_HOME_DRAFT = "dev.omalauncher.shell.draft"

/**
 * The launcher: a full-screen [ShellHost] over the wallpaper (the shell's home), as the Home app - the only one (the
 * Compose launcher it replaced is gone, docs/COMPOSE-REMOVAL.md). Home pressed and Back go to the page; the widgets'
 * sources run while it shows.
 */
class ShellActivity : Activity() {
    private lateinit var host: ShellHost

    /** Home is the app in front (resumed): only then is the display without its window the wallpaper. */
    @Volatile private var inFront = false
    private val scope: CoroutineScope = MainScope()

    private val runtime get() = (application as App).runtime

    /**
     * Rooted: the PowOS session. No root: the same for the PowOS image's session (lotfix-run: D-Bus, PipeWire, the
     * compositor, agentsd), once the engine installed the image - apps, their windows, Steam, terminals and agents run
     * in it (Guest). Already running: nothing.
     */
    private fun startPowosSession() {
        if (andro.marchy.RootMode.enabled()) {
            andro.marchy.SessionService.start(this)
        } else if (dev.omalauncher.linux.POWOS && andro.marchy.SessionService.rootfsReady(this)) {
            andro.marchy.SessionService.startAsync(this)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Each home made, and why (the manager saw home's task change: an app update, a recreation, a second home).
        Log.i(TAG, "home created: task $taskId, restored ${savedInstanceState != null}, intent ${intent.component?.shortClassName} ${intent.categories} ${intent.extras?.keySet()}, from ${referrer}")
        if (toHome()) return
        // A restored task's intent is the one it was made with, not a new ask (the stale-home check, [leaveStaleHome]).
        noteArrived(restored = savedInstanceState != null)
        dropOtherHomes()
        // The launcher's runtime (themes, widgets, the PowOS session); started once.
        runtime.start()
        // The shell has no first-run screen (the Compose launcher's welcome): home shows at once, and the rest of
        // Omarchy's themes download behind it, as they did once the welcome was done.
        if (!runtime.launcherReady) runtime.finishWelcome()
        // Rooted mode: the PowOS session with it (terminals, PowOS apps, folding run in it), as the desktop starts it -
        // after a reboot or an update the launcher is often the first thing that runs. Already running: nothing.
        startPowosSession()
        window.setDecorFitsSystemWindows(false)
        // Edge to edge for real: the page (and the wallpaper behind it) fills the whole screen, the bars draw nothing.
        // Theme.Material's defaults left the decor's navigationBarBackground black over the gesture-nav strip (a black
        // row under the dock, folded) and statusBarBackground over the status bar; the page keeps its own insets.
        @Suppress("DEPRECATION")
        run {
            window.statusBarColor = android.graphics.Color.TRANSPARENT
            window.navigationBarColor = android.graphics.Color.TRANSPARENT
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        host = ShellHost(this, this, runtime)
        openPanel(intent)   // a cold start with a panel asked for (the old AI app's entries): once the page is ready
        setContentView(host.web)
        keepFocusOnPage(host.web)
        // The switcher is a layer of this page: the gestures and the overview button reach it here.
        // Its whole-window blur is the switcher's depth: never on once the switcher isn't up (WindowBlur's watchdog).
        val blur = WindowBlur(window, glass = host::wholeWindow, keep = { dev.omalauncher.system.Switcher.open })
        // Home's window, left out when the wallpaper's picture is taken from the display (WallpaperBackdrop.still).
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            WallpaperBackdrop.homeWindow = { if (inFront) host.windowSurface() else null }
            WallpaperBackdrop.homeBars = {
                val bars = window.decorView.rootWindowInsets?.getInsets(android.view.WindowInsets.Type.systemBars())
                (bars?.top ?: 0) to (bars?.bottom ?: 0)
            }
        }
        dev.omalauncher.system.Switcher.attach(host.bridge, { host.highRefresh?.boost(it) }, blur::set)
        applicationContext.getSystemService(android.hardware.display.DisplayManager::class.java).registerDisplayListener(stuckListener, main)
        // Opened from the agents' notification: the page opens the Agents screen.
        dev.omalauncher.AgentsSpool.opened(intent)
        handleDebugExec(intent)
        // Asked once nothing else is in front: not over the notification permission dialog a Linux install brings up.
        scope.launch {
            snapshotFlow { runtime.themes.loaded }.first { it }
            if (!isFinishing) requestHomeRole()
        }
    }

    /**
     * Opened by its component (its app entry, a notification, `am start -n`) while it's the home screen: on to the
     * home screen's own instance, extras and all, and gone - one shell page, not a second WebView in a task of its own
     * (Android keeps a home activity and the same activity started as an app in different tasks, singleTask or not).
     * A HOME intent without a component is a home launch from any app; it resolves to .HomeShell, the one enabled.
     * Only while PowOS is the default home ([HomeRedirect]); otherwise this is the app, opened right here.
     */
    private fun toHome(): Boolean {
        val alias = android.content.ComponentName(this, "andro.marchy.HomeShell")
        val redirect = HomeRedirect.redirects(
            homeIntent = intent.hasCategory(Intent.CATEGORY_HOME),
            // DEFAULT (manifest android:enabled="true") counts as on: HomeShell has been on by default since 909ff910.
            aliasOn = packageManager.getComponentEnabledSetting(alias) != PackageManager.COMPONENT_ENABLED_STATE_DISABLED &&
                runCatching { packageManager.getActivityInfo(alias, 0).enabled }.getOrDefault(false),
            // Not the default home (the razr fold, Moto's launcher home): the HOME intent below lands on this very
            // instance (singleTask, START_DELIVERED_TO_TOP) and finish() then closed it - a tap on the icon showed nothing.
            isDefaultHome = getSystemService(RoleManager::class.java).isRoleHeld(RoleManager.ROLE_HOME),
        )
        if (!redirect) return false
        startActivity(
            Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_HOME)
                // The launcher's alias itself: rooted, both home aliases stay on (HomeScreen) and the default home may
                // be the desktop - a HOME intent for the package would open that.
                .setComponent(alias)
                .putExtras(intent)
                .putExtra(EXTRA_REDIRECTED, true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        finish()
        return true
    }

    /**
     * Any other task of this activity goes: a home task left from before (an update, a relaunch as home on another
     * display or after an alias switch) kept its own WebView, and two homes at different sizes resized the hosted
     * Android widgets back and forth. One home page, this one.
     */
    private fun dropOtherHomes() {
        val mine = javaClass.name
        for (task in getSystemService(ActivityManager::class.java).appTasks) {
            val info = runCatching { task.taskInfo }.getOrNull() ?: continue
            if (info.taskId == taskId) continue
            val base = info.baseActivity ?: info.baseIntent.component
            // By the activity (the alias resolves to it): the HOME alias's tasks and any started by name.
            val ours = base?.className == mine || base?.className == "andro.marchy.HomeShell" || info.topActivity?.className == mine
            if (ours) dropHome(task, info.taskId)
        }
    }

    /** Asks once to become the default home app; Android shows its own chooser. (Rooted PowOS sets it itself.) */
    private fun requestHomeRole() {
        val roles = getSystemService(RoleManager::class.java)
        if (!roles.isRoleAvailable(RoleManager.ROLE_HOME) || roles.isRoleHeld(RoleManager.ROLE_HOME)) return
        val prefs = getSharedPreferences("launcher", MODE_PRIVATE)
        if (prefs.getBoolean("home_role_asked", false)) return
        prefs.edit().putBoolean("home_role_asked", true).apply()
        @Suppress("DEPRECATION")
        startActivityForResult(roles.createRequestRoleIntent(RoleManager.ROLE_HOME), HOME_ROLE_REQUEST)
    }

    /**
     * Debug builds: `adb shell am start -n com.powos.app/dev.omalauncher.shell.ShellActivity --es exec foot`, `--es app
     * org.kde.dolphin` to open a Linux app as a launcher tap does (its desktop id), or `--es theme kanagawa` to apply a
     * theme (scripts/collage-captures.sh).
     */
    private fun handleDebugExec(intent: Intent) {
        if (!dev.omalauncher.AppVersion.debuggable(this)) return
        intent.getStringExtra("exec")?.let(runtime::launch)
        intent.getStringExtra("app")?.let { id ->
            scope.launch {
                snapshotFlow { runtime.linuxApps.firstOrNull { it.id == id } }.first { it != null }?.let(runtime::launch)
            }
        }
        intent.getStringExtra("theme")?.let { name ->
            scope.launch {
                snapshotFlow { runtime.themes.loaded }.first { it }
                runtime.themes.themes.firstOrNull { it.name == name }?.let { runtime.themes.apply(it) } ?: Log.w("debug", "no theme $name")
            }
        }
    }

    /**
     * One line per home (the dock's window) visibility change, with the desktop (Plasma app) state: a dock seen over the
     * Plasma app during a launch (board plasma-app-launching-inside-plasma-never-flashes) shows here as "home started"
     * while desktop=true, and the line before it says which launch moved home up.
     */
    private fun dockLog(what: String) =
        android.util.Log.i("PowosDock", "home $what (desktop on screen=${andro.marchy.WindowTasks.desktopOnScreen()}, top task=${dev.omalauncher.system.Tasks.visible(this)})")

    override fun onPause() {
        super.onPause()
        dockLog("paused")
        inFront = false
        WebWindowLaunch.homeInFront = false
    }

    override fun onResume() {
        super.onResume()
        if (leaveStaleHome()) return
        dockLog("resumed")
        inFront = true
        WebWindowLaunch.homeInFront = true
        UnlockLog.homeResumed(host.web)
        // The page may have missed a fold while hidden: the display state again, whatever it was.
        host.bridge.pushDisplay(force = true)
        runtime.wm.focus(null)
        removeStaleWindowTasks()
        // Back from the engine's installer (or anything else): whether PowOS is installed now.
        runtime.refreshLinuxState()
        // The user may have set or replaced the wallpaper while we were in the background.
        scope.launch { runtime.themes.refreshLiveWallpaper() }
        // A live wallpaper shows another frame after an unlock or a fold (OxygenOS's video ones play then): the page's
        // picture of it again now, and once more when that has played out.
        ShellWallpaper.refresh(this)
        ShellWallpaper.refresh(this, WALLPAPER_SETTLE_MS)
        checkStuckSoon("resumed")
    }

    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private val stuckCheck = Runnable { unstick() }
    private var stuckWhy = ""
    private var stuckTold = ""

    /** A fold or a rotation: home's window should follow it; looked at once the system has applied it. */
    private val stuckListener =
        object : android.hardware.display.DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {}

            override fun onDisplayRemoved(displayId: Int) {}

            override fun onDisplayChanged(displayId: Int) {
                if (displayId == (display?.displayId ?: android.view.Display.DEFAULT_DISPLAY)) checkStuckSoon("display changed")
            }
        }

    private fun checkStuckSoon(why: String) {
        stuckWhy = why
        main.removeCallbacks(stuckCheck)
        main.postDelayed(stuckCheck, STUCK_SETTLE_MS)
    }

    /**
     * Home's window stuck at the other screen's size: sent home again (10-31 02:49, folded: only the wallpaper showed).
     * OxygenOS's canvas (com.oplus.pscanvas, started when an app was opened over another unfolded) took home's task in
     * (its VRI scenario=2); folding finished the canvas, but home's task kept the inner display's 2268x2440 px on the
     * 1116x2484 cover - the page laid out 821x883 dp off the screen, alive and drawing nothing visible. A HOME intent
     * brought to the front gives the task the display's bounds again (`am start -c HOME`, 02:54:39: 404 dp at once).
     * HACK: re-delivering home is the recovery, not a cure - real fix: keep OxygenOS's canvas off home's task (launch
     * apps from home so pscanvas doesn't group them with it), which needs its trigger understood first.
     */
    private fun unstick() {
        if (!inFront || isFinishing || isInMultiWindowMode) return
        val win = windowManager.currentWindowMetrics.bounds
        val disp = applicationContext.getSystemService(android.hardware.display.DisplayManager::class.java).getDisplay(display?.displayId ?: android.view.Display.DEFAULT_DISPLAY) ?: return
        val real = android.graphics.Point()
        // The display's own size (an application context's display, as the WebView's window.screen reads it).
        @Suppress("DEPRECATION")
        disp.getRealSize(real)
        val off = { a: Int, b: Int -> b > 0 && Math.abs(a - b) > b * 0.05 }
        val now = "${win.width()}x${win.height()} on ${real.x}x${real.y}"
        if (!off(win.width(), real.x) && !off(win.height(), real.y)) {
            stuckTold = ""
            return
        }
        // Once per stuck size: a window the system won't resize is logged, not sent home in a loop.
        if (now == stuckTold) return
        stuckTold = now
        Log.w(TAG, "home's window is $now ($stuckWhy): not the display's size - home brought to the front again")
        runCatching {
            startActivity(
                // The launcher's alias itself, as toHome: a package HOME intent may open the desktop's alias when rooted.
                Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).setComponent(android.content.ComponentName(this, "andro.marchy.HomeShell"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra(EXTRA_UNSTICK, true),
            )
        }.onFailure { Log.w(TAG, "home's window: re-delivering home failed: $it") }
        checkStuckSoon("after re-delivering home")
    }

    /** The intent that brought this instance up since its last resume (null: none - raised with its task). */
    private var arrived: Intent? = null

    private fun noteArrived(restored: Boolean) {
        arrived = if (restored) null else intent
    }

    /**
     * Home's task with PowOS no longer the default home ([staleHome]): the task goes, so the phone's own home and its
     * recents overview are in front again; opened as an app, the app comes back in a task of its own. True: leaving.
     */
    private fun leaveStaleHome(): Boolean {
        val came = arrived
        arrived = null
        val roles = getSystemService(RoleManager::class.java)
        val action =
            staleHome(
                isDefaultHome = !roles.isRoleAvailable(RoleManager.ROLE_HOME) || roles.isRoleHeld(RoleManager.ROLE_HOME),
                inHomeTask = inHomeTask(),
                homeIntentNow = came?.hasCategory(Intent.CATEGORY_HOME) == true,
                appIntentNow = came != null && !came.hasCategory(Intent.CATEGORY_HOME),
            )
        if (action == StaleHome.STAY) return false
        Log.i(TAG, "home task $taskId left: PowOS isn't the default home any more (${action.name.lowercase()})")
        dev.omalauncher.system.Tasks.logRemove("finishAndRemoveTask", taskId, "home's task, PowOS no longer the default home", removes = true)
        finishAndRemoveTask()
        // Finishing, this instance is no longer the singleTask one a start finds: a task of its own, a standard one.
        if (action == StaleHome.REOPEN && came != null) {
            runCatching {
                startActivity(Intent(came).setComponent(android.content.ComponentName(this, ShellActivity::class.java)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }.onFailure { Log.w(TAG, "can't reopen PowOS as an app", it) }
        }
        return true
    }

    /** This instance's task was made as home (the .HomeShell alias's HOME intent is its base). */
    private fun inHomeTask(): Boolean =
        getSystemService(ActivityManager::class.java).appTasks.any { t ->
            val info = runCatching { t.taskInfo }.getOrNull()
            info != null && info.taskId == taskId && info.baseIntent.hasCategory(Intent.CATEGORY_HOME)
        }

    /** Drops Recents cards whose Linux window no longer exists (app exited or process restarted). */
    private fun dropHome(
        task: ActivityManager.AppTask,
        id: Int,
    ) {
        dev.omalauncher.system.Tasks.logRemove("finishAndRemoveTask", id, "a second home task", removes = true)
        runCatching { task.finishAndRemoveTask() }.onSuccess { Log.i(TAG, "dropped a second home task $id") }
    }

    private fun removeStaleWindowTasks() {
        for (task in getSystemService(ActivityManager::class.java).appTasks) {
            val base = runCatching { task.taskInfo?.baseIntent }.getOrNull() ?: continue
            // By its data rather than its class: windows start through aliases too.
            if (base.data?.let { it.scheme == "omarchy" && it.host == "window" } != true) continue
            // A window that just closed removes its own task meanwhile; finishing it again throws.
            if (runtime.wm.windowByHandle(base.data?.lastPathSegment) == null) {
                dev.omalauncher.system.Tasks.logRemove("finishAndRemoveTask", runCatching { task.taskInfo?.taskId }.getOrNull() ?: -1, "a stale Linux window task", removes = true)
                runCatching { task.finishAndRemoveTask() }
            }
        }
    }

    /** The last Forward's DOWN went to a web window ([dispatchKeyEvent]). */
    private var forwardSent = false

    /** Super+Enter opens a terminal, as in Omarchy (the page has the rest of the keys). */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.isMetaPressed && event.action == KeyEvent.ACTION_DOWN && event.keyCode == KeyEvent.KEYCODE_ENTER) {
            runtime.terminal(null, "Terminal")
            return true
        }
        // Forward (the keyboard's key, a mouse's forward button) with a web window the user is in: its app's.
        // The helper presses it whole (down, up) at our DOWN; its UP is ours then too.
        if (event.keyCode == KeyEvent.KEYCODE_FORWARD && ::host.isInitialized) {
            if (event.action == KeyEvent.ACTION_DOWN) forwardSent = event.repeatCount == 0 && host.bridge.windowKey(WindowKeys.Key.FORWARD)
            if (forwardSent) return true
        }
        return super.dispatchKeyEvent(event)
    }

    /**
     * Home pressed while the shell is home already (singleTask: the intent comes back here): the page closes what's
     * open and goes to the first page, as a stock launcher does.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        arrived = intent
        // Home re-delivered to resize its window (unstick): not a Home press, the page stays where it is.
        if (intent.getBooleanExtra(EXTRA_UNSTICK, false)) return
        // Home pressed - not a notification's or the app entry's way here (toHome), which carries what it opens.
        // Nor the recents transition's launch of home or the switcher's (Switcher.EXTRA_RECENTS): its layer is coming up.
        val recents = intent.getBooleanExtra(dev.omalauncher.system.Switcher.EXTRA_RECENTS, false)
        // Nor a web window's minimise (WebWindows.EXTRA_APP_LEFT: its app's home-gesture lifecycle): home is in front already.
        val appLeft = intent.getBooleanExtra(WebWindows.EXTRA_APP_LEFT, false)
        // Nor a Linux window opening on home's page (WebWindows.toFront): home comes forward to show it.
        val windowFront = intent.getBooleanExtra(WebWindows.EXTRA_WINDOW_FRONT, false)
        if (intent.hasCategory(Intent.CATEGORY_HOME) && !intent.hasExtra(EXTRA_REDIRECTED) && !recents && !appLeft && !windowFront) homePressed()
        dev.omalauncher.AgentsSpool.opened(intent)
        // An edge gesture's "app drawer": home with its pull-up panel up.
        openPanel(intent)
        handleDebugExec(intent)
    }

    /** [EXTRA_HOME_PANEL] (an edge gesture's "app drawer", the old AI app's entries): home with that pull-up panel
     * up, [EXTRA_HOME_DRAFT] in the AI page's field. Sent once the page is ready (a cold start's intent too). */
    private fun openPanel(intent: Intent) {
        val kind = intent.getStringExtra(EXTRA_HOME_PANEL) ?: return
        val ev = org.json.JSONObject().put("kind", kind)
        intent.getStringExtra(EXTRA_HOME_DRAFT)?.let { d -> ev.put("draft", d) }
        // The launcher is the overlay over home (PullHost), as from every other way in; home's page asks it (state.ts
        // openPanel) only when the overlay's host isn't up yet.
        val pull = dev.omalauncher.system.PullHost.current
        if (pull != null && pull.open(kind, org.json.JSONObject().putOpt("draft", ev.optString("draft").ifEmpty { null }))) return
        host.whenReady { host.bridge.emit("home.panel", ev) }
    }

    /** SystemUI can deliver Home directly instead of going through our navigation consumer. */
    private fun homePressed() {
        // A full-screen Linux web window leaves full screen on Home (FL3), then Home goes on as ever.
        host.bridge.leaveFullScreen("home")
        val switcher = dev.omalauncher.system.Switcher
        if (switcher.homeVisible && switcher.homeMainPage && !switcher.open) {
            switcher.show(this, null)
        } else {
            host.bridge.emit("system.home", null)
        }
    }

    /** Back goes to the page: it closes the drawer, a folder or edit mode. A home screen has nowhere to go back to. */
    @Deprecated("Back reaches the page instead", ReplaceWith(""))
    override fun onBackPressed() {
        // Back from a full-screen Linux web window: it leaves full screen, nothing else (FL3).
        if (host.bridge.leaveFullScreen("back")) return
        // A web window the user is in (a quick page's card first): Back is its app's - back a page, at its root it closes.
        if (host.bridge.windowKey(WindowKeys.Key.BACK)) return
        host.bridge.emit("system.back", null)
    }

    // A home screen showing: widgets' sources run (they pause while no home is visible), the guest's on-screen helpers.
    override fun onStart() {
        super.onStart()
        dockLog("started (dock visible)")
        if (::host.isInitialized) dev.omalauncher.system.Switcher.homeStarted(host.bridge)
        // Back in front with a home panel still open: over the windows again (PanelLift).
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) PanelLift.current?.again()
        // A hosted widget that lost its drawing while home was away (its provider killed, a display gone): again.
        AppWidgets.get(this).heal()
        runtime.widgets.homeStarted()
        runtime.screenStarted()
    }

    override fun onStop() {
        super.onStop()
        dockLog("stopped (dock hidden)")
        // Out of sight: the switcher layer goes (an app was opened from it, or came up over it).
        if (::host.isInitialized) dev.omalauncher.system.Switcher.homeStopped(host.bridge)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) PanelLift.dropNow("home stopped")
        // An app was just opened from home: it moves to the front of the recent apps, out of sight.
        runtime.usage.settle()
        runtime.widgets.homeStopped()
        runtime.screenStopped()
    }

    /** The photo picker's answer (a background of one's own, from Style). */
    @Deprecated("The page's requests come back here", ReplaceWith(""))
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == ShellScreens.PICK_IMAGE_REQUEST) host.bridge.screens.imagePicked(data?.data?.takeIf { resultCode == RESULT_OK })
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == ShellBridge.MIC_REQUEST) host.bridge.micPermission(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    override fun onDestroy() {
        Log.i(TAG, "home destroyed: task $taskId, finishing $isFinishing, config change $isChangingConfigurations")
        scope.cancel()
        main.removeCallbacks(stuckCheck)
        runCatching { applicationContext.getSystemService(android.hardware.display.DisplayManager::class.java).unregisterDisplayListener(stuckListener) }
        // Not there when it went on to the home screen's instance (toHome).
        if (::host.isInitialized) {
            dev.omalauncher.system.Switcher.detach(host.bridge)
            host.destroy()
            // Not just recreated: a swipe up shouldn't find no home - made again in the background.
            if (isFinishing && !isChangingConfigurations) dev.omalauncher.system.Switcher.homeGone(this)
        }
        super.onDestroy()
    }

    private companion object {
        const val HOME_ROLE_REQUEST = 1
        const val STUCK_SETTLE_MS = 1500L
        const val EXTRA_UNSTICK = "dev.omalauncher.shell.unstick"
        const val TAG = "PowosShell"

        /** On a HOME intent that [toHome] sent: not Home pressed. */
        /** How long OxygenOS's video wallpapers play after an unlock or a fold. */
        const val WALLPAPER_SETTLE_MS = 2_500L
        const val EXTRA_REDIRECTED = "dev.omalauncher.shell.redirected"
    }
}

/**
 * The page is the only thing in home's window that may hold view focus. A text field in the page has the keyboard only
 * while the WebView holds Android's view focus: any other view in the window taking it (requestFocus from a native
 * view, a focusable view added next to the page) blurs the field and closes the keyboard - the launcher search lost
 * its keyboard 0.4-0.9 s after focus, document.hasFocus() still true (2026-10-28). Each focus change is logged
 * (PowosFocus, with a stack when it leaves the page) and a view that took it is made non-focusable and the focus handed
 * back. Native views are also made non-focusable where they're made ([neverFocus]); this catches whatever wasn't.
 */
internal fun keepFocusOnPage(web: View) {
    web.rootView.viewTreeObserver.addOnGlobalFocusChangeListener { old, new ->
        val msg = "PowosFocus: ${focusName(old)} -> ${focusName(new)}"
        if (new == null || new === web || isInside(new, web)) {
            Log.i("PowosShell", msg)
            return@addOnGlobalFocusChangeListener
        }
        Log.i("PowosShell", msg, Throwable("focus left the page"))
        new.neverFocus()
        if (web.isAttachedToWindow) web.requestFocus()
    }
}

private fun isInside(v: View, ancestor: View): Boolean {
    var p = v.parent
    while (p != null) {
        if (p === ancestor) return true
        p = p.parent
    }
    return false
}

private fun focusName(v: View?): String {
    if (v == null) return "null"
    val id = if (v.id != View.NO_ID) runCatching { v.resources.getResourceEntryName(v.id) }.getOrDefault(v.id.toString()) else "-"
    return "${v.javaClass.name}#$id(${v.parent?.javaClass?.simpleName})"
}

/**
 * Never takes view focus (nor its children): a native view in or beside the page's window. Touches still reach it -
 * clicks don't need focus - but a focus it took would blur the page's text field and close the keyboard.
 */
internal fun View.neverFocus() {
    isFocusable = false
    isFocusableInTouchMode = false
    if (this is android.view.ViewGroup) descendantFocusability = android.view.ViewGroup.FOCUS_BLOCK_DESCENDANTS
}

/** A Presentation (an offscreen widget / recon / preview window) that never takes window focus from home. */
internal fun android.app.Dialog.neverFocused() {
    window?.addFlags(android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL)
}

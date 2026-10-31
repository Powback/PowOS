package dev.omalauncher.system

import android.app.ActivityManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.Rect
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import dev.omalauncher.shell.WindowLog

/**
 * Android's floating (freeform) app windows ([AppWindows] opens them): which are on screen and where, and moving,
 * resizing, raising and closing them - what PowOS's own window frames ([WindowFrames]) drive, since OxygenOS draws no
 * caption for them. As the recents provider PowOS sees every task and holds MANAGE_ACTIVITY_TASKS (resizeTask, the
 * task stack listener) and REORDER_TASKS.
 *
 * HACK: TaskInfo.configuration / Configuration.windowConfiguration (a task's bounds and windowing mode),
 * IActivityTaskManager.resizeTask / registerTaskStackListener are hidden: reflected past the checks ([HiddenApi]).
 * ITaskStackListener isn't in the SDK, so its binder is a plain Binder that takes every call as "something changed".
 * Real fix: none for an app - WM Shell's desktop mode (the caption it would draw) is SystemUI's, off on this ROM.
 */
object FreeformTasks {
    private const val TAG = "PowosFreeform"

    /** WindowConfiguration.WINDOWING_MODE_FREEFORM. */
    private const val FREEFORM = 5

    /** WindowConfiguration.WINDOWING_MODE_FULLSCREEN and ACTIVITY_TYPE_STANDARD (an app, not home/recents/assistant). */
    private const val FULLSCREEN = 1
    private const val ACTIVITY_TYPE_STANDARD = 1

    /** ActivityTaskManager.RESIZE_MODE_USER: the window kept (no relaunch) while it's moved or resized. */
    private const val RESIZE_MODE_USER = 1

    /** A floating window: its task, its app (package), where it is (screen px) and whether it shows now. */
    data class Window(
        val id: Int,
        val pkg: String?,
        val bounds: Rect,
        val visible: Boolean,
        /** The density its app lays itself out at now (its task's configuration). */
        val dpi: Int = 0,
        /** Its task's label (TaskDescription): a PowOS (Linux) window's caption. */
        val label: String? = null,
    )

    /**
     * The floating windows, top-most first. [hadUnreadableTask] says whether THIS call's result is missing a task
     * whose window configuration briefly couldn't be read (right after it opened or changed, not "it isn't floating"):
     * a caller that publishes this list to the dock shouldn't treat a window dropped that way as closed.
     */
    fun list(context: Context): List<Window> = read(context).also { hadUnreadableTask = it.unreadable }.windows

    /** One [list] reading: the windows and whether a task in it was unreadable ([hadUnreadableTask]'s value for it). */
    class Read(
        val windows: List<Window>,
        val unreadable: Boolean,
    )

    /**
     * [list] with its unreadable flag in the result instead of the shared [hadUnreadableTask]: binder calls
     * (getRunningTasks, getAllRootTaskInfos), safe off the main thread - [WindowFrames] reads it on its own thread,
     * and a [list] on another thread meanwhile can't change this reading's flag.
     */
    fun read(context: Context): Read {
        HiddenApi.allow()
        val failed = BooleanArray(1)
        // getRunningTasks is deprecated for apps (their own tasks only); the recents provider sees them all.
        @Suppress("DEPRECATION")
        val tasks = runCatching { context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrDefault(emptyList())
        val z = stackOrder()?.withIndex()?.associate { (i, id) -> id to i }
        val result = (if (z == null) tasks else tasks.sortedBy { z[it.taskId] ?: Int.MAX_VALUE }).mapNotNull { window(it, failed) }
        return Read(result, failed[0])
    }

    /** Set by [list] after each call: see its doc. */
    @Volatile var hadUnreadableTask = false
        private set

    /** Tasks already logged as left to Android ([resizable] false), so the line comes once per task. */
    private val compatLogged = java.util.concurrent.ConcurrentHashMap.newKeySet<Int>()

    /** Whether task [t]'s app can be resized (TaskInfo.isResizeable, hidden; unreadable = yes, as before). */
    private fun resizable(t: ActivityManager.RunningTaskInfo): Boolean =
        runCatching { android.app.TaskInfo::class.java.getField("isResizeable").getBoolean(t) }.getOrDefault(true)

    /** Task [t] as a floating window, or null (another mode, a fixed-size app, or its window configuration unreadable). */
    private fun window(
        t: ActivityManager.RunningTaskInfo,
        failed: BooleanArray,
    ): Window? {
        // A web window (a task on a web window's own display, shell/WebWindowDisplays) is never a floating window of this
        // path, whatever its mode - no frame, no full-screen fix-up. Every other task (Linux windows too): as before.
        if (dev.omalauncher.shell.WebWindowDisplays.isWebWindow(t)) return null
        val wc = runCatching { windowConfiguration(t) }.onFailure { if (!unreadable) WindowLog.w(TAG, "can't read task ${t.taskId}'s window", it) }.getOrNull()
        unreadable = wc == null
        if (wc == null) { failed[0] = true; return null }
        if (wc.javaClass.getMethod("getWindowingMode").invoke(wc) != FREEFORM) return null
        val bounds = Rect(wc.javaClass.getMethod("getBounds").invoke(wc) as Rect)
        // A fixed-size (non-resizable) app is never a PowOS window, whatever its mode says: on the unfolded screen
        // OnePlus shows it in its compat box (a phone-sized portrait box centred on black, OplusCompatModeBgSurface)
        // and its task's bounds are that box, not where its surface is drawn - PowOS framed and dressed it as a
        // floating window and its crop at the box size, cut in the leash's own coordinates, drew Camera/Photos in a
        // box at the top-left with the UI cut off (the user, 2026-10-29: "I tried to open the photo app and it's...
        // or the camera app and it's broken"). Left exactly where Android puts it; WindowFrames drops its look.
        if (!resizable(t)) {
            if (compatLogged.add(t.taskId)) {
                WindowLog.i(TAG, "task ${t.taskId} (${(t.baseActivity ?: t.topActivity)?.packageName}) not resizable: Android places it (compat), PowOS leaves its surface alone")
            }
            return null
        }
        val visible = runCatching { android.app.TaskInfo::class.java.getField("isVisible").getBoolean(t) }.getOrDefault(true)
        val dpi = runCatching { (android.app.TaskInfo::class.java.getField("configuration").get(t) as Configuration).densityDpi }.getOrDefault(0)
        return Window(t.taskId, (t.baseActivity ?: t.topActivity)?.packageName, bounds, visible, dpi, t.taskDescription?.label?.toString())
    }

    /**
     * Task ids top-most first as WM stacks them (IActivityTaskManager.getAllRootTaskInfos walks the root tasks top to
     * bottom; a floating window's task is its own root), or null. getRunningTasks sorts by last-active time instead: a
     * window raised by a reorder (restore, a desktop switch) kept its old place there, so the frames stacked a lower
     * window's bar over the front one's (a drag on Calculator's bar moved Chrome, 2026-10-23) and the dock's "window in
     * front" was the wrong one. HACK: hidden, reflected like [minimise] (MANAGE_ACTIVITY_TASKS, held as the recents
     * provider). Real fix: none for an app.
     */
    private fun stackOrder(): List<Int>? =
        runCatching {
            val roots = atm().javaClass.getMethod("getAllRootTaskInfos").invoke(atm()) as List<*>
            roots.map { android.app.TaskInfo::class.java.getField("taskId").getInt(it) }
        }.onFailure { if (!noOrder) WindowLog.w(TAG, "no stacking order: windows in last-active order", it) }
            .also { noOrder = it.isFailure }.getOrNull()

    @Volatile private var noOrder = false

    /**
     * The app tasks showing full screen now (an ordinary activity: not home, recents, the assistant or a dream), top-most
     * first, as task id -> its package: on the unfolded home every app is a window ([toWindow] makes one of them).
     */
    fun fullScreen(
        context: Context,
        hiddenToo: Boolean = false,
    ): List<Pair<Int, String?>> {
        HiddenApi.allow()
        @Suppress("DEPRECATION")
        val tasks = runCatching { context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrDefault(emptyList())
        return tasks.filter { isFullScreenApp(it, hiddenToo) }.map { it.taskId to (it.baseActivity ?: it.topActivity)?.packageName }
    }

    /** [t] a standard app task in full screen - shown now, or also behind home ([hiddenToo]: a full-screen window gone home). */
    private fun isFullScreenApp(
        t: ActivityManager.RunningTaskInfo,
        hiddenToo: Boolean,
    ): Boolean {
        // A web window is home's page's, never adopted as a floating window (WindowFrames' adopt).
        if (dev.omalauncher.shell.WebWindowDisplays.isWebWindow(t)) return false
        val wc = runCatching { windowConfiguration(t) }.getOrNull() ?: return false
        val mode = wc.javaClass.getMethod("getWindowingMode").invoke(wc)
        val type = wc.javaClass.getMethod("getActivityType").invoke(wc)
        val visible = runCatching { android.app.TaskInfo::class.java.getField("isVisible").getBoolean(t) }.getOrDefault(false)
        return mode == FULLSCREEN && type == ACTIVITY_TYPE_STANDARD && (visible || hiddenToo)
    }

    /**
     * Task [id] (full screen) made a floating window at [bounds] (screen px): WindowContainerTransaction.setWindowingMode
     * + setBounds through WindowOrganizer, as WM Shell's desktop mode moves a task into a desktop. For an app opened
     * WITHOUT PowOS's launch options (another app, a notification of the system's, `am start`): Android puts a task
     * started with no source window full screen. HACK: hidden, reflected like [minimise]. Real fix: none for an app.
     */
    fun toWindow(
        context: Context,
        id: Int,
        bounds: Rect,
    ): Boolean =
        transact(context, id.also { markOwnFloat(it) }) { wct, token ->
            wct.javaClass.getMethod("setWindowingMode", token.javaClass, Int::class.javaPrimitiveType).invoke(wct, token, FREEFORM)
            wct.javaClass.getMethod("setBounds", token.javaClass, Rect::class.java).invoke(wct, token, bounds)
        }.onFailure { WindowLog.w(TAG, "can't make task $id a window", it) }.isSuccess

    /**
     * Task [id] over the whole screen ([on]: the app asked for full screen - a video, a game) or a floating window
     * again at [bounds]. What WM Shell's desktop mode does to move a task to full screen and back (DesktopTasksController:
     * windowing mode UNDEFINED = the display's full screen, bounds cleared; back: FREEFORM + its bounds), as a change
     * transition so WM Shell puts the app's content (its leash) where the task is. HACK: hidden, reflected like
     * [minimise]. Real fix: none for an app.
     */
    fun setFullScreen(
        context: Context,
        id: Int,
        on: Boolean,
        bounds: Rect?,
    ): Boolean {
        val mode = if (on) UNDEFINED else FREEFORM
        if (!on) markOwnFloat(id)
        val to = if (on) Rect() else bounds ?: Rect()
        // Full screen has square corners and no shadow; a window again is dressed at the next WindowFrames refresh.
        if (on) android.os.Handler(android.os.Looper.getMainLooper()).post { TaskSurfaces.undress(id) }
        return runCatching {
            apply(token(context, id), transition = true) { wct, token -> fullScreenChange(wct, token, id, if (on) null else to) }
        }
            .onFailure { WindowLog.w(TAG, "can't put task $id in windowing mode $mode", it) }.isSuccess
    }

    /** [setFullScreen]'s change: a window at [window], or full screen (null) and focusable again; its caption inset. */
    private fun fullScreenChange(
        wct: Any,
        token: Any,
        id: Int,
        window: Rect?,
    ) {
        val on = window == null
        modeAndBounds(wct, token, if (on) UNDEFINED else FREEFORM, window ?: Rect())
        captionFor(wct, token, id, window)
        // A window of a page off the screen was made hidden and not focusable (WindowFrames.showOnly, [away]): full
        // screen it is the app in front again, shown and taking the keys.
        if (on) {
            TaskLeash.setHidden(wct, token, false)
            TaskLeash.setFocusable(wct, token, true)
        }
    }

    /**
     * Floating task [id] to [bounds] (screen px) as a change transition WM Shell plays, so the app's content (its
     * leash) and its touches go there too - a bare applyTransaction moved the task in WM only. HACK: hidden, reflected
     * like [minimise]. Real fix: none for an app.
     */
    fun moveTo(
        context: Context,
        id: Int,
        bounds: Rect,
    ): Boolean =
        runCatching {
            apply(token(context, id), transition = true) { wct, token -> wct.javaClass.getMethod("setBounds", token.javaClass, Rect::class.java).invoke(wct, token, bounds) }
        }.onFailure { WindowLog.w(TAG, "can't move task $id", it) }.isSuccess

    private fun modeAndBounds(
        wct: Any,
        token: Any,
        mode: Int,
        bounds: Rect,
    ) {
        wct.javaClass.getMethod("setWindowingMode", token.javaClass, Int::class.javaPrimitiveType).invoke(wct, token, mode)
        wct.javaClass.getMethod("setBounds", token.javaClass, Rect::class.java).invoke(wct, token, bounds)
    }

    /** WindowConfiguration.WINDOWING_MODE_UNDEFINED: the display's own (full screen). */
    private const val UNDEFINED = 0

    /** The last task's window couldn't be read (logged once, not on every refresh; [read]/[hadUnreadableTask]
     * are the per-[list]-call signal callers act on). */
    @Volatile private var unreadable = false

    private fun windowConfiguration(t: ActivityManager.RunningTaskInfo): Any {
        val c = android.app.TaskInfo::class.java.getField("configuration").get(t) as Configuration
        return Configuration::class.java.getField("windowConfiguration").get(c)!!
    }

    /** Task [id]'s window moved/resized to [bounds] (screen px). */
    fun resize(
        id: Int,
        bounds: Rect,
    ): Boolean =
        runCatching {
            HiddenApi.allow()
            atm().javaClass.getMethod("resizeTask", Int::class.javaPrimitiveType, Rect::class.java, Int::class.javaPrimitiveType)
                .invoke(atm(), id, bounds, RESIZE_MODE_USER) as Boolean
        }.onFailure { WindowLog.w(TAG, "can't resize task $id", it) }.getOrDefault(false)

    /** Task [id]'s window above the others (a touch on its frame). */
    fun raise(
        context: Context,
        id: Int,
    ): Boolean =
        runCatching { context.getSystemService(ActivityManager::class.java).moveTaskToFront(id, 0) }
            .onFailure { WindowLog.w(TAG, "can't raise task $id", it) }.isSuccess

    /**
     * Task [id]'s window to the bottom, under home (out of sight, still running): what WM Shell's desktop mode does to
     * minimise (WindowContainerTransaction.reorder(token, onTop = false) through WindowOrganizer). HACK: the token
     * (TaskInfo.token) and the transaction's reorder are hidden, reflected. Real fix: none for an app.
     */
    fun minimise(
        context: Context,
        id: Int,
    ): Boolean =
        transact(context, id) { wct, token -> wct.javaClass.getMethod("reorder", token.javaClass, Boolean::class.javaPrimitiveType).invoke(wct, token, false) }
            .onFailure { WindowLog.w(TAG, "can't minimise task $id", it) }.isSuccess

    /**
     * Task [id] may take input focus ([on]) or not: a window whose page is off the screen stays above home with its
     * leash hidden (TaskSurfaces.show) and must not hold the key focus meanwhile. HACK: hidden, reflected like [minimise].
     */
    fun focusable(
        context: Context,
        id: Int,
        on: Boolean,
    ): Boolean =
        transact(context, id) { wct, token -> TaskLeash.setFocusable(wct, token, on) }
            .onFailure { WindowLog.w(TAG, "can't set task $id focusable=$on", it) }.isSuccess

    /**
     * Task [id]'s window on a page off the screen ([on]) or back on the shown one: hidden in WM and not focusable
     * (TaskLeash.setHidden), so it takes no touch and no key focus - a swipe where it sat goes to the page - and
     * shown and focusable again when its page shows. One WCT, the path [focusable] uses. HACK: hidden, reflected.
     */
    fun away(
        context: Context,
        id: Int,
        on: Boolean,
    ): Boolean =
        transact(context, id) { wct, token ->
            TaskLeash.setHidden(wct, token, on)
            TaskLeash.setFocusable(wct, token, !on)
        }.onFailure { WindowLog.w(TAG, "can't set task $id away=$on", it) }.isSuccess
            .also { WindowLog.i(TAG, "task $id ${if (on) "hidden in WM (off page, no input)" else "shown in WM (its page)"}: ok=$it") }

    /**
     * Task [id]'s content drawn at [dpi] (0: the screen's own again): a real per-task density, the app lays itself out
     * for it (WindowContainerTransaction.setDensityDpi, what WM Shell's desktop mode does to its windows; checked on
     * this ROM 2026-10-22: the task's configuration says the new dpi and its screen width in dp follows). HACK: hidden,
     * reflected like [minimise]. Real fix: none for an app.
     */
    fun density(
        context: Context,
        id: Int,
        dpi: Int,
    ): Boolean =
        transact(context, id) { wct, token -> wct.javaClass.getMethod("setDensityDpi", token.javaClass, Int::class.javaPrimitiveType).invoke(wct, token, dpi) }
            .onFailure { WindowLog.w(TAG, "can't set task $id to $dpi dpi", it) }.isSuccess

    /**
     * Apps that draw their own caption in a desktop window (Chromium: a captionBar inset turns on its tab strip in the
     * caption area, APPEARANCE_TRANSPARENT_CAPTION_BAR_BACKGROUND): under PowOS's in-task bar Chrome's strip came doubled
     * and misaligned, Brave padded the inset black. Decision: PowOS's bar stays (Chrome's header has no window buttons of
     * its own - it leaves them to SystemUI's caption, which PowOS shrinks to 1 px, OemCaption), as the overlay bar
     * ABOVE the window, and these tasks get no caption inset - the app lays out from its top with nothing to pad.
     * HACK: a package list, not the window's own appearance flag (hidden; only `dumpsys window` shows it). Real fix:
     * read APPEARANCE_TRANSPARENT_CAPTION_BAR_BACKGROUND per window (a WM Shell-side decor provider sees it).
     */
    fun drawsOwnCaption(pkg: String?): Boolean = pkg != null && (pkg in CAPTION_APPS || CAPTION_PREFIXES.any { pkg.startsWith(it) })

    private val CAPTION_APPS = setOf("com.android.chrome", "com.brave.browser", "com.microsoft.emmx", "com.vivaldi.browser", "com.kiwibrowser.browser", "org.chromium.chrome")
    private val CAPTION_PREFIXES = listOf("com.chrome.", "com.brave.browser_")

    /** Task [id]'s caption inset (TaskFrame's) taken off, if it has one: the app lays out from its top again. */
    fun dropCaptionInsets(
        context: Context,
        id: Int,
    ): Boolean {
        if (captions.remove(id) == null) return true
        return transact(context, id) { wct, token -> removeCaption(wct, token) }
            .onFailure { WindowLog.w(TAG, "task $id: caption inset not removed", it) }.isSuccess
    }

    /** The caption inset (px) each task's in-task bar (TaskFrame) asked for. */
    private val captions = java.util.concurrent.ConcurrentHashMap<Int, Int>()

    /** The captionBar insets sources' owner: one per process, so a later call replaces the earlier source. */
    private val captionOwner = android.os.Binder()

    /**
     * Task [id]'s app content laid out under a [height] px title bar at its top (the in-task bar, TaskFrame): a
     * captionBar insets source on the task (WindowContainerTransaction.addInsetsSource, what WM Shell's desktop window
     * decoration does for its caption). [bounds]: the task's (screen px). Taken off again by [setFullScreen].
     * HACK: hidden, reflected like [minimise]. Real fix: none for an app.
     */
    fun captionInsets(
        context: Context,
        id: Int,
        bounds: Rect,
        height: Int,
    ): Boolean =
        transact(context, id) { wct, token -> addCaption(wct, token, bounds, height) }
            .onSuccess { captions[id] = height }
            .onFailure { WindowLog.w(TAG, "task $id: no caption inset", it) }.isSuccess

    /** The in-task bar's caption inset (TaskFrame) off for the full screen ([to] null), back with the window at [to]. */
    private fun captionFor(
        wct: Any,
        token: Any,
        id: Int,
        to: Rect?,
    ) {
        val h = captions[id] ?: return
        runCatching { if (to == null) removeCaption(wct, token) else addCaption(wct, token, to, h) }
            .onFailure { WindowLog.w(TAG, "task $id: caption inset not ${if (to == null) "removed" else "restored"}", it) }
    }

    private fun addCaption(
        wct: Any,
        token: Any,
        bounds: Rect,
        height: Int,
    ) {
        val m = wct.javaClass.methods.filter { it.name == "addInsetsSource" }.maxByOrNull { it.parameterCount } ?: error("no addInsetsSource")
        val p = m.parameterTypes
        // HACK: Android 14 takes the frame in screen coordinates (5 parameters); 15+ relative to the task, with
        // bounding rects (and on 16 flags) after it. Real fix: none, the hidden signature moves per release.
        val frame = if (p.size <= 5) Rect(bounds.left, bounds.top, bounds.right, bounds.top + height) else Rect(0, 0, bounds.width(), height)
        val fixed = listOf(token, captionOwner, 0, android.view.WindowInsets.Type.captionBar(), frame)
        val extra = p.drop(fixed.size).map { if (it == Int::class.javaPrimitiveType) 0 else if (it == Boolean::class.javaPrimitiveType) false else null }
        m.invoke(wct, *(fixed + extra).toTypedArray())
    }

    private fun removeCaption(
        wct: Any,
        token: Any,
    ) {
        val m = wct.javaClass.methods.first { it.name == "removeInsetsSource" && it.parameterCount == 4 }
        m.invoke(wct, token, captionOwner, 0, android.view.WindowInsets.Type.captionBar())
    }

    /** One WindowContainerTransaction on task [id]'s container (any windowing mode), applied through WindowOrganizer. */
    private fun transact(
        context: Context,
        id: Int,
        change: (Any, Any) -> Unit,
    ): Result<Unit> = runCatching { apply(token(context, id), change = change) }

    @Volatile private var windowsShown = false
    @Volatile private var homeTypingNow = false
    @Volatile private var homeFocusTold: Boolean? = null

    /**
     * Desktop mode (docs/DESKTOP-NATIVE.md step 7): PowOS's home task is non-focusable while desktop windows show, so a
     * tap on the wallpaper or home doesn't take the focus from them and hide them; focusable again when none show
     * (folded included) or while a shell text field takes the keyboard ([homeTyping]). WindowFrames' refresh, any thread.
     */
    fun homeFocusable(
        context: Context,
        shown: Boolean,
        ids: Collection<Int> = emptyList(),
    ) {
        windowsShown = shown
        shownIds = ids.toSet()
        applyHomeFocus(context)
    }

    /** The shown window tasks (WindowFrames' refresh). */
    @Volatile private var shownIds: Set<Int> = emptySet()

    /** Window tasks made non-focusable while a shell text field types ([homeTyping]); focusable again after. */
    private val typingHeld = mutableSetOf<Int>()

    /** A PowOS shell text field has the keyboard now (keyboard.show till keyboard.hide): no window task may take focus. */
    val typing get() = homeTypingNow

    /**
     * A shell text field has the keyboard ([on]) or let it go: home's non-focusable flag is lifted meanwhile so
     * ShellBridge.keyboard's moveTaskToFront can give it the input focus (57fcf37b).
     * HACK: keyed to keyboard.show/hide, not to the field's own focus/blur - a field blurred without keyboard.hide keeps
     * home focusable until the next hide. Real fix: the page reports text-field focus through the bridge.
     */
    fun homeTyping(
        context: Context,
        on: Boolean,
    ) {
        homeTypingNow = on
        applyHomeFocus(context)
    }

    @Synchronized
    private fun applyHomeFocus(context: Context) {
        windowsFocus(context)
        val focusable = !windowsShown || homeTypingNow
        if (focusable == homeFocusTold) return
        val id = homeTaskId(context) ?: return
        runCatching { apply(token(context, id)) { wct, token -> TaskLeash.setFocusable(wct, token, focusable) } }
            .onSuccess {
                homeFocusTold = focusable
                WindowLog.i(TAG, "home task $id ${if (focusable) "focusable" else "non-focusable (desktop windows show)"}")
            }.onFailure { WindowLog.w(TAG, "can't set home task $id focusable=$focusable", it) }
    }

    /**
     * While a shell text field types, every shown window task is non-focusable (still shown, still on top): WM can't
     * hand the input focus to a floating window (a Linux window's PowosWindowActivity was the top focusable task, so a
     * focus update gave it the focus and the IME was hidden for HIDE_INPUT_TARGET_CHANGED, 2026-10-28), and focus falls
     * to home, the top focusable task. Focusable again on keyboard.hide.
     * HACK: keyed to keyboard.show/hide like [homeTyping]; a touch on a window's content while the field keeps its
     * focus doesn't focus that window till keyboard.hide (the drawer closing, the field's blur). Real fix: the page
     * reports text-field focus/blur through the bridge, and a touch outside home's window ends the typing.
     */
    private fun windowsFocus(context: Context) {
        val hold = if (homeTypingNow && windowsShown) shownIds else emptySet()
        val change = (hold - typingHeld).map { it to false } + (typingHeld - hold).map { it to true }
        for ((id, focusable) in change) {
            runCatching { apply(token(context, id)) { wct, token -> TaskLeash.setFocusable(wct, token, focusable) } }
                .onFailure { WindowLog.w(TAG, "can't set window task $id focusable=$focusable", it) }
            // A task gone meanwhile has nothing to restore: it leaves the set either way.
            if (focusable) typingHeld.remove(id) else typingHeld.add(id)
        }
        if (change.isNotEmpty()) WindowLog.i(TAG, "typing on home: window tasks non-focusable $typingHeld")
    }

    /** PowOS's home task (this app's CATEGORY_HOME activity), or null when it isn't running. */
    fun homeTaskId(context: Context): Int? =
        runCatching {
            @Suppress("DEPRECATION")
            context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS).firstOrNull {
                it.baseIntent.hasCategory(android.content.Intent.CATEGORY_HOME) && it.baseActivity?.packageName == context.packageName
            }?.taskId
        }.getOrNull()

    /** Task [id]'s WindowContainerToken (TaskInfo.token, hidden). */
    private fun token(
        context: Context,
        id: Int,
    ): Any {
        HiddenApi.allow()
        @Suppress("DEPRECATION")
        val info = context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS).firstOrNull { it.taskId == id } ?: error("no task $id")
        return android.app.TaskInfo::class.java.getField("token").get(info)!!
    }

    /**
     * Applies [change] to the window of [token]. [transition]: as a change transition (WindowOrganizer.startNewTransition,
     * TRANSIT_CHANGE) that WM Shell plays, so its leash - where the app's content is drawn - goes to the new bounds too.
     * A bare applyTransaction moves the task in WM only: WM Shell owns the task's surface position, and the content
     * stayed drawn where the window had been until a minimise and restore (e2e r3 2026-10-23: bar at 887, the app at
     * 556 after a bar drag).
     */
    private fun apply(
        token: Any,
        transition: Boolean = false,
        change: (Any, Any) -> Unit,
    ) {
        val wctClass = Class.forName("android.window.WindowContainerTransaction")
        val wct = wctClass.getConstructor().newInstance()
        change(wct, token)
        val organizer = Class.forName("android.window.WindowOrganizer")
        val o = organizer.getConstructor().newInstance()
        if (transition) {
            val started = runCatching { organizer.getMethod("startNewTransition", Int::class.javaPrimitiveType, wctClass).invoke(o, TRANSIT_CHANGE, wct) }
            if (started.isSuccess) return
            WindowLog.w(TAG, "no change transition, the bounds without one", started.exceptionOrNull())
        }
        organizer.getMethod("applyTransaction", wctClass).invoke(o, wct)
    }

    /**
     * A finger moving or resizing task [id]'s window: its bounds set straight through WindowOrganizer each move, as WM
     * Shell's desktop mode does (FluidResizeTaskPositioner: WindowContainerTransaction.setBounds, drag-resizing on
     * while it's resized), so the app lays itself out at the new size as the finger goes. Through resizeTask the app's
     * content took the new size only after the finger lifted (the user, 2026-10-23); likely its change transition per
     * call queueing - logcat PowosWindowResize has the live path's numbers per drag.
     * HACK: the token and the transaction's setBounds/setDragResizing are hidden, reflected like [minimise]; a
     * failure falls back to [resize]. Real fix: none for an app.
     */
    class Live(
        context: Context,
        private val id: Int,
        private val resizing: Boolean,
    ) {
        private val token = runCatching { token(context, id) }.onFailure { WindowLog.w(TAG, "no live bounds for task $id", it) }.getOrNull()
        private var started = false

        /** The window to [bounds] now: true when applied (a fallback to resizeTask says false). */
        fun to(bounds: Rect): Boolean = set(bounds, drag = true)

        /** The finger lifted, the window at [bounds]: drag-resizing off. */
        fun end(bounds: Rect) {
            if (!set(bounds, drag = false)) resize(id, bounds)
        }

        private fun set(
            bounds: Rect,
            drag: Boolean,
        ): Boolean {
            val t = token ?: return resize(id, bounds).let { false }
            return runCatching {
                // A move's one call (the finger lifted) as a transition: WM Shell puts the app's content where the window
                // is. Never a resize's: its end in a transition left the app at its old size in a white new-size
                // window and WM at the old bounds (the user, 13:43 2026-10-23); resizes stay plain transactions.
                apply(t, transition = !drag && !resizing) { wct, tok ->
                    wct.javaClass.getMethod("setBounds", tok.javaClass, Rect::class.java).invoke(wct, tok, bounds)
                    if (resizing && drag != started) wct.javaClass.getMethod("setDragResizing", tok.javaClass, Boolean::class.javaPrimitiveType).invoke(wct, tok, drag)
                }
                started = drag
                true
            }.onFailure { WindowLog.w(TAG, "can't set task $id's bounds", it) }.getOrElse { resize(id, bounds).let { false } }
        }
    }

    /**
     * The app tasks floating now - Android's freeform (5) or OnePlus' own floating window (WindowConfiguration
     * WINDOWING_MODE_ZOOM, 100: its "..." menu's "Floating window", OxygenOS 16 SystemUI TransitionUtil) - on the main
     * display, as task id -> its package. Web windows (their own displays) never.
     */
    fun floatingApps(context: Context): List<Pair<Int, String?>> = floatingModes(context).map { (id, pkg, _) -> id to pkg }

    /** [floatingApps] with each task's windowing mode (freeform 5 or OnePlus' zoom [ZOOM]). */
    fun floatingModes(context: Context): List<Triple<Int, String?, Int>> {
        HiddenApi.allow()
        @Suppress("DEPRECATION")
        val tasks = runCatching { context.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS) }.getOrDefault(emptyList())
        return tasks.mapNotNull { t ->
            if (dev.omalauncher.shell.WebWindowDisplays.isWebWindow(t)) return@mapNotNull null
            val mode = runCatching { windowConfiguration(t).let { it.javaClass.getMethod("getWindowingMode").invoke(it) as Int } }.getOrNull()
            if (mode != FREEFORM && mode != ZOOM) null else Triple(t.taskId, (t.baseActivity ?: t.topActivity)?.packageName, mode)
        }
    }

    /**
     * D1 (the user 2026-10-31: "we were supposed to add a desk.window option in addition to like the floating window
     * thing"): task id -> when the user made it an Android floating window ON PURPOSE (uptime ms) - the "..." menu's or
     * the switcher's "Floating window", OnePlus' swipe-and-hold Floating window. Such a task stays a native floating
     * window: shell/SystemFloat never turns it into a web window, a web window never pulls it back (WebWindows.follow).
     * Dropped once the task floats no more ([retainNativeFloats]).
     */
    private val nativeFloats = java.util.concurrent.ConcurrentHashMap<Int, Long>()

    /** Task [id] is becoming a native floating window by the user's choice (see [nativeFloats]). */
    fun markNativeFloat(id: Int) {
        nativeFloats[id] = android.os.SystemClock.uptimeMillis()
    }

    /**
     * Whether task [id], floating in windowing [mode] now, is a native floating window the user picked: marked
     * ([markNativeFloat]), or in OnePlus' zoom mode (100) without PowOS doing it - only OnePlus' own UI makes that
     * mode (its "..." menu's Floating window, its swipe-and-hold Floating window panel), an app can't ask for it. Such
     * a zoom task is marked here, so it stays native when it later turns freeform (resized).
     */
    fun isNativeFloat(
        id: Int,
        mode: Int,
    ): Boolean {
        if (nativeFloats.containsKey(id)) return true
        if (mode != ZOOM || isOwnFloat(id)) return false
        markNativeFloat(id)
        return true
    }

    /** Task [id] is no native floating window of the user's any more ("Desktop window" picked for it). */
    fun clearNativeFloat(id: Int) {
        nativeFloats.remove(id)
    }

    /** Marks of tasks no longer in [floating] dropped (a fresh mark kept [OWN_FLOAT_MS]: the task may not float yet). */
    fun retainNativeFloats(floating: Set<Int>) {
        val now = android.os.SystemClock.uptimeMillis()
        nativeFloats.entries.removeIf { (id, at) -> id !in floating && now - at > OWN_FLOAT_MS }
    }

    /** OnePlus' WINDOWING_MODE_ZOOM: its own floating ("zoom") window. */
    const val ZOOM = 100

    /** Task id -> when PowOS itself last made it float (uptime ms): shell/SystemFloat leaves those alone. */
    private val ownFloats = java.util.concurrent.ConcurrentHashMap<Int, Long>()

    /** PowOS is making task [id] a floating window now (not the system's own menu): shell/SystemFloat skips it. */
    fun markOwnFloat(id: Int) {
        ownFloats[id] = android.os.SystemClock.uptimeMillis()
    }

    /** Task [id] floated by PowOS's own hand within the last [OWN_FLOAT_MS]. */
    fun isOwnFloat(id: Int): Boolean {
        val at = ownFloats[id] ?: return false
        if (android.os.SystemClock.uptimeMillis() - at < OWN_FLOAT_MS) return true
        ownFloats.remove(id)
        return false
    }

    private const val OWN_FLOAT_MS = 5000L

    /**
     * Calls [changed] (on a binder thread) whenever Android's tasks change - opened, raised, moved, closed; a handle to
     * stop it, or null where the listener can't be registered.
     */
    fun listen(changed: () -> Unit): (() -> Unit)? {
        val binder =
            object : Binder() {
                override fun onTransact(
                    code: Int,
                    data: Parcel,
                    reply: Parcel?,
                    flags: Int,
                ): Boolean {
                    if (code == INTERFACE_TRANSACTION) return super.onTransact(code, data, reply, flags)
                    changed()
                    return true
                }
            }
        return runCatching {
            HiddenApi.allow()
            val type = Class.forName("android.app.ITaskStackListener")
            val listener = Class.forName("android.app.ITaskStackListener\$Stub").getMethod("asInterface", IBinder::class.java).invoke(null, binder)
            atm().javaClass.getMethod("registerTaskStackListener", type).invoke(atm(), listener)
            WindowLog.i(TAG, "task stack listener on")
            val stop: () -> Unit = {
                runCatching { atm().javaClass.getMethod("unregisterTaskStackListener", type).invoke(atm(), listener) }
            }
            stop
        }.onFailure { WindowLog.w(TAG, "no task stack listener", it) }.getOrNull()
    }

    private const val MAX_TASKS = 24

    /** WindowManager.TRANSIT_CHANGE (hidden). */
    private const val TRANSIT_CHANGE = 6

    private fun atm(): Any = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
}

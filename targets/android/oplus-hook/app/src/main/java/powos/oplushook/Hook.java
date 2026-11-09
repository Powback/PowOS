package powos.oplushook;

import android.app.Activity;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;

import java.util.Map;
import java.util.WeakHashMap;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * OnePlus's launcher (com.android.launcher, OxygenOS 16) with a third-party home - PowOS's launcher or desktop.
 * OnePlus's launcher stays the gesture/recents provider; these hooks give the third-party home what its own home gets.
 * Found by reading the decompiled launcher against AOSP Launcher3 (android16-release); see README.md.
 *
 * Every hook is guarded: a launcher update that renames something only logs, never crashes the launcher.
 */
public class Hook implements IXposedHookLoadPackage {
    private static final String TAG = "PowOS-oplushook";
    private static final String LAUNCHER = "com.android.launcher";
    private static final String SYSTEMUI = "com.android.systemui";
    private static final String BATTERY = "com.oplus.battery";
    /** Settings.Global key game-boost.sh sets to the boosted game's app id (GameBoost.VENDOR_GAME_KEY). */
    static final String VENDOR_GAME_KEY = "powos_game_front";
    /** com.oplus.battery's appType for a game (StateManager: an OifaceManager game -> 4; category_4 of its table). */
    static final int APP_TYPE_GAME = 4;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lp) {
        if (SYSTEMUI.equals(lp.packageName)) {
            darkSplitVeilWhenLoaded(lp.classLoader);
            desktopWindowItemWhenLoaded(lp.classLoader);
            return;
        }
        if (BATTERY.equals(lp.packageName)) {
            gameClassWhileBoosted(lp.classLoader);
            return;
        }
        if (!LAUNCHER.equals(lp.packageName))
            return;
        swipeToHome(lp.classLoader);
        splitAndFloat(lp.classLoader);
        keepTaskbar(lp.classLoader);
        revealTaskbar(lp.classLoader);
    }

    /**
     * The taskbar / "quick peek" dock: OverviewComponentObserver.updateOverviewTargets() switches OnePlus's own
     * taskbar setting off (Settings.System enable_launcher_taskbar = 0, after backing up the user's value) whenever
     * the default home isn't OnePlus's launcher. Drop exactly that write: the one that comes from there; the user's own
     * switch in Settings keeps working, both ways. (Forcing mIsDefaultHome instead would also change the recents/home
     * routing.)
     *
     * At the write itself, not around updateOverviewTargets: that's a private method ART inlines into its callers, so a
     * hook on it never ran (the setting went back to 0 on every launcher start, 2026-10-17). A stack trace still lists
     * inlined frames, so the caller check holds either way.
     */
    private static void keepTaskbar(ClassLoader cl) {
        XC_MethodHook dropObserversOff = new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                if (param.args.length < 3 || !"enable_launcher_taskbar".equals(param.args[1]))
                    return;
                if (!"0".equals(String.valueOf(param.args[2])))
                    return;
                for (StackTraceElement e : new Throwable().getStackTrace()) {
                    if (e.getClassName().equals("com.android.quickstep.OverviewComponentObserver")) {
                        param.setResult(true); // as if written: Settings.System.put* return whether it was
                        return;
                    }
                }
            }
        };
        try {
            for (String m : new String[] {"putInt", "putIntForUser", "putString", "putStringForUser"})
                XposedBridge.hookAllMethods(android.provider.Settings.System.class, m, dropObserversOff);
        } catch (Throwable t) {
            log("keepTaskbar", t);
        }
    }

    /**
     * The (transient) taskbar in apps, revealed by a short swipe up. Under a third-party home (PowOS) it stayed stashed,
     * for two reasons, both OnePlus assuming its own home is the default:
     * - AbsSwipeUpHandler only reveals it when activityInterface.getTaskbarActivityContext() gives the taskbar.
     *   LauncherActivityInterface (OnePlus home) returns the global one, TaskbarUtils.getTaskbarActivityContext();
     *   FallbackActivityInterface (any other home) doesn't override it, so BaseActivityInterface returns null.
     * - OplusTaskbarStashController.TransitionCallback.canResponseTransition() requires OnePlus's Launcher activity to
     *   exist with all its app transitions ended. With another home that activity is never created, so it was always
     *   false. No Launcher activity means no Launcher transition can be running: that term is true then. The method's
     *   other conditions (in an app, taskbar has icons) are kept as OnePlus computes them.
     * - "Taskbar has icons" was never true either: OplusTaskbarModelCallbacks.finishBindingItems() defers putting the
     *   bound items into the taskbar (commitItemsToUI) until OnePlus's Launcher activity exists. commitItemsToUI doesn't
     *   use it, so with another home they're committed right away (the deferred refresh still runs if it ever starts).
     */
    private static void revealTaskbar(ClassLoader cl) {
        try {
            Class<?> fallback = XposedHelpers.findClass("com.android.quickstep.FallbackActivityInterface", cl);
            Class<?> taskbarUtils = XposedHelpers.findClass("com.android.launcher3.taskbar.TaskbarUtils", cl);
            Class<?> base = XposedHelpers.findClass("com.android.quickstep.BaseActivityInterface", cl);
            XposedBridge.hookAllMethods(base, "getTaskbarActivityContext", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (param.getResult() == null && fallback.isInstance(param.thisObject))
                        param.setResult(XposedHelpers.callStaticMethod(taskbarUtils, "getTaskbarActivityContext"));
                }
            });
            Class<?> launcher = XposedHelpers.findClass("com.android.launcher3.Launcher", cl);
            Class<?> callback = XposedHelpers.findClass("com.android.launcher3.taskbar.OplusTaskbarStashController$TransitionCallback", cl);
            XposedHelpers.findAndHookMethod(callback, "canResponseTransition", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        if ((Boolean) param.getResult())
                            return;
                        Object tracker = XposedHelpers.getStaticObjectField(launcher, "ACTIVITY_TRACKER");
                        if (XposedHelpers.callMethod(tracker, "getCreatedActivity") != null)
                            return; // OnePlus home is running: its answer stands
                        Object stash = XposedHelpers.getSurroundingThis(param.thisObject);
                        if (!(Boolean) XposedHelpers.callMethod(stash, "hasAnyFlag", 1L))
                            return; // not in an app
                        Object taskbar = XposedHelpers.getObjectField(stash, "mActivity");
                        Object view = taskbar == null ? null : XposedHelpers.callMethod(taskbar, "getTaskbarView");
                        if (view != null && ((android.view.ViewGroup) view).getChildCount() > 0)
                            param.setResult(true);
                    } catch (Throwable t) {
                        log("revealTaskbar canResponseTransition", t);
                    }
                }
            });
            XposedHelpers.findAndHookMethod("com.android.launcher3.taskbar.OplusTaskbarModelCallbacks", cl, "finishBindingItems",
                "com.android.launcher3.util.IntSet", new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        try {
                            if (XposedHelpers.getObjectField(param.thisObject, "mDeferTaskOnLauncherReady") != null)
                                XposedHelpers.callMethod(param.thisObject, "commitItemsToUI");
                        } catch (Throwable t) {
                            log("revealTaskbar finishBindingItems", t);
                        }
                    }
                });
        } catch (Throwable t) {
            log("revealTaskbar", t);
        }
    }

    /**
     * Swiping up to a third-party home showed the wallpaper for ~1-2 s: the shell hides the opening home task's leash
     * and expects the launcher to show it. AOSP's FallbackSwipeHandler.setHomeScaleAndAlpha() calls setShow();
     * OnePlus's copy (older code) only sets matrix and alpha, so the home animated in invisibly until the recents
     * transition timed out. Add AOSP's line back.
     */
    private static void swipeToHome(ClassLoader cl) {
        try {
            Class<?> handler = XposedHelpers.findClass("com.android.quickstep.FallbackSwipeHandler", cl);
            XposedBridge.hookAllMethods(handler, "setHomeScaleAndAlpha", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        // Shown and fully opaque for the whole gesture: the fallback fades the home in (alpha 0->1)
                        // while recents fades out over the system wallpaper - a crossfade to the wallpaper. Like
                        // iOS / OnePlus's own home: the home is simply there behind the shrinking app.
                        Object props = XposedHelpers.callMethod(param.args[0], "setShow");
                        XposedHelpers.callMethod(props, "setAlpha", 1f);
                    } catch (Throwable t) {
                        log("setShow", t);
                    }
                }
            });
        } catch (Throwable t) {
            log("swipeToHome", t);
        }
    }

    private static final Map<Activity, Object> panels = new WeakHashMap<>();
    private static final Map<Object, Float> downX = new WeakHashMap<>();
    private static final Map<Object, Integer> fingerOffset = new WeakHashMap<>();
    private static volatile boolean splitPick; // the home intent being started is for picking split's second app
    private static volatile Integer dragOffset; // the finger's sideways travel during a gesture over a third-party home
    private static final int SCROLL_SIGN = 1; // the window's x offset: the same sign (checked on the Open)
    private static final int SIGN = 1; // the panel's offset: finger left = negative

    /**
     * Split screen / floating window (drag the app to a side or a corner during the gesture) need the gesture's
     * "trigger panel". OplusBaseSwipeUpHandler.onActivityInit only takes it from OnePlus's own Launcher activity
     * (launcher.getTriggerPanel()); with a third-party home the gesture runs in RecentsActivity and the panel stays
     * null, so the options never trigger. Inflate the same panel into RecentsActivity, as Launcher does from its
     * ViewStub, and hand it to the handler. The code after that already handles a missing Launcher.
     */
    private static void splitAndFloat(ClassLoader cl) {
        try {
            Class<?> handler = XposedHelpers.findClass("com.oplus.quickstep.gesture.OplusBaseSwipeUpHandler", cl);
            Class<?> launcher = XposedHelpers.findClass("com.android.launcher.Launcher", cl);
            Class<?> multi = XposedHelpers.findClass("com.oplus.quickstep.rapidreaction.widget.MultiTriggerPanelView", cl);
            XposedBridge.hookAllMethods(handler, "onActivityInit", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        Object self = param.thisObject;
                        if (XposedHelpers.getObjectField(self, "triggerPanel") != null)
                            return;
                        Object created = XposedHelpers.callMethod(
                            XposedHelpers.getObjectField(self, "mActivityInterface"), "getCreatedActivity");
                        if (!(created instanceof Activity) || launcher.isInstance(created))
                            return; // OnePlus's own home: its code already did this
                        Object panel = panelFor((Activity) created, cl);
                        if (panel == null)
                            return;
                        XposedHelpers.setObjectField(self, "triggerPanel", panel);
                        XposedHelpers.setBooleanField(self, "isSplitAndFloatTriggerPanel", multi.isInstance(panel));
                        XposedHelpers.callMethod(panel, "setSwipeUpHandler", self);
                    } catch (Throwable t) {
                        log("trigger panel", t);
                    }
                }
            });
            // The panel picks a target from the swipe's progress and a sideways offset; OnePlus takes that offset from
            // the recents view, which a third-party home's switcher (RecentsActivity) never scrolls during the
            // gesture - the offset stayed 0 and only the middle could be picked. The finger's own sideways travel then.
            XposedBridge.hookAllMethods(handler, "onMotionEvent", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        android.view.MotionEvent e = (android.view.MotionEvent) param.args[0];
                        Object self = param.thisObject;
                        Object panel = XposedHelpers.getObjectField(self, "triggerPanel");
                        if (e == null || panel == null || !panels.containsValue(panel))
                            return; // OnePlus's own home: its recents view supplies the offset
                        if (e.getActionMasked() == android.view.MotionEvent.ACTION_DOWN || !downX.containsKey(self)) {
                            downX.put(self, e.getRawX());
                            View rv = (View) XposedHelpers.getObjectField(self, "mRecentsView");
                            if (rv != null) { // a new gesture: the switcher as it was, should the last one have left it faded
                                rv.animate().cancel();
                                rv.setAlpha(1f);
                            }
                        }
                        int off = (int) (SIGN * (e.getRawX() - downX.get(self)));
                        fingerOffset.put(panel, off);
                        int a = e.getActionMasked();
                        dragOffset = a == android.view.MotionEvent.ACTION_UP || a == android.view.MotionEvent.ACTION_CANCEL ? null : off;
                        XposedHelpers.callMethod(panel, "updateHorizontalOffset", off);
                    } catch (Throwable t) {
                        log("trigger offset", t);
                    }
                }
            });
            // The window follows the finger sideways, as over OnePlus's home - there its recents view scrolls with the
            // finger and the window takes that scroll; here the scroll stays 0. Only while the finger is down: the
            // drop animation after the release is OnePlus's.
            XposedBridge.hookAllMethods(XposedHelpers.findClass("com.android.quickstep.views.OplusRecentsViewImpl", cl), "getOffsetXForTSV", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    Integer off = dragOffset;
                    if (off != null)
                        param.setResult((float) (SCROLL_SIGN * off));
                }
            });
            // When the window reaches a target, OnePlus moves the other recents cards away by winding the recents view's
            // own enter animation back to 0. Over its home that zooms them off screen; RecentsActivity's grid at 0 draws
            // them full-screen size, still visible - huge windows behind the one being dropped. The intent (out of the
            // way) here: the switcher fades out while a target is selected and back in if the finger leaves it. The
            // dragged window is the app's own surface, not part of this view.
            XposedBridge.hookAllMethods(handler, "createRecentsAnimationForTriggerPanel", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        Object self = param.thisObject;
                        if (!panels.containsValue(XposedHelpers.getObjectField(self, "triggerPanel")))
                            return;
                        View rv = (View) XposedHelpers.getObjectField(self, "mRecentsView");
                        if (rv == null)
                            return;
                        boolean reverse = (Boolean) param.args[0];
                        rv.animate().cancel();
                        rv.animate().alpha(reverse ? 1f : 0f).setDuration((Long) param.args[3]).start();
                    } catch (Throwable t) {
                        log("trigger recents", t);
                    }
                }
            });
            // Split View dropped: OnePlus then shows its home to pick the second app (tap an icon, it fills the other
            // half). FallbackSwipeHandler starts the third-party home (PowOS) for that; the home intent says why
            // (powos.split_pick), so PowOS opens its app grid instead of just showing the desktop. 3 = split
            // (OnePuttUtils options: 1 floating window, 3 split, 4 capsule).
            XposedBridge.hookAllMethods(XposedHelpers.findClass("com.android.quickstep.FallbackSwipeHandler", cl), "createHomeAnimationFactory", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    try {
                        splitPick = (Integer) XposedHelpers.callMethod(param.thisObject, "getSelectedOptionsType") == 3;
                    } catch (Throwable t) {
                        log("split pick", t);
                    }
                }

                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    splitPick = false;
                }
            });
            XposedBridge.hookAllMethods(XposedHelpers.findClass("android.app.ContextImpl", cl), "startActivity", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (!splitPick || param.args.length == 0 || !(param.args[0] instanceof android.content.Intent))
                        return;
                    android.content.Intent i = (android.content.Intent) param.args[0];
                    if (i.hasCategory(android.content.Intent.CATEGORY_HOME))
                        i.putExtra("powos.split_pick", true);
                }
            });
            // ...and on every frame OnePlus sets it again from the recents view's scroll (0 here) - through a setter ART
            // inlines, so hooking the setter misses it. The finger's offset goes in right before the panel picks.
            XposedBridge.hookAllMethods(multi, "updateProgress", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    Integer off = fingerOffset.get(param.thisObject);
                    if (off != null)
                        XposedHelpers.setIntField(param.thisObject, "centerPointHorizontalOffset", off);
                }
            });
        } catch (Throwable t) {
            log("splitAndFloat", t);
        }
    }

    /** The panel in this RecentsActivity, inflated once - the layout Launcher would pick (multi when supported). */
    private static Object panelFor(Activity a, ClassLoader cl) {
        Object cached = panels.get(a);
        if (cached != null)
            return cached;
        boolean single;
        try {
            Object fwm = XposedHelpers.callStaticMethod(
                XposedHelpers.findClass("com.oplus.flexiblewindow.FlexibleWindowManager", cl), "getInstance");
            Map<?, ?> info = (Map<?, ?>) XposedHelpers.callMethod(fwm, "getMinimizedInfo", a.getApplicationContext());
            single = !info.containsKey("androidx.flexible.minimized.corner.weight"); // Launcher's own choice
        } catch (Throwable t) {
            single = false;
        }
        int layout = a.getResources().getIdentifier(
            single ? "rapid_trigger_panel_stub" : "rapid_multi_trigger_panel_stub", "layout", LAUNCHER);
        if (layout == 0)
            return null;
        // Into RecentsActivity's drag layer (RecentsDragLayer, set up in onCreate), behind the recents view - where
        // Launcher keeps its panel stub. android.R.id.content isn't found from here (findViewById returned null).
        ViewGroup dragLayer = (ViewGroup) XposedHelpers.callMethod(a, "getDragLayer");
        if (dragLayer == null)
            return null;
        View panel = LayoutInflater.from(a).inflate(layout, dragLayer, false);
        dragLayer.addView(panel, 0, new ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        panels.put(a, panel);
        XposedBridge.log(TAG + ": trigger panel " + panel.getClass().getSimpleName() + " in " + a.getClass().getSimpleName());
        return panel;
    }

    /** The "..." menu's PowOS item: right after OnePlus' Floating window (list position 1). */
    private static final int DESKTOP_AT = 2;
    private static final String POWOS = "com.powos.app";
    private static final String CAPTION_MENU = "com.powos.app.action.CAPTION_MENU";
    /** Menu -> the "Desktop window" item it holds now. */
    private static final Map<Object, Object> desktopItems = new WeakHashMap<>();
    /** Menu -> the item taken out of its list for the length of one click (OnePlus' handler counts positions). */
    private static final Map<Object, Object> lifted = new WeakHashMap<>();

    /**
     * SystemUI: the "..." app handle menu on a full-screen app (OnePlus' FullscreenCaptionHandleMenu, OxygenOS 16) gets a
     * "Desktop window" item next to OnePlus' own "Floating window" (D1, the user 2026-10-31: "we were supposed to add a
     * desk.window option in addition to like the floating window thing"). Its items are built in code
     * (initPopupListWindow: Split View, Floating window, Close, [inner split]) - no resource can add one - and its click
     * handler (lambda$initPopupListWindow$3) dispatches by position, so: after initPopupListWindow our item goes in at
     * [DESKTOP_AT] and the list is handed to the popup again; a click on it tells PowOS (an explicit broadcast, which
     * PowOS takes only from a STATUS_BAR_SERVICE holder) and closes the menu; a click below it is passed on with our item
     * out of the list for that call, so OnePlus' positions hold. A click on Floating window also tells PowOS, so that
     * task stays a native floating window. Guarded: a SystemUI update that renames any of this leaves OnePlus' menu as is.
     *
     * HACK: every hook point here is OxygenOS 16 SystemUI internals, checked against the phone's SystemUI.apk
     * 2026-10-31 (FullscreenCaptionHandleMenu.mPopupListItems/mPopupWindow/mTaskId/mContext, initPopupListWindow,
     * lambda$initPopupListWindow$3(AdapterView, View, int, long), COUI PopupListItem$Builder). Why: OnePlus' menu has no
     * extension point (items built in code, clicks by position). Real fix: AOSP desktop mode's app handle menu
     * (WM Shell HandleMenu) with a PowOS desktop task repository / DesktopModeTransitionSource for "Desktop window",
     * once OxygenOS ships WM Shell's desktop windowing on the Open - then this hook goes.
     */
    private static final String CAPTION_MENU_CLASS = "com.android.wm.shell.fullscreen.FullscreenCaptionHandleMenu";
    private static volatile boolean desktopWindowHooked;

    /**
     * HACK: Vector (v2.2, OxygenOS 16) calls handleLoadPackage for com.android.systemui twice: on the main thread with
     * SystemUI.apk's loader (the hooks go in there), then from another thread with an empty PathClassLoader (no dex
     * path) - that second call logged the ClassNotFoundException for FullscreenCaptionHandleMenu (2026-10-31). So: once
     * hooked, later calls are no-ops; a loader without the class waits for SystemUI's Application.attach and tries its
     * loaders. Real fix: none needed once the hook goes (see [desktopWindowItem]); for a module, the libxposed API's
     * onPackageLoaded with the package's final loader.
     */
    private static void desktopWindowItemWhenLoaded(ClassLoader cl) {
        if (desktopWindowHooked)
            return;
        if (has(cl, CAPTION_MENU_CLASS)) {
            desktopWindowItem(cl, "handleLoadPackage");
            return;
        }
        XposedBridge.log(TAG + ": desktopWindowItem: " + CAPTION_MENU_CLASS + " not in " + cl + ", waiting for Application.attach");
        try {
            XposedHelpers.findAndHookMethod(android.app.Application.class, "attach", android.content.Context.class, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (desktopWindowHooked)
                        return;
                    android.app.Application app = (android.app.Application) param.thisObject;
                    ClassLoader[] loaders = {app.getClass().getClassLoader(), app.getClassLoader(),
                            Thread.currentThread().getContextClassLoader()};
                    for (ClassLoader l : loaders)
                        if (has(l, CAPTION_MENU_CLASS)) {
                            desktopWindowItem(l, "Application.attach " + app.getClass().getName());
                            return;
                        }
                    XposedBridge.log(TAG + ": desktopWindowItem: " + CAPTION_MENU_CLASS + " in no loader at Application.attach ("
                            + app.getClass().getName() + "); menu left as is");
                }
            });
        } catch (Throwable t) {
            log("desktopWindowItem attach", t);
        }
    }

    private static boolean has(ClassLoader cl, String name) {
        if (cl == null)
            return false;
        try {
            Class.forName(name, false, cl);
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    private static synchronized void desktopWindowItem(ClassLoader cl, String via) {
        if (desktopWindowHooked)
            return;
        splitDividerMenu(cl, via);
        try {
            Class<?> menu = XposedHelpers.findClass(CAPTION_MENU_CLASS, cl);
            Class<?> builder = XposedHelpers.findClass("com.coui.appcompat.poplist.PopupListItem$Builder", cl);
            XposedHelpers.findAndHookMethod(menu, "initPopupListWindow", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        Object self = param.thisObject;
                        @SuppressWarnings("unchecked")
                        java.util.List<Object> items = (java.util.List<Object>) XposedHelpers.getObjectField(self, "mPopupListItems");
                        Object window = XposedHelpers.getObjectField(self, "mPopupWindow");
                        if (items == null || window == null || items.size() < DESKTOP_AT)
                            return;
                        android.content.Context ctx = (android.content.Context) XposedHelpers.getObjectField(self, "mContext");
                        Object b = XposedHelpers.newInstance(builder);
                        XposedHelpers.callMethod(b, "reset");
                        int icon = ctx.getResources().getIdentifier("desktop_mode_ic_handle_menu_desktop", "drawable", ctx.getPackageName());
                        if (icon == 0)
                            icon = ctx.getResources().getIdentifier("fullscreen_caption_handle_menu_icon_freeform", "drawable", ctx.getPackageName());
                        if (icon != 0)
                            XposedHelpers.callMethod(b, "setIcon", ctx.getDrawable(icon));
                        XposedHelpers.callMethod(b, "setTitle", "Desktop window");
                        XposedHelpers.callMethod(b, "setIsEnable", true);
                        XposedHelpers.callMethod(b, "setGroupId", XposedHelpers.getIntField(items.get(0), "mGroupId"));
                        Object item = XposedHelpers.callMethod(b, "build");
                        // HACK: position 2 = after OnePlus' Floating window (Split View, Floating window, Close, ...);
                        // real fix: the AOSP handle menu's own desktop item (see desktopWindowItem).
                        items.add(DESKTOP_AT, item);
                        synchronized (desktopItems) {
                            desktopItems.put(self, item);
                        }
                        XposedHelpers.callMethod(window, "setItemList", items);
                    } catch (Throwable t) {
                        log("desktopWindowItem add", t);
                    }
                }
            });
            XposedBridge.hookAllMethods(menu, "lambda$initPopupListWindow$3", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    try {
                        if (param.args.length < 3 || !(param.args[2] instanceof Integer))
                            return;
                        Object self = param.thisObject;
                        Object item;
                        synchronized (desktopItems) {
                            item = desktopItems.get(self);
                        }
                        if (item == null)
                            return;
                        @SuppressWarnings("unchecked")
                        java.util.List<Object> items = (java.util.List<Object>) XposedHelpers.getObjectField(self, "mPopupListItems");
                        int at = items.indexOf(item);
                        int pos = (Integer) param.args[2];
                        int task = XposedHelpers.getIntField(self, "mTaskId");
                        if (at < 0)
                            return;
                        if (pos == at) {
                            tell(self, task, "desktop");
                            XposedHelpers.callMethod(self, "close");
                            param.setResult(null);
                            return;
                        }
                        if (pos == 1)
                            tell(self, task, "float");
                        // HACK: OnePlus' click handler indexes its list by position, so our item is lifted out for
                        // the length of the call; real fix: no position dispatch (the AOSP handle menu has ids).
                        if (pos > at) {
                            items.remove(at);
                            synchronized (lifted) {
                                lifted.put(self, item);
                            }
                            param.args[2] = pos - 1;
                        }
                    } catch (Throwable t) {
                        log("desktopWindowItem click", t);
                    }
                }

                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    Object item;
                    synchronized (lifted) {
                        item = lifted.remove(param.thisObject);
                    }
                    if (item == null)
                        return;
                    try {
                        @SuppressWarnings("unchecked")
                        java.util.List<Object> items = (java.util.List<Object>) XposedHelpers.getObjectField(param.thisObject, "mPopupListItems");
                        items.add(Math.min(DESKTOP_AT, items.size()), item);
                    } catch (Throwable t) {
                        log("desktopWindowItem restore", t);
                    }
                }
            });
            desktopWindowHooked = true;
            XposedBridge.log(TAG + ": desktopWindowItem: hooks installed on " + CAPTION_MENU_CLASS + " (via " + via + ")");
        } catch (Throwable t) {
            log("desktopWindowItem", t);
        }
    }

    /** PowOS told: the "..." menu's [item] picked for [task] (an explicit broadcast to the PowOS app, current user). */
    private static void tell(Object menu, int task, String item) {
        try {
            android.content.Context ctx = (android.content.Context) XposedHelpers.getObjectField(menu, "mContext");
            android.content.Intent i = new android.content.Intent(CAPTION_MENU).setPackage(POWOS).putExtra("task", task).putExtra("item", item);
            Object current = XposedHelpers.getStaticObjectField(android.os.UserHandle.class, "CURRENT");
            XposedHelpers.callMethod(ctx, "sendBroadcastAsUser", i, current);
        } catch (Throwable t) {
            log("desktopWindowItem tell", t);
        }
    }

    private static final String DIVIDER_TAP = "com.android.wm.shell.common.split.DividerView$DoubleTapListener";
    private static final String DIVIDER_MENU_ADAPTER = "com.oplus.splitscreen.DividerMenuAdapter";
    /** Side by side, Top and bottom: in front of OnePlus' own items (Swap, [Save split combination]). */
    private static final int ORIENTATION_ITEMS = 2;
    private static volatile boolean splitMenuHooked;
    /** The user's pick from the divider menu: true side by side, false top/bottom; null = WM Shell's own rule. */
    private static volatile Boolean leftRight;
    /** The SplitLayout whose divider was tapped last (the menu that's open is its). */
    private static volatile java.lang.ref.WeakReference<Object> tappedLayout = new java.lang.ref.WeakReference<>(null);
    /** The open menu has our two orientation items at the top (only on a large screen). */
    private static volatile boolean orientationItemsShown;

    /**
     * SystemUI: a tap on the split divider's handle opens a menu - Side by side / Top and bottom / Swap (+ OnePlus' Save
     * split combination), task split-screen-side-by-side-left-right-on-the-unfo, the user 2026-10-29. Double tap still
     * swaps (AOSP), drag still resizes.
     *
     * OnePlus' SystemUI has the menu already but nothing opens it: StageCoordinatorExt.showDividerMenu() (com.oplus.
     * splitscreen.DividerMenu, a COUI popup at the divider: Swap / Save split combination / orientation toggle) has no
     * caller in OxygenOS 16's SystemUI.apk (dexdump, 2026-11-01). And its orientation toggle can't work here: it flips
     * DividerOrientation.sForceOrientation, which WM Shell's SplitLayout never reads - SplitLayout takes left/right from
     * SplitScreenUtils.isLeftRightSplit(allowLeftRightSplitInPortrait, configuration) only. So:
     *  1. the divider's single tap (its GestureDetector listener, DividerView$DoubleTapListener, has no
     *     onSingleTapConfirmed of its own) shows OnePlus' menu;
     *  2. its item list gets Side by side / Top and bottom first (on a large screen - the unfolded inner one; the cover
     *     screen keeps WM Shell's top/bottom and OnePlus' items only), OnePlus' broken toggle is dropped, Swap and Save
     *     stay OnePlus' own (their click positions shifted back by two);
     *  3. a pick is the layout rule: isLeftRightSplit gives it on a large screen from then on (this SystemUI run), and the
     *     split relayouts at once the way WM Shell does on a root task config change (StageCoordinator.onTaskInfoChanged:
     *     SplitLayout.updateConfiguration, update, onLayoutSizeChanged), on the shell main thread.
     * Default stays the framework overlay's config_leftRightSplitInPortrait (side by side unfolded).
     *
     * HACK: OxygenOS 16 SystemUI internals, checked against the phone's SystemUI.apk 2026-11-01 (DividerView.mSplitLayout,
     * SplitLayout.mSplitLayoutHandler/mOrientation/mIsLargeScreen, StageCoordinator.getExtImpl/mRootTaskInfo/
     * mMainExecutor/onTaskInfoChanged, StageCoordinatorExt.mDividerMenu/showDividerMenu, DividerMenuAdapter.mItemList/
     * mContext, DividerMenu$$ExternalSyntheticLambda1.onItemClick by position, COUI PopupListItem(int, String, boolean)).
     * Why: OnePlus' menu has no opener and its orientation toggle doesn't reach WM Shell's layout; no resource can add
     * either. Real fix: WM Shell's own split orientation API (none in AOSP yet) or OnePlus wiring DividerOrientation into
     * SplitScreenUtils.isLeftRightSplit and the divider tap to showDividerMenu - then this hook goes.
     */
    private static void splitDividerMenu(ClassLoader cl, String via) {
        if (splitMenuHooked)
            return;
        try {
            Class<?> utils = XposedHelpers.findClass("com.android.wm.shell.common.split.SplitScreenUtils", cl);
            Class<?> popupItem = XposedHelpers.findClass("com.coui.appcompat.poplist.PopupListItem", cl);
            XposedHelpers.findAndHookMethod(utils, "isLeftRightSplit", boolean.class, android.content.res.Configuration.class, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    Boolean lr = leftRight;
                    android.content.res.Configuration c = (android.content.res.Configuration) param.args[1];
                    if (lr != null && c != null && c.smallestScreenWidthDp >= 600)
                        param.setResult(lr);
                }
            });
            XposedHelpers.findAndHookMethod(android.view.GestureDetector.SimpleOnGestureListener.class, "onSingleTapConfirmed",
                    android.view.MotionEvent.class, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    if (!DIVIDER_TAP.equals(param.thisObject.getClass().getName()))
                        return;
                    try {
                        Object view = XposedHelpers.getObjectField(param.thisObject, "this$0");
                        Object layout = XposedHelpers.getObjectField(view, "mSplitLayout");
                        if (layout == null)
                            return;
                        Object ext = XposedHelpers.callMethod(XposedHelpers.getObjectField(layout, "mSplitLayoutHandler"), "getExtImpl");
                        if (XposedHelpers.getObjectField(ext, "mDividerMenu") == null)
                            return;
                        tappedLayout = new java.lang.ref.WeakReference<>(layout);
                        XposedHelpers.callMethod(ext, "showDividerMenu");
                        param.setResult(true);
                    } catch (Throwable t) {
                        log("splitDividerMenu tap", t);
                    }
                }
            });
            XposedHelpers.findAndHookMethod("com.oplus.splitscreen.DividerMenuPopupListWindow", cl, "setAdapter",
                    android.widget.BaseAdapter.class, new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    orientationItemsShown = false;
                    Object adapter = param.args[0];
                    Object layout = tappedLayout.get();
                    if (adapter == null || layout == null || !DIVIDER_MENU_ADAPTER.equals(adapter.getClass().getName()))
                        return;
                    try {
                        if (!XposedHelpers.getBooleanField(layout, "mIsLargeScreen"))
                            return;
                        @SuppressWarnings("unchecked")
                        java.util.List<Object> items = (java.util.List<Object>) XposedHelpers.getObjectField(adapter, "mItemList");
                        android.content.Context ctx = (android.content.Context) XposedHelpers.getObjectField(adapter, "mContext");
                        boolean lr = (Boolean) XposedHelpers.callMethod(layout, "isLeftRightSplit");
                        boolean pair = XposedHelpers.getBooleanField(
                                XposedHelpers.callStaticMethod(XposedHelpers.findClass("com.oplus.splitscreen.SplitToggleHelper", cl), "getInstance"),
                                "mHasSplitPairFeature");
                        java.util.List<Object> mine = new java.util.ArrayList<>();
                        // The current arrangement greyed out, the other one offered.
                        mine.add(XposedHelpers.newInstance(popupItem, drawable(ctx, "split_screen_switch_orientation_vertical"), "Side by side", !lr));
                        mine.add(XposedHelpers.newInstance(popupItem, drawable(ctx, "split_screen_switch_orientation_horizontal"), "Top and bottom", lr));
                        // OnePlus' own: Swap at 0, Save split combination at 1 when the feature is on (its orientation
                        // toggle after them is dropped - see splitDividerMenu).
                        mine.addAll(items.subList(0, Math.min(items.size(), pair ? 2 : 1)));
                        XposedHelpers.setObjectField(adapter, "mItemList", mine);
                        orientationItemsShown = true;
                    } catch (Throwable t) {
                        log("splitDividerMenu items", t);
                    }
                }
            });
            XposedBridge.hookAllMethods(XposedHelpers.findClass("com.oplus.splitscreen.DividerMenu$$ExternalSyntheticLambda1", cl), "onItemClick", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (!orientationItemsShown || param.args.length < 3 || !(param.args[2] instanceof Integer))
                        return;
                    try {
                        int pos = (Integer) param.args[2];
                        if (pos >= ORIENTATION_ITEMS) {
                            // HACK: OnePlus' handler dispatches by position (0 Swap, 1 Save); ours sit in front.
                            param.args[2] = pos - ORIENTATION_ITEMS;
                            return;
                        }
                        Object layout = tappedLayout.get();
                        if (layout != null)
                            arrange(layout, pos == 0);
                        XposedHelpers.callMethod(XposedHelpers.getObjectField(param.thisObject, "f$0"), "hideMenuIfNeed");
                        param.setResult(null);
                    } catch (Throwable t) {
                        log("splitDividerMenu click", t);
                    }
                }
            });
            splitMenuHooked = true;
            XposedBridge.log(TAG + ": splitDividerMenu: hooks installed (via " + via + ")");
        } catch (Throwable t) {
            log("splitDividerMenu", t);
        }
    }

    private static int drawable(android.content.Context ctx, String name) {
        return ctx.getResources().getIdentifier(name, "drawable", ctx.getPackageName());
    }

    /** Split side by side ([leftRight]) or top/bottom now, and from then on (the isLeftRightSplit hook). */
    private static void arrange(Object layout, boolean lr) {
        leftRight = lr;
        Object coordinator = XposedHelpers.getObjectField(layout, "mSplitLayoutHandler");
        Runnable relayout = () -> {
            try {
                Object root = XposedHelpers.getObjectField(coordinator, "mRootTaskInfo");
                if (root == null || (Boolean) XposedHelpers.callMethod(layout, "isLeftRightSplit") == lr)
                    return;
                // updateConfiguration returns early when orientation/rotation/density/bounds are unchanged - they are;
                // an orientation it never had makes it recompute (isLeftRightSplit included), as on a real change.
                XposedHelpers.setIntField(layout, "mOrientation", -1);
                XposedHelpers.callMethod(coordinator, "onTaskInfoChanged", root);
                XposedBridge.log(TAG + ": splitDividerMenu: " + (lr ? "side by side" : "top and bottom"));
            } catch (Throwable t) {
                log("splitDividerMenu arrange", t);
            }
        };
        XposedHelpers.callMethod(XposedHelpers.getObjectField(coordinator, "mMainExecutor"), "execute", relayout);
    }

    /**
     * The vendor's thermal table for a PowOS game (scope com.oplus.battery). OxygenOS' skin-temperature controller
     * (com.oplus.battery's ThermalControllHandler, applied by horae) picks its table by the front package's appType:
     * com.powos.app is -1, "common_config", which caps the big cores from gear 3 (35 C); a game is 4, category_4, full
     * clocks to gear 5. While game-boost.sh holds a boost it sets Settings.Global powos_game_front; only then, and only
     * for com.powos.app, the appType lookup answers 4. Home and every other app keep the vendor's own answer.
     *
     * HACK: the lookup is ThermalControlUtils' one (String)int method (obfuscated "G": the app_type config, else
     * StateManager -> DeepThinker / OifaceManager's game list); found by that signature, so a rename only logs. It is
     * not done through the game list itself because StateManager caches a positive appType until the package is
     * uninstalled - every later PowOS use would stay on the game table. The table switches on the controller's next
     * evaluation (a temperature gear change or a front app change). Real fix: a vendor API that classes a running
     * game per window/process, then drop this hook and game-boost.sh's marker.
     */
    private static void gameClassWhileBoosted(ClassLoader cl) {
        try {
            Class<?> utils = XposedHelpers.findClass("com.oplus.thermalcontrol.ThermalControlUtils", cl);
            java.lang.reflect.Method lookup = null;
            for (java.lang.reflect.Method m : utils.getDeclaredMethods()) {
                Class<?>[] p = m.getParameterTypes();
                if (m.getReturnType() == int.class && p.length == 1 && p[0] == String.class) {
                    if (lookup != null) {
                        XposedBridge.log(TAG + ": gameClass: two (String)int methods in ThermalControlUtils, not hooked");
                        return;
                    }
                    lookup = m;
                }
            }
            if (lookup == null) {
                XposedBridge.log(TAG + ": gameClass: no (String)int method in ThermalControlUtils");
                return;
            }
            XposedBridge.hookMethod(lookup, new XC_MethodHook() {
                private String last = "";

                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        if (!POWOS.equals(param.args[0]) || !(param.getResult() instanceof Integer))
                            return;
                        android.app.Application app = android.app.AndroidAppHelper.currentApplication();
                        String game = app == null ? null
                            : android.provider.Settings.Global.getString(app.getContentResolver(), VENDOR_GAME_KEY);
                        boolean on = game != null && !game.isEmpty() && (Integer) param.getResult() <= 0;
                        if (on)
                            param.setResult(APP_TYPE_GAME);
                        String now = on ? game : "";
                        if (!now.equals(last)) {
                            last = now;
                            XposedBridge.log(TAG + ": gameClass: " + POWOS + " appType "
                                + (on ? APP_TYPE_GAME + " (" + game + " boosted)" : "the vendor's"));
                        }
                    } catch (Throwable t) {
                        log("gameClass", t);
                    }
                }
            });
            XposedBridge.log(TAG + ": gameClass: hooked " + lookup.getName());
            reevaluateOnMarker(cl);
        } catch (Throwable t) {
            log("gameClass", t);
        }
    }

    /**
     * The game table from the tap, not minutes later. The controller picks its table only when it evaluates - a front
     * package change or a temperature gear change - and the front package stays com.powos.app for the whole launch, so
     * the marker going on was not seen until the next gear change: 11-08/11-09 launches ran under common_config's cpu
     * level 4-5 (prime 1.59 / 1.36 GHz of 3.19 on a cool phone) while category_4 allows full clocks to gear 4 and
     * level 1 (prime 1.98) at gears 5-6. Here a ContentObserver on the marker runs the controller's own category
     * evaluation (what its app switch calls: ThermalControlUtils -> controller.q1(), "CategoryChanged") on the
     * controller's thread, both ways: marker on picks category_4, off goes back to common_config (through the vendor's
     * own protect period). Temperature still sets the gear and the gear the cap: a hot phone stays capped by the
     * vendor's game table.
     *
     * HACK: com.oplus.thermalcontrol.m / q1 are obfuscated names in CPH2551_16.0.5.1301's Battery.apk (jadx 11-09); a
     * rename only logs and leaves the old next-gear behaviour. Real fix: a vendor API that classes a running game per
     * window/process.
     */
    private static void reevaluateOnMarker(ClassLoader cl) {
        final Class<?> controller;
        final java.lang.reflect.Method getter;
        final java.lang.reflect.Method evaluate;
        try {
            controller = XposedHelpers.findClass("com.oplus.thermalcontrol.m", cl);
            java.lang.reflect.Method g = null;
            for (java.lang.reflect.Method m : controller.getDeclaredMethods()) {
                Class<?>[] p = m.getParameterTypes();
                if (java.lang.reflect.Modifier.isStatic(m.getModifiers()) && m.getReturnType() == controller
                    && p.length == 1 && p[0] == android.content.Context.class)
                    g = m;
            }
            java.lang.reflect.Method e = controller.getDeclaredMethod("q1");
            if (g == null || e.getReturnType() != void.class) {
                XposedBridge.log(TAG + ": gameClass: no controller getter / q1(), the table switches on the next gear");
                return;
            }
            g.setAccessible(true);
            e.setAccessible(true);
            getter = g;
            evaluate = e;
        } catch (Throwable t) {
            log("gameClass reevaluate (the table switches on the next gear)", t);
            return;
        }
        XposedHelpers.findAndHookMethod(android.app.Application.class, "attach", android.content.Context.class, new XC_MethodHook() {
            private boolean done;

            @Override
            protected void afterHookedMethod(MethodHookParam param) {
                if (done)
                    return;
                done = true;
                try {
                    // The base context attach() was given: getApplicationContext() is still null here (LoadedApk has not stored the
                    // Application yet) - 11-09 on the OnePlus: "gameClass observer: NullPointerException ... ContentResolver".
                    final android.content.Context ctx = (android.content.Context) param.args[0];
                    ctx.getContentResolver().registerContentObserver(
                        android.provider.Settings.Global.getUriFor(VENDOR_GAME_KEY), false,
                        new android.database.ContentObserver(new android.os.Handler(android.os.Looper.getMainLooper())) {
                            @Override
                            public void onChange(boolean self) {
                                reevaluate(ctx, controller, getter, evaluate);
                            }
                        });
                    XposedBridge.log(TAG + ": gameClass: the category is evaluated on every " + VENDOR_GAME_KEY + " change");
                } catch (Throwable t) {
                    log("gameClass observer", t);
                }
            }
        });
    }

    private static void reevaluate(android.content.Context ctx, Class<?> controller, java.lang.reflect.Method getter,
                                   java.lang.reflect.Method evaluate) {
        try {
            final Object c = getter.invoke(null, ctx);
            // On the controller's own thread (its Handler field), where its messages run.
            android.os.Handler h = null;
            for (java.lang.reflect.Field f : controller.getDeclaredFields()) {
                if (h == null && android.os.Handler.class.isAssignableFrom(f.getType())
                    && !java.lang.reflect.Modifier.isStatic(f.getModifiers())) {
                    f.setAccessible(true);
                    h = (android.os.Handler) f.get(c);
                }
            }
            Runnable run = () -> {
                try {
                    evaluate.invoke(c);
                } catch (Throwable t) {
                    log("gameClass reevaluate", t);
                }
            };
            if (h == null || !h.post(run))
                run.run();
            String game = android.provider.Settings.Global.getString(ctx.getContentResolver(), VENDOR_GAME_KEY);
            XposedBridge.log(TAG + ": gameClass: marker " + (game == null ? "off" : game) + ", category evaluated now");
        } catch (Throwable t) {
            log("gameClass reevaluate", t);
        }
    }

    /**
     * The split-screen divider drag. The user, 2026-10-30: "it turns white while im dragging the splitscreen handle".
     * While the divider moves, WM Shell's SplitDecorManager.onResizing (StageTaskListener.onResizing, from
     * ResizingEffectPolicy.applyDividerPosition) covers each app whose size changes with a veil: a colour layer
     * ("ResizingBackground", plus "GapBackground" where the stage outgrows its old bounds) filled with
     * getResizingBackgroundColor(task) = the task's TaskDescription background colour, white for most apps, and the
     * app's icon on top. Same in drawNextVeilFrameForSwapAnimation (the swap). OnePlus's SplitDecorManagerExt
     * (a Gaussian-blurred screenshot veil) is on this build but nothing calls its veil path.
     *
     * Signatures from this phone's SystemUI.apk (CPH2551_16.0.5.1301, classes2.dex, dexdump 2026-10-30):
     *   private static float[] getResizingBackgroundColor(ActivityManager.RunningTaskInfo)
     *   public void onResizing(RunningTaskInfo, Rect, Rect, Rect, SurfaceControl.Transaction, int, int, boolean)
     *   public void drawNextVeilFrameForSwapAnimation(RunningTaskInfo, Rect, SurfaceControl.Transaction, boolean,
     *       SurfaceControl, float, float)
     *   fields mBackgroundLeash, mGapBackgroundLeash (SurfaceControl)
     *
     * The veil stays (the apps can't relayout every frame, without it they'd show stretched or cut off) but in PowOS's
     * dark tone. getResizingBackgroundColor is a 19-unit private static method that ART may inline into its callers
     * (as it did with updateOverviewTargets above), so the layers are also recoloured in the same transaction after
     * onResizing / drawNextVeilFrameForSwapAnimation: the later setColor wins whichever hook ran.
     *
     * HACK: a hook in SystemUI, because OxygenOS gives no setting or resource for the veil colour (it is the app's
     * TaskDescription colour). Real fix: PowOS's own split (WM Shell) veil, or a snapshot veil, once PowOS owns that.
     */
    private static final float[] VEIL_RGBA = {0x0f / 255f, 0x11 / 255f, 0x15 / 255f, 1f}; // #0f1115, PowOS's --bg
    private static volatile boolean veilLogged;

    private static final String SPLIT_DECOR = "com.android.wm.shell.common.split.SplitDecorManager";
    private static volatile boolean veilHooked;

    /** Once, from the loader that has WM Shell (Vector's second SystemUI call has an empty loader; see desktopWindowItemWhenLoaded). */
    private static synchronized void darkSplitVeilWhenLoaded(ClassLoader cl) {
        if (veilHooked || !has(cl, SPLIT_DECOR))
            return;
        veilHooked = true;
        darkSplitVeil(cl);
    }

    private static void darkSplitVeil(ClassLoader cl) {
        try {
            Class<?> decor = XposedHelpers.findClass("com.android.wm.shell.common.split.SplitDecorManager", cl);
            XposedHelpers.findAndHookMethod(decor, "getResizingBackgroundColor",
                android.app.ActivityManager.RunningTaskInfo.class, new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        param.setResult(VEIL_RGBA.clone());
                    }
                });
            XC_MethodHook recolour = new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    try {
                        android.view.SurfaceControl.Transaction t = null;
                        for (Object a : param.args)
                            if (a instanceof android.view.SurfaceControl.Transaction) {
                                t = (android.view.SurfaceControl.Transaction) a;
                                break;
                            }
                        if (t == null)
                            return;
                        boolean any = false;
                        for (String f : new String[] {"mBackgroundLeash", "mGapBackgroundLeash"}) {
                            Object sc = XposedHelpers.getObjectField(param.thisObject, f);
                            if (sc instanceof android.view.SurfaceControl && ((android.view.SurfaceControl) sc).isValid()) {
                                // Transaction.setColor(SurfaceControl, float[]) is @hide; SystemUI may call it.
                                XposedHelpers.callMethod(t, "setColor", sc, VEIL_RGBA.clone());
                                any = true;
                            }
                        }
                        if (any && !veilLogged) {
                            veilLogged = true;
                            android.util.Log.i(TAG, "split veil: dark #0f1115 (" + param.method.getName() + ")");
                        }
                    } catch (Throwable t) {
                        log("darkSplitVeil " + param.method.getName(), t);
                    }
                }
            };
            int n = XposedBridge.hookAllMethods(decor, "onResizing", recolour).size()
                + XposedBridge.hookAllMethods(decor, "drawNextVeilFrameForSwapAnimation", recolour).size();
            android.util.Log.i(TAG, "split veil hooks installed in SystemUI (" + (n + 1) + " methods)");
        } catch (Throwable t) {
            log("darkSplitVeil", t);
            android.util.Log.w(TAG, "split veil hooks not installed: " + t);
        }
    }

    private static void log(String what, Throwable t) {
        XposedBridge.log(TAG + ": " + what + ": " + t);
    }
}

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

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lp) {
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
                        if (e.getActionMasked() == android.view.MotionEvent.ACTION_DOWN || !downX.containsKey(self))
                            downX.put(self, e.getRawX());
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

    private static void log(String what, Throwable t) {
        XposedBridge.log(TAG + ": " + what + ": " + t);
    }
}

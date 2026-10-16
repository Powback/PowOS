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
    }

    private static final ThreadLocal<Boolean> inOverviewTargets = new ThreadLocal<>();

    /**
     * The taskbar / "quick peek" dock: OverviewComponentObserver.updateOverviewTargets() switches OnePlus's own
     * taskbar setting off (Settings.System enable_launcher_taskbar = 0, after backing up the user's value) whenever
     * the default home isn't OnePlus's launcher, and restores it when it is again. Skip exactly those two calls when
     * they come from there; the user's own taskbar switch in Settings keeps working. (Forcing mIsDefaultHome instead
     * would also change the recents/home routing.)
     */
    private static void keepTaskbar(ClassLoader cl) {
        try {
            Class<?> observer = XposedHelpers.findClass("com.android.quickstep.OverviewComponentObserver", cl);
            XposedBridge.hookAllMethods(observer, "updateOverviewTargets", new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    inOverviewTargets.set(true);
                }

                @Override
                protected void afterHookedMethod(MethodHookParam param) {
                    inOverviewTargets.remove();
                }
            });
            Class<?> config = XposedHelpers.findClass("com.android.launcher3.taskbar.TaskbarSettingsConfig", cl);
            XC_MethodHook skipFromObserver = new XC_MethodHook() {
                @Override
                protected void beforeHookedMethod(MethodHookParam param) {
                    if (!Boolean.TRUE.equals(inOverviewTargets.get()))
                        return;
                    if (param.args.length == 0 || Boolean.FALSE.equals(param.args[0]))
                        param.setResult(null); // backupTaskbarSettingEnable() / setTaskbarSettingEnable(false)
                }
            };
            XposedBridge.hookAllMethods(config, "setTaskbarSettingEnable", skipFromObserver);
            XposedBridge.hookAllMethods(config, "backupTaskbarSettingEnable", skipFromObserver);
        } catch (Throwable t) {
            log("keepTaskbar", t);
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
                        XposedHelpers.callMethod(param.args[0], "setShow");
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
        ViewGroup content = a.findViewById(android.R.id.content);
        View panel = LayoutInflater.from(a).inflate(layout, content, false);
        content.addView(panel);
        panels.put(a, panel);
        return panel;
    }

    private static void log(String what, Throwable t) {
        XposedBridge.log(TAG + ": " + what + ": " + t);
    }
}

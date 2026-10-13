package andro.marchy;

import android.content.Context;
import android.content.pm.PackageInfo;

/**
 * PowOS: the engine is a library inside the PowOS app, and a library's BuildConfig has no
 * APPLICATION_ID / VERSION_NAME / VERSION_CODE. Read them from the installed app instead.
 */
final class AppVersion {
    private AppVersion() {}

    static String name(Context ctx) {
        PackageInfo p = info(ctx);
        return p != null && p.versionName != null ? p.versionName : "?";
    }

    static long code(Context ctx) {
        PackageInfo p = info(ctx);
        return p != null ? p.getLongVersionCode() : 0;
    }

    private static PackageInfo info(Context ctx) {
        try {
            return ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0);
        } catch (Exception e) {
            return null;
        }
    }
}

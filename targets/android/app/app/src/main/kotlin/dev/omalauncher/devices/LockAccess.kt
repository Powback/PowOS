package dev.omalauncher.devices

import android.app.Activity
import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import dev.omalauncher.R
import dev.omalauncher.linux.RootedGuest
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArraySet

/**
 * The no-root phone's lock, the Android-sanctioned way: a device admin (PowosLockAdmin) holding ONLY the force-lock
 * policy (res/xml/powos_lock_admin.xml), so DevicePolicyManager.lockNow() locks the screen. Never taken silently: the
 * person turns it on from the Devices app (its explanation sheet, then Android's own "Activate device admin app?"
 * screen) and off there or in Settings > Security > Device admin apps; the device agent advertises lock/screen_off
 * only while it is on (LockActions), read live on every request.
 *
 * Shell bridge calls (ShellBridge.kt): devices.lock (state), devices.lockAllow (Android's screen), devices.lockStop;
 * "devices.lock" events on every change (the receiver's onEnabled/onDisabled, whoever made it).
 */
object LockAccess {
    private const val TAG = "PowosLock"

    /** Every page's "devices.lock" event: the new state ([state]), from the receiver's callbacks. */
    val listeners = CopyOnWriteArraySet<(JSONObject) -> Unit>()

    private fun admin(ctx: Context) = ComponentName(ctx, PowosLockAdmin::class.java)

    private fun dpm(ctx: Context) = ctx.getSystemService(DevicePolicyManager::class.java)

    fun allowed(ctx: Context): Boolean = runCatching { dpm(ctx)?.isAdminActive(admin(ctx)) == true }.getOrDefault(false)

    fun locker(ctx: Context): Locker =
        object : Locker {
            override fun allowed() = allowed(ctx)

            override fun lock() {
                runCatching { dpm(ctx).lockNow() }.onFailure {
                    Log.w(TAG, "lockNow failed", it)
                    throw DeviceActionError("lock: Android refused (${it.message})", "failed")
                }
            }
        }

    /**
     * What the Devices app shows for this phone: [available] (the no-root agent serves it: a rooted phone's powos-deviced
     * locks through the system tier instead, so nothing to ask there), [allowed] (the admin is active).
     */
    fun state(ctx: Context): JSONObject =
        JSONObject()
            .put("available", !RootedGuest.enabled && dpm(ctx) != null)
            .put("rooted", RootedGuest.enabled)
            .put("allowed", allowed(ctx))

    /**
     * Android's own consent screen for the lock admin (the person taps Activate there, or doesn't). The answer arrives as
     * a "devices.lock" event (PowosLockAdmin.onEnabled); returns the state now, before they answered.
     */
    fun ask(ctx: Context): JSONObject {
        if (!allowed(ctx)) {
            val i =
                Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                    .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, admin(ctx))
                    .putExtra(DevicePolicyManager.EXTRA_ADD_EXPLANATION, ctx.getString(R.string.lock_admin_description))
            if (ctx !is Activity) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(i)
        }
        return state(ctx)
    }

    /** Off from the Devices app: the app gives up its own admin (no Android screen needed for that). */
    fun stop(ctx: Context): JSONObject {
        if (allowed(ctx)) dpm(ctx).removeActiveAdmin(admin(ctx))
        // removeActiveAdmin is asynchronous: say "off" now (onDisabled confirms it with another event).
        return state(ctx).put("allowed", false)
    }

    internal fun changed(
        ctx: Context,
        allowed: Boolean,
    ) {
        Log.i(TAG, "lock from other devices ${if (allowed) "allowed" else "turned off"}")
        val s = state(ctx).put("allowed", allowed)
        listeners.forEach { runCatching { it(s) } }
    }
}

/** Android tells PowOS the person turned the lock admin on or off (Devices app, Settings, or uninstall's prompt). */
class PowosLockAdmin : DeviceAdminReceiver() {
    override fun onEnabled(
        context: Context,
        intent: Intent,
    ) = LockAccess.changed(context, true)

    override fun onDisabled(
        context: Context,
        intent: Intent,
    ) = LockAccess.changed(context, false)
}

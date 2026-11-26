package dev.omalauncher.system

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager

/**
 * The phone permission the status bar's SIM icons need (READ_PHONE_STATE: the second SIM, 5G / LTE+, the carrier's
 * "4G"), asked the PowOS way: explicitly, once. Rooted, [StatusSignals] grants it itself and this never asks. Not
 * rooted, home asks the first time it comes up while PowOS draws the status bar ([ShadeHost] running); a "no" is kept
 * (never asked again) and the bar shows what it can without it (the first SIM's bars and radio type).
 */
object StatusPermission {
    const val REQUEST = 44
    private const val PREFS = "status-permission"
    private const val ASKED = "asked-phone-state"

    /** True if it asked now (one permission dialog at a time: home asks nothing else this time). */
    fun askOnce(activity: Activity): Boolean {
        if (ShadeHost.current == null) return false
        if (activity.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED) return false
        if (andro.marchy.RootMode.enabled()) return false
        val prefs = activity.getSharedPreferences(PREFS, Activity.MODE_PRIVATE)
        if (prefs.getBoolean(ASKED, false)) return false
        prefs.edit().putBoolean(ASKED, true).apply()
        activity.requestPermissions(arrayOf(Manifest.permission.READ_PHONE_STATE), REQUEST)
        return true
    }

    /** The answer ([Activity.onRequestPermissionsResult]): granted, the bar reads the SIMs again. */
    fun answered(granted: Boolean) {
        if (granted) StatusSignals.permissionChanged()
    }
}

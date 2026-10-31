package dev.omalauncher.shell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * The "..." app handle menu's PowOS items, from SystemUI (the PowOS LSPosed module's hook in OnePlus'
 * FullscreenCaptionHandleMenu, targets/android/oplus-hook): [SystemFloat.ACTION] with the task and the item picked.
 * Only SystemUI can send it: the receiver requires STATUS_BAR_SERVICE (signature|privileged, SystemUI holds it).
 */
class CaptionMenuReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action != SystemFloat.ACTION) return
        val task = intent.getIntExtra("task", -1)
        if (task < 0) return
        SystemFloat.captionMenu(task, intent.getStringExtra("item"))
    }
}

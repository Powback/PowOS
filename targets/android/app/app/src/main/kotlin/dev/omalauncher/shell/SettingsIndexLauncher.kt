package dev.omalauncher.shell

import android.content.Intent
import android.os.Bundle
import android.os.Parcel
import android.os.Process
import android.util.Base64

/** Root-mode navigation to an indexed Settings fragment. Carries the nested preference Bundle intact. */
object SettingsIndexLauncher {
    @JvmStatic fun main(args: Array<String>) {
        check(Process.myUid() == 0 && args.size == 1)
        val request = decode(args[0])
        val intent = request.getParcelable<Intent>("intent") ?: error("Missing settings destination")
        check(intent.component?.packageName == "com.android.settings" && intent.component?.className == "com.android.settings.SubSettings")
        check(!intent.getStringExtra(":settings:show_fragment").isNullOrBlank())
        val service = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null)
        val method = Class.forName("android.app.IActivityManager").methods.first { it.name == "startActivityAsUserWithFeature" }
        // Same external caller contract as Android's `am start`; actual Binder identity remains root.
        val result = method.invoke(service, null, "com.android.shell", null, intent, null, null, null, 0, 0, null, request.getBundle("options"), 0) as Int
        check(result >= 0) { "Settings launch failed: $result" }
        println("POWOS_SETTINGS_OPENED=$result")
        kotlin.system.exitProcess(0)
    }

    private fun decode(value: String): Bundle {
        val bytes = Base64.decode(value, Base64.NO_WRAP)
        val parcel = Parcel.obtain()
        return try {
            parcel.unmarshall(bytes, 0, bytes.size)
            parcel.setDataPosition(0)
            parcel.readBundle(Intent::class.java.classLoader) ?: error("Missing settings request")
        } finally { parcel.recycle() }
    }
}

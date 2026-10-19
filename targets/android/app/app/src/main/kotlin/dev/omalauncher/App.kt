package dev.omalauncher

import android.app.Application
import dev.omalauncher.linux.RootedGuest
import java.io.File

class App : Application() {
    val runtime by lazy { Runtime(this) }

    override fun onCreate() {
        super.onCreate()
        // PowOS AI's agents reach the user whenever the app runs (the PowOS session keeps it alive), not only once the
        // launcher has been opened: their notifications with inline replies (AgentMail).
        if (RootedGuest.enabled) {
            AgentMail.start(this, File(filesDir, "run"))
            // Mail for the manager runs its turn in PowOS AI's chat, the user's next message not needed.
            PowosAiChat.startWake(this, File(filesDir, "run"))
        }
    }
}

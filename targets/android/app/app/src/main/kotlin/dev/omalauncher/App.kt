package dev.omalauncher

import android.app.Application
import dev.omalauncher.linux.RootedGuest
import java.io.File

class App : Application() {
    val runtime by lazy { Runtime(this) }

    override fun onCreate() {
        super.onCreate()
        // SystemUI's binding to the recents service (and with it the gesture input) back after the process dies.
        dev.omalauncher.system.RecentsWatchdog.start(this)
        // The smart glasses: reconnect if they were connected when the app last ran; `powos glasses`'s commands. In the
        // main process only (the engine's ":restart" runs this too): one process owns the BLE link.
        if (Application.getProcessName() == packageName) dev.omalauncher.glasses.Glasses.init(this)
        // PowOS AI's agents reach the user whenever the app runs (the PowOS session keeps it alive), not only once the
        // launcher has been opened: their notifications with inline replies (AgentMail).
        if (RootedGuest.enabled) {
            AgentMail.start(this, File(filesDir, "run"))
            // Mail for the manager runs its turn in PowOS AI's chat, the user's next message not needed.
            PowosAiChat.startWake(this, File(filesDir, "run"))
            // Which agents run and what they do (the Agents view): the spool PowOS's agentsd writes, and the notification.
            AgentsSpool.start(this, File(filesDir, "run"))
            // The verify queue's status pill while it tests on the phone (tools/phone/verify/queue.sh).
            dev.omalauncher.shell.VerifyRun.start(this, File(filesDir, "run"))
        }
    }
}

package dev.omalauncher

import android.app.Application
import dev.omalauncher.linux.RootedGuest
import java.io.File

class App : Application() {
    val runtime by lazy { Runtime(this) }

    override fun onCreate() {
        super.onCreate()
        // PowOS windows (KWin's, WindowTasks) float on the unfolded home like Android apps. Set here, before the
        // session's service connects to KWin - set lazily (by Runtime) KWin's "caps" could come first and it was never
        // told to open new windows as tasks.
        if (Application.getProcessName() == packageName) floatingWindows()
        // SystemUI's binding to the recents service (and with it the gesture input) back after the process dies.
        dev.omalauncher.system.RecentsWatchdog.start(this)
        // The smart glasses: reconnect if they were connected when the app last ran; `powos glasses`'s commands. In the
        // main process only (the engine's ":restart" runs this too): one process owns the BLE link.
        if (Application.getProcessName() == packageName) dev.omalauncher.glasses.Glasses.init(this)
        // Which apps run (the dot under their icons): Android's tasks, and the PowOS session's apps where it runs.
        if (Application.getProcessName() == packageName) dev.omalauncher.system.RunningApps.start(this, File(filesDir, "run").takeIf { RootedGuest.enabled })
        // PowOS AI's agents reach the user whenever the app runs (the PowOS session keeps it alive), not only once the
        // launcher has been opened: their notifications with inline replies (AgentMail).
        if (RootedGuest.enabled) {
            AgentMail.start(this, File(filesDir, "run"))
            // Mail for the manager runs its turn in PowOS AI's chat, the user's next message not needed.
            PowosAiChat.startWake(this, File(filesDir, "run"))
            // Which agents run and what they do (the Agents view): the spool PowOS's agentsd writes, and the notification.
            AgentsSpool.start(this, File(filesDir, "run"))
            // The Plasma session's notifications in PowOS's shade and its clipboard both ways (powos-plasma-bridge);
            // the main process only (one reader of its spool; the engine's ":restart" runs this too).
            if (Application.getProcessName() == packageName) {
                PlasmaBridge.start(this, File(filesDir, "run"))
                andro.marchy.PowosWindowActivity.focusHook = Runnable { PlasmaBridge.pushClip(this) }
            }
            // The verify queue's status pill while it tests on the phone (tools/phone/verify/queue.sh).
            dev.omalauncher.shell.VerifyRun.start(this, File(filesDir, "run"))
        }
    }

    private fun floatingWindows() {
        val windows = dev.omalauncher.system.AppWindows
        // The Linux side's "open <package>" (the AI, scripts) and a PowOS window's task: a floating window unfolded.
        andro.marchy.AndroidRequests.openOptions = java.util.function.Function { windows.bundle(it) }
        // A PowOS window's task shown again (the launcher, the dock): to the front, floating if it was full screen.
        andro.marchy.WindowTasks.raiseTask =
            java.util.function.BiPredicate { c, id -> dev.omalauncher.system.Tasks.open(c, id, windows.taskOptions(c, id, android.app.ActivityOptions.makeBasic())) }
        // A floating Linux window's app went full screen by itself (KWin "fullscreen"): its task covers the screen, then floats back.
        andro.marchy.WindowTasks.fullScreenTask =
            java.util.function.BiConsumer { id, on -> dev.omalauncher.system.WindowFrames.current?.appFullScreen(id, on) }
        // A Linux window that draws its own title bar (KWin "decor 0") gets no frame bar; its own bar's drag ("move") moves its task.
        andro.marchy.WindowTasks.barChanged = Runnable { dev.omalauncher.system.WindowFrames.current?.changed() }
        andro.marchy.WindowTasks.moveTask =
            java.util.function.BiPredicate { id, e -> dev.omalauncher.system.WindowFrames.current?.appMove(id, e) ?: false }
        // KWin opens every new application window as a floating task then (WindowTasks "export-new").
        andro.marchy.WindowTasks.setFloating(this, java.util.function.Predicate { windows.floating(it) })
    }
}

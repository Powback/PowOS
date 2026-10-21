package dev.omalauncher.assist

import android.app.assist.AssistStructure
import android.content.Context
import android.graphics.Bitmap
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.view.View
import android.view.ViewGroup
import dev.omalauncher.shell.ShellHost
import org.json.JSONObject
import java.io.File

/**
 * One summoning of PowOS AI over whatever is on screen: the session's window (the system's, over the app) shows the
 * web shell's assist screen (shell/ui/assist.tsx) - a thin host, as every PowOS slot. The system hands over the
 * screen's text ([onHandleAssist]) and a screenshot ([onHandleScreenshot]); the page gets them as "assist.context"
 * (assist.screen: text outline, screenshot URL), asks PowOS AI with them, and closes the session (assist.close).
 */
class PowosAssistSession(
    context: Context,
) : VoiceInteractionSession(context) {
    private var host: ShellHost? = null
    private var screenText = ""
    private var shot: File? = null

    /** Live mode: only the page's bar takes touches (device px); null: the whole window, as when it's a panel. */
    private var touchArea: android.graphics.Rect? = null

    override fun onComputeInsets(outInsets: Insets) {
        super.onComputeInsets(outInsets)
        val area = touchArea ?: return
        outInsets.touchableInsets = Insets.TOUCHABLE_INSETS_REGION
        outInsets.touchableRegion.set(area)
    }

    override fun onCreateContentView(): View {
        // The warm page (AssistWeb): ready before the power button is held, so the panel is there at once.
        val h = AssistWeb.get(context)
        (h.web.parent as? ViewGroup)?.removeView(h.web)
        h.bridge.assist =
            object : AssistSlot {
                override fun screen() = screenJson()

                override fun attach(image: String?) = share(image)

                override fun touchable(rect: android.graphics.Rect?) {
                    touchArea = rect
                    // A layout pass makes the window ask for its insets again (onComputeInsets): the app below gets the
                    // touches outside the bar from now on.
                    host?.web?.requestLayout()
                }

                override fun close() = finish()
            }
        host = h
        return h.web
    }

    override fun onShow(
        args: Bundle?,
        showFlags: Int,
    ) {
        super.onShow(args, showFlags)
        screenText = ""
        shot = null
        // A new summoning: the page forgets the last one (its question, answer view, cut-out).
        host?.bridge?.emit("assist.reset", null)
        sendScreen()
        // Its page must answer (it never loaded, it hangs: a window over the app that can't be closed from it) - else
        // the session ends (dev.omalauncher.shell.PageWatchdog).
        host?.web?.let { web ->
            watchdog?.stop()
            watchdog = dev.omalauncher.shell.PageWatchdog(web, "PowOS assistant") { finish() }.also { it.start() }
        }
    }

    private var watchdog: dev.omalauncher.shell.PageWatchdog? = null

    override fun onHide() {
        watchdog?.stop()
        // The page stays warm after the panel goes: it stops listening (a summoning starts dictation, assist.tsx).
        host?.bridge?.emit("assist.hidden", null)
        super.onHide()
    }

    /** The screen's text, as an outline of what each window shows (the app's own view text, by the framework). */
    override fun onHandleAssist(state: AssistState) {
        val structure = state.assistStructure ?: return
        val out = StringBuilder()
        // What's under the overlay, by name first: a bare list of words made the agent take PowOS's own home (its AI
        // tile, its widgets) for the assistant it was asked from.
        out.append("[under the PowOS AI overlay: ").append(appName(structure.activityComponent)).append("]\n")
        for (i in 0 until structure.windowNodeCount) walk(structure.getWindowNodeAt(i).rootViewNode, out, 0)
        screenText = out.toString().take(MAX_TEXT)
        sendScreen()
    }

    override fun onHandleScreenshot(screenshot: Bitmap?) {
        screenshot ?: return
        val dir = File(context.cacheDir, "assist").apply { mkdirs() }
        val file = File(dir, "screen.jpg")
        file.outputStream().use { screenshot.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        shot = file
        sendScreen()
    }

    override fun onDestroy() {
        watchdog?.stop()
        // Live mode ends with the session (the capture would otherwise go on, unseen).
        LiveCapture.stop(context)
        // The page stays warm for the next time (AssistWeb); only this session's window lets go of it.
        host?.let { (it.web.parent as? ViewGroup)?.removeView(it.web) }
        host?.bridge?.assist = null
        host = null
        super.onDestroy()
    }

    /** The app on screen, as the user knows it: PowOS's home is "the PowOS home screen", any other its label (package). */
    private fun appName(component: android.content.ComponentName?): String {
        component ?: return "an app"
        if (component.packageName == context.packageName) {
            return if (component.className.contains("Shell") || component.className.contains("Home")) "the PowOS home screen" else "PowOS (${component.shortClassName})"
        }
        val pm = context.packageManager
        val label = runCatching { pm.getApplicationLabel(pm.getApplicationInfo(component.packageName, 0)).toString() }.getOrNull()
        return if (label != null) "$label (${component.packageName})" else component.packageName
    }

    private fun walk(
        node: AssistStructure.ViewNode,
        out: StringBuilder,
        depth: Int,
    ) {
        val text = node.text?.toString()?.trim().orEmpty().ifEmpty { node.contentDescription?.toString()?.trim().orEmpty() }
        if (text.isNotEmpty()) out.append("  ".repeat(depth.coerceAtMost(8))).append(text.replace('\n', ' ')).append('\n')
        for (i in 0 until node.childCount) walk(node.getChildAt(i), out, depth + 1)
    }

    private fun screenJson(): JSONObject =
        JSONObject()
            .put("text", screenText)
            // The host serves it (ShellHost /_assist/); the version makes each new screenshot a new URL.
            .put("screenshot", shot?.let { "${ShellHost.ORIGIN}/_assist/screen.jpg?v=${it.lastModified()}" } ?: JSONObject.NULL)

    /**
     * An image for PowOS AI to look at, where PowOS sees it (the run dir, /run/powos-app in the session - as the share
     * sheet's files): [image] a region the user cut out (a data: URL from the page), or null for the whole screenshot.
     * Its path in PowOS; the question names it, and the agent reads it.
     */
    private fun share(image: String?): String? {
        val dir = File(context.filesDir, "run/powos-ai-shared").apply { mkdirs() }
        val name = "screen-${System.currentTimeMillis()}.${if (image == null) "jpg" else "png"}"
        val out = File(dir, name)
        if (image == null) {
            shot?.copyTo(out, overwrite = true) ?: return null
        } else {
            val data = image.substringAfter("base64,", "")
            if (data.isEmpty()) return null
            out.writeBytes(android.util.Base64.decode(data, android.util.Base64.DEFAULT))
        }
        return "/run/powos-app/powos-ai-shared/$name"
    }

    private fun sendScreen() {
        host?.bridge?.emit("assist.context", screenJson())
    }

    private companion object {

        /** The screen's text sent along, at most (a long page is mostly repetition). */
        const val MAX_TEXT = 8000
    }
}

/** What the page's assist screen reaches through the bridge (assist.screen, assist.close). */
interface AssistSlot {
    fun screen(): JSONObject

    /** Where the page takes touches (live mode: its bar), in device px; null: everywhere. */
    fun touchable(rect: android.graphics.Rect?)

    /** An image for PowOS AI (a cut-out region as a data: URL, or null: the whole screenshot); its path in PowOS. */
    fun attach(image: String?): String?

    fun close()
}

package dev.omalauncher.assist

import android.app.assist.AssistStructure
import android.content.Context
import android.graphics.Bitmap
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.view.View
import dev.omalauncher.App
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

    override fun onCreateContentView(): View {
        val runtime = (context.applicationContext as App).runtime
        runtime.start()
        val h = ShellHost(context, null, runtime, MODE)
        h.bridge.assist =
            object : AssistSlot {
                override fun screen() = screenJson()

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
        sendScreen()
    }

    /** The screen's text, as an outline of what each window shows (the app's own view text, by the framework). */
    override fun onHandleAssist(state: AssistState) {
        val structure = state.assistStructure ?: return
        val out = StringBuilder()
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
        host?.destroy()
        host = null
        super.onDestroy()
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

    private fun sendScreen() {
        host?.bridge?.emit("assist.context", screenJson())
    }

    private companion object {
        const val MODE = "assist"

        /** The screen's text sent along, at most (a long page is mostly repetition). */
        const val MAX_TEXT = 8000
    }
}

/** What the page's assist screen reaches through the bridge (assist.screen, assist.close). */
interface AssistSlot {
    fun screen(): JSONObject

    fun close()
}

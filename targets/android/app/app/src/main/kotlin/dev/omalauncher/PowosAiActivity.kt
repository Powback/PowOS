package dev.omalauncher

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import dev.omalauncher.shell.EXTRA_HOME_DRAFT
import dev.omalauncher.shell.EXTRA_HOME_PANEL
import dev.omalauncher.shell.ShellActivity
import java.io.File

/**
 * The old PowOS AI app, retired: there is one PowOS AI now - the shell's page (the pull-up panel, ui/powai.tsx) and its
 * assist overlay. This activity stays only as a redirect, so every old way here still lands on the new page: the share
 * sheet ("PowOS AI"), the assistant gesture (ACTION_ASSIST), the Quick Settings tile ([PowosAiTile]), the agents'
 * notifications ([AgentMail]) and the shell's "ai.open". It shows nothing (Theme.NoDisplay): it hands what it was given
 * to the chat ([PowosAiChat] is the conversation's one owner, data included), opens home with the AI panel up, finishes.
 */
class PowosAiActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        redirect(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        redirect(intent)
    }

    private fun redirect(intent: Intent?) {
        PowosAiChat.load(applicationContext)
        // The old "keep me in the switcher" launch (EXTRA_BACKGROUND): nothing to keep any more.
        var draft: String? = null
        if (intent != null && !intent.getBooleanExtra(EXTRA_BACKGROUND, false)) {
            // From an agent's mail notification: that mail read, and shown in the chat.
            AgentMail.opened(applicationContext, intent)
            val prompt = intent.getStringExtra(EXTRA_PROMPT)
            if (prompt != null) {
                PowosAiChat.send(applicationContext, prompt)
            } else if (intent.action == Intent.ACTION_SEND) draft = sharedDraft(intent)
            toPanel(this, draft)
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    /** A share's text and file, as the words waiting in the page's field (the user adds theirs). */
    private fun sharedDraft(intent: Intent): String? {
        val parts = mutableListOf<String>()
        intent.getStringExtra(Intent.EXTRA_SUBJECT)?.takeIf { it.isNotBlank() }?.let { parts += it }
        intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }?.let { parts += it }
        @Suppress("DEPRECATION")
        (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uri -> share(uri)?.let { parts += "Shared file: $it" } }
        return if (parts.isEmpty()) null else parts.joinToString("\n") + "\n\n"
    }

    /**
     * A shared file, copied where PowOS sees it: the app's run dir (/run/powos-app in the session). Its path in PowOS,
     * or null when it can't be read.
     */
    private fun share(uri: Uri): String? =
        runCatching {
            val name =
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) c.getString(0) else null
                }?.replace('/', '_') ?: "shared-${System.currentTimeMillis()}"
            val dir = File(filesDir, "run/powos-ai-shared").apply { mkdirs() }
            val dest = File(dir, name)
            contentResolver.openInputStream(uri)!!.use { input -> dest.outputStream().use { input.copyTo(it) } }
            "/run/powos-app/powos-ai-shared/$name"
        }.getOrNull()

    companion object {
        private const val EXTRA_PROMPT = "prompt"
        private const val EXTRA_BACKGROUND = "background"

        /** Home with PowOS AI's page up (the pull-up panel), [draft] waiting in its field. The one way to "open the AI". */
        private fun toPanel(
            context: Context,
            draft: String?,
        ) {
            context.startActivity(
                Intent(context, ShellActivity::class.java)
                    .setAction(Intent.ACTION_MAIN)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .putExtra(EXTRA_HOME_PANEL, "ai")
                    .apply { draft?.let { putExtra(EXTRA_HOME_DRAFT, it) } },
            )
        }

        /** Retired: the chat is no longer a task of its own, so there is none to keep in the switcher. */
        @Suppress("UNUSED_PARAMETER")
        fun keepInRecents(context: Context) = Unit

        /** Opens PowOS AI's page; with [prompt], sends it. */
        fun open(
            context: Context,
            prompt: String? = null,
        ) {
            prompt?.let { PowosAiChat.send(context.applicationContext, it) }
            toPanel(context, null)
        }
    }
}

package dev.omalauncher

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import dev.omalauncher.ui.Mono
import dev.omalauncher.ui.Palette
import dev.omalauncher.ui.ReadingWidth
import dev.omalauncher.ui.TextSize
import dev.omalauncher.ui.applySystemBars
import java.io.File

/**
 * PowOS AI on the phone: a chat with PowOS's manager ([PowosAiChat]) as its own task. Where the phone asks PowOS AI
 * anything: the launcher's prompt bar and search, Android's share sheet ("PowOS AI"), the Quick Settings tile
 * ([PowosAiTile]), the assistant gesture (the app as the phone's digital assistant: ACTION_ASSIST), and the agents'
 * notifications ([AgentMail]).
 */
class PowosAiActivity : ComponentActivity() {
    /** What the field holds: a shared text or file, waiting for the user's words. */
    private var draft by mutableStateOf(TextFieldValue(""))

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PowosAiChat.load(applicationContext)
        // Started only to be in the app switcher (the web launcher's chat was used): straight behind home, unseen.
        if (intent?.getBooleanExtra(EXTRA_BACKGROUND, false) == true && savedInstanceState == null) {
            moveTaskToBack(true)
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
        applySystemBars(this, Palette.isLight)
        @Suppress("DEPRECATION")
        setTaskDescription(ActivityManager.TaskDescription("PowOS AI", null, Palette.background.toArgb()))
        handle(intent)
        setContent { Chat() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Asked from the launcher again: only to come up in the switcher (most recent after home), not to show.
        if (intent.getBooleanExtra(EXTRA_BACKGROUND, false)) {
            moveTaskToBack(true)
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
            return
        }
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        intent ?: return
        // From an agent's mail notification: that mail read, and shown here.
        AgentMail.opened(applicationContext, intent)
        intent.getStringExtra(EXTRA_PROMPT)?.let {
            PowosAiChat.send(applicationContext, it)
            return
        }
        if (intent.action == Intent.ACTION_SEND) {
            val parts = mutableListOf<String>()
            intent.getStringExtra(Intent.EXTRA_SUBJECT)?.takeIf { it.isNotBlank() }?.let { parts += it }
            intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }?.let { parts += it }
            @Suppress("DEPRECATION")
            (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uri -> share(uri)?.let { parts += "Shared file: $it" } }
            if (parts.isNotEmpty()) {
                val text = parts.joinToString("\n") + "\n\n"
                draft = TextFieldValue(text, TextRange(text.length))
            }
        }
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

    @Composable
    private fun Chat() {
        val items = PowosAiChat.items
        val list = rememberLazyListState()
        val focus = remember { FocusRequester() }
        LaunchedEffect(items.size, PowosAiChat.busy) { if (items.isNotEmpty()) list.animateScrollToItem(items.size) }
        LaunchedEffect(Unit) { focus.requestFocus() }
        Box(
            Modifier
                .fillMaxSize()
                .background(Palette.background)
                .systemBarsPadding()
                .imePadding(),
            contentAlignment = Alignment.TopCenter,
        ) {
            Column(Modifier.widthIn(max = ReadingWidth).fillMaxSize().padding(horizontal = 12.dp)) {
                BasicText(
                    "PowOS AI",
                    Modifier.padding(vertical = 12.dp),
                    style = Mono.copy(fontSize = TextSize.Title, fontWeight = FontWeight.Bold),
                )
                LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (items.isEmpty()) {
                        item {
                            BasicText(
                                "Ask PowOS AI anything - about PowOS, the phone, its apps and files. It keeps the " +
                                    "conversation: `powos manager` in a terminal continues it.",
                                style = Mono.copy(color = Palette.muted),
                            )
                        }
                    }
                    itemsIndexed(items) { _, item -> Bubble(item) }
                    if (PowosAiChat.busy) item { BasicText("…", style = Mono.copy(color = Palette.muted)) }
                }
                Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    BasicTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        modifier =
                            Modifier
                                .weight(1f)
                                .focusRequester(focus)
                                .background(Palette.surface, RoundedCornerShape(12.dp))
                                .padding(12.dp),
                        textStyle = Mono.copy(fontSize = TextSize.Large),
                        cursorBrush = SolidColor(Palette.accent),
                        maxLines = 6,
                        decorationBox = { inner ->
                            if (draft.text.isEmpty()) BasicText("Message PowOS AI", style = Mono.copy(fontSize = TextSize.Large, color = Palette.muted))
                            inner()
                        },
                    )
                    val canSend = draft.text.isNotBlank() && !PowosAiChat.busy
                    Box(
                        Modifier
                            .padding(start = 8.dp)
                            .size(44.dp)
                            .background(if (canSend) Palette.accent else Palette.surface, CircleShape)
                            .clickable(enabled = canSend) {
                                PowosAiChat.send(applicationContext, draft.text)
                                draft = TextFieldValue("")
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        BasicText("↑", style = Mono.copy(fontSize = TextSize.Title, color = if (canSend) Palette.background else Palette.muted))
                    }
                }
            }
        }
    }

    @Composable
    private fun Bubble(item: PowosAiChat.Item) {
        when (item) {
            is PowosAiChat.Item.User ->
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                    SelectionContainer {
                        BasicText(
                            item.text,
                            Modifier
                                .widthIn(max = 520.dp)
                                .background(Palette.accent.copy(alpha = 0.2f), RoundedCornerShape(12.dp))
                                .padding(10.dp),
                            style = Mono,
                        )
                    }
                }
            is PowosAiChat.Item.Assistant ->
                SelectionContainer {
                    BasicText(
                        item.text,
                        Modifier.fillMaxWidth().background(Palette.surface, RoundedCornerShape(12.dp)).padding(10.dp),
                        style = Mono,
                    )
                }
            is PowosAiChat.Item.Tool -> {
                val mark =
                    when (item.ok) {
                        null -> "…"
                        true -> "✓"
                        false -> "✗"
                    }
                BasicText(
                    "⚙ ${item.name}" + (if (item.hint.isNotBlank()) "  ${item.hint}" else "") + "  $mark",
                    style = Mono.copy(fontSize = TextSize.Small, color = if (item.ok == false) Palette.current.red else Palette.muted),
                    maxLines = 2,
                )
            }
            is PowosAiChat.Item.Note ->
                BasicText(item.text, style = Mono.copy(fontSize = TextSize.Small, color = if (item.error) Palette.current.red else Palette.muted))
        }
    }

    companion object {
        private const val EXTRA_PROMPT = "prompt"
        private const val EXTRA_BACKGROUND = "background"

        /**
         * Puts the chat in the app switcher as its most recent app, without showing it: asked from the launcher's
         * search (which shows the same conversation), it's then a task of its own a swipe away. Every time - a task
         * from earlier sits far down the switcher, as good as gone.
         */
        fun keepInRecents(context: Context) {
            context.startActivity(
                Intent(context, PowosAiActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
                    .putExtra(EXTRA_BACKGROUND, true),
            )
        }

        /** Opens the chat; with [prompt], sends it. */
        fun open(
            context: Context,
            prompt: String? = null,
        ) {
            context.startActivity(
                Intent(context, PowosAiActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .apply { prompt?.let { putExtra(EXTRA_PROMPT, it) } },
            )
        }
    }
}

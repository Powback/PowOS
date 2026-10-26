package dev.omalauncher.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import dev.omalauncher.Runtime
import dev.omalauncher.linux.GuestEntry
import dev.omalauncher.linux.GuestFs
import dev.omalauncher.linux.shellQuote
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** A touch-first file manager for the guest filesystem, in the Omarchy theme. */
@Composable
fun FilesScreen(
    runtime: Runtime,
    startPath: String,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val fs = remember { GuestFs(runtime.proot::hostFile) }
    val scope = rememberCoroutineScope()
    // The folder and the way back start over when the screen is opened with another path; the rest stays.
    val nav = remember(startPath) { FilesNav(fs.normalize(startPath)) }
    val ui = remember { FilesUi() }
    val f = remember(nav, ui) { Files(runtime, fs, context, scope, ui, nav) }
    f.onExit = onExit

    val entries by produceState<List<GuestEntry>?>(null, nav.path, ui.showHidden, ui.reload) {
        value = withContext(Dispatchers.IO) { runCatching { fs.list(nav.path, ui.showHidden) }.getOrDefault(emptyList()) }
    }
    val shown = entries?.let { matching(it, ui.query) }
    val listState = rememberLazyListState()
    LaunchedEffect(nav.path) { listState.scrollToItem(0) }

    BackHandler { f.back() }

    Column(Modifier.fillMaxSize().background(Palette.background).systemBarsPadding().imePadding()) {
        if (ui.selected.isNotEmpty()) FilesSelectionBar(f, entries, shown) else FilesTopBar(f)
        Breadcrumbs(nav.path, onNavigate = f::navigate)
        Places(nav.path, exists = fs::isDir, onNavigate = f::navigate)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            FilesList(f, shown, listState)
            if (ui.selected.isEmpty() && ui.query == null) {
                Fab(Icons.NewFolder, "new folder", Modifier.align(Alignment.BottomEnd).padding(20.dp)) { ui.dialog = FileDialog.NewFolder }
            }
        }
        FilesPasteBar(f)
    }

    ui.viewing?.let { file -> ImageViewer(file, onClose = { ui.viewing = null }) }
    FilesDialogs(f)
}

/** The entries whose name contains [query] (all of them without one). */
private fun matching(
    entries: List<GuestEntry>,
    query: String?,
): List<GuestEntry> {
    if (query.isNullOrBlank()) return entries
    val q = query.lowercase()
    return entries.filter { q in it.name.lowercase() }
}

/** Where the screen is: the folder and the folders before it. */
private class FilesNav(
    start: String,
) {
    var path by mutableStateOf(start)
    val history = mutableStateListOf<String>()
}

/** What the screen shows besides the folder. */
private class FilesUi {
    var showHidden by mutableStateOf(true)
    var query by mutableStateOf<String?>(null)
    val selected = mutableStateListOf<String>()
    var reload by mutableIntStateOf(0)
    var viewing by mutableStateOf<File?>(null)
    var dialog by mutableStateOf<FileDialog?>(null)
    var menuOpen by mutableStateOf(false)
}

/** The screen's actions over its state. */
private class Files(
    val runtime: Runtime,
    val fs: GuestFs,
    private val context: Context,
    private val scope: CoroutineScope,
    val ui: FilesUi,
    val nav: FilesNav,
) {
    var onExit: () -> Unit = {}

    fun toast(msg: String) = Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()

    fun navigate(to: String) {
        nav.history += nav.path
        nav.path = to
        ui.query = null
        ui.selected.clear()
    }

    /** Back: closes what's open first, then the previous folder, then the screen. */
    fun back() {
        when {
            ui.viewing != null -> ui.viewing = null
            ui.selected.isNotEmpty() -> ui.selected.clear()
            ui.query != null -> ui.query = null
            nav.history.isNotEmpty() -> {
                nav.path = nav.history.removeAt(nav.history.lastIndex)
                ui.selected.clear()
            }
            else -> onExit()
        }
    }

    /** The top bar's back arrow: the parent folder, or out at the root. */
    fun up() {
        val up = fs.parent(nav.path)
        if (up != null) navigate(up) else onExit()
    }

    /** Runs a file operation off the main thread, then reloads the listing. */
    fun operate(block: () -> Unit) {
        scope.launch {
            val error = withContext(Dispatchers.IO) { runCatching(block).exceptionOrNull() }
            if (error != null) toast(error.message ?: "failed")
            ui.selected.clear()
            ui.reload++
        }
    }

    fun openWithAndroid(
        file: File,
        share: Boolean = false,
    ) {
        // A file outside the folders in file_paths.xml (a link out of them) has no uri.
        val uri =
            try {
                FileProvider.getUriForFile(context, context.packageName + ".files", file)
            } catch (e: IllegalArgumentException) {
                return toast("can't hand ${file.name} to other apps")
            }
        val mime = mimeOf(file.name) ?: "*/*"
        val intent =
            if (share) {
                Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, uri)
            } else {
                Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
            }.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            context.startActivity(Intent.createChooser(intent, file.name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: ActivityNotFoundException) {
            toast("no app can open ${file.name}")
        }
    }

    fun edit(entry: GuestEntry) = runtime.terminal("micro ${shellQuote(entry.path)}", entry.name)

    fun open(entry: GuestEntry) {
        if (entry.isDir) return navigate(fs.resolve(entry.path))
        val file = fs.host(entry.path)
        when {
            isImage(entry.name) -> ui.viewing = file
            isText(entry.name, file) -> edit(entry)
            else -> openWithAndroid(file)
        }
    }

    /** A tap on a row: opens it, or while selecting toggles it. */
    fun tap(entry: GuestEntry) {
        if (ui.selected.isEmpty()) {
            open(entry)
        } else if (!ui.selected.remove(entry.path)) {
            ui.selected += entry.path
        }
    }

    fun hold(entry: GuestEntry) {
        if (entry.path !in ui.selected) ui.selected += entry.path
    }

    fun selectAll(shown: List<GuestEntry>?) {
        ui.selected.clear()
        ui.selected += shown.orEmpty().map { it.path }
    }

    /** Puts the selection on the clipboard, to copy or (with [cut]) move. */
    fun clip(cut: Boolean) {
        FileClipboard.paths = ui.selected.toList()
        FileClipboard.cut = cut
        ui.selected.clear()
    }

    fun paste(clip: List<String>) {
        val cut = FileClipboard.cut
        FileClipboard.paths = emptyList()
        val into = nav.path
        operate { fs.paste(clip, into, move = cut) }
    }

    fun terminalHere() = runtime.terminal("cd ${shellQuote(nav.path)} && exec bash", "Terminal")
}

@Composable
private fun FilesSelectionBar(
    f: Files,
    entries: List<GuestEntry>?,
    shown: List<GuestEntry>?,
) {
    val ui = f.ui
    val single = entries?.firstOrNull { it.path == ui.selected.singleOrNull() }
    val file = single?.takeIf { !it.isDir }
    // Sniffing a file for text reads it: off the main thread, once per selection.
    val singleIsText by produceState(false, single?.path) {
        value = file?.let { s -> withContext(Dispatchers.IO) { isText(s.name, f.fs.host(s.path)) } } == true
    }
    SelectionBar(
        count = ui.selected.size,
        onClose = { ui.selected.clear() },
        onSelectAll = { f.selectAll(shown) },
        onCopy = { f.clip(cut = false) },
        onCut = { f.clip(cut = true) },
        onDelete = { ui.dialog = FileDialog.Delete(ui.selected.toList()) },
        onRename = single?.let { { ui.dialog = FileDialog.Rename(it) } },
        onShare = file?.let { { f.openWithAndroid(f.fs.host(it.path), share = true) } },
        onOpenWith = file?.let { { f.openWithAndroid(f.fs.host(it.path)) } },
        onEdit = single?.takeIf { singleIsText }?.let { { f.edit(it) } },
    )
}

@Composable
private fun FilesTopBar(f: Files) {
    Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(Icons.Back, "back") { f.up() }
        val q = f.ui.query
        if (q != null) {
            FilesSearch(f, q)
        } else {
            FilesTitle(f.nav.path)
            IconButton(Icons.Search, "search") { f.ui.query = "" }
            FilesMenu(f)
        }
    }
}

@Composable
private fun RowScope.FilesSearch(
    f: Files,
    q: String,
) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    BasicTextField(
        value = q,
        onValueChange = { f.ui.query = it },
        singleLine = true,
        textStyle = Mono.copy(fontSize = TextSize.Large),
        cursorBrush = SolidColor(Palette.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = {}),
        modifier = Modifier.weight(1f).focusRequester(focus).padding(horizontal = 8.dp),
        decorationBox = { inner ->
            Box {
                if (q.isEmpty()) BasicText("filter this folder", style = Mono.copy(color = Palette.muted, fontSize = TextSize.Large))
                inner()
            }
        },
    )
    IconButton(Icons.Close, "close search") { f.ui.query = null }
}

@Composable
private fun RowScope.FilesTitle(path: String) {
    Column(Modifier.weight(1f).padding(horizontal = 8.dp)) {
        BasicText(
            when (path) {
                "/" -> "/"
                "/root" -> "home"
                else -> path.substringAfterLast('/')
            },
            style = Mono.copy(fontSize = TextSize.Title),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun FilesMenu(f: Files) {
    val ui = f.ui
    Box {
        IconButton(Icons.More, "more") { ui.menuOpen = true }
        if (ui.menuOpen) {
            MenuPopup(
                listOf(
                    "new folder" to { ui.dialog = FileDialog.NewFolder },
                    (if (ui.showHidden) "hide hidden files" else "show hidden files") to { ui.showHidden = !ui.showHidden },
                    "open terminal here" to { f.terminalHere() },
                ),
                onDismiss = { ui.menuOpen = false },
            )
        }
    }
}

@Composable
private fun BoxScope.FilesList(
    f: Files,
    shown: List<GuestEntry>?,
    listState: LazyListState,
) {
    when {
        shown == null -> {}
        shown.isEmpty() ->
            BasicText(
                if (f.ui.query.isNullOrBlank()) "empty folder" else "nothing matches",
                Modifier.align(Alignment.Center),
                style = Mono.copy(color = Palette.muted),
            )
        else ->
            LazyColumn(state = listState, contentPadding = PaddingValues(bottom = 96.dp)) {
                items(shown, key = { it.path }) { entry ->
                    FileRow(
                        entry = entry,
                        selected = entry.path in f.ui.selected,
                        selecting = f.ui.selected.isNotEmpty(),
                        onClick = { f.tap(entry) },
                        onLongClick = { f.hold(entry) },
                    )
                }
            }
    }
}

@Composable
private fun FilesPasteBar(f: Files) {
    val clip = FileClipboard.paths
    if (clip.isEmpty()) return
    PasteBar(
        count = clip.size,
        cut = FileClipboard.cut,
        onCancel = { FileClipboard.paths = emptyList() },
        onPaste = { f.paste(clip) },
    )
}

@Composable
private fun FilesDialogs(f: Files) {
    val ui = f.ui
    val close = { ui.dialog = null }
    when (val d = ui.dialog) {
        null -> {}
        FileDialog.NewFolder ->
            TextDialog("new folder", "", "create", onDismiss = close) { name ->
                close()
                f.operate { f.fs.mkdir(f.nav.path, name) }
            }
        is FileDialog.Rename ->
            TextDialog("rename", d.entry.name, "rename", onDismiss = close) { name ->
                close()
                f.operate { f.fs.rename(d.entry.path, name) }
            }
        is FileDialog.Delete -> {
            val what = if (d.paths.size == 1) d.paths[0].substringAfterLast('/') else "${d.paths.size} items"
            ConfirmDialog("delete $what?", "This can't be undone.", "delete", onDismiss = close) {
                close()
                f.operate { d.paths.forEach(f.fs::delete) }
            }
        }
    }
}

private sealed interface FileDialog {
    data object NewFolder : FileDialog

    data class Rename(
        val entry: GuestEntry,
    ) : FileDialog

    data class Delete(
        val paths: List<String>,
    ) : FileDialog
}

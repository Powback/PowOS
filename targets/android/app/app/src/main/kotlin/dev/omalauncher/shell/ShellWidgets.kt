package dev.omalauncher.shell

import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.snapshotFlow
import dev.omalauncher.Runtime
import dev.omalauncher.widgets.lang.text
import dev.omalauncher.widgets.runtime.WidgetInstance
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * OWL widgets for the web shell (the bridge's widgets.* calls): the widget engine runs them here as it does for the
 * Compose launcher; the page draws them from their trees (WidgetTree), sent as "widget.tree" whenever one changes,
 * and sends back their events and sizes.
 *
 * A widget is only evaluated while the page watches it (it's on screen); animated ones get a clock while watched.
 */
class ShellWidgets(
    private val runtime: Runtime,
    private val scope: CoroutineScope,
    private val emit: (String, Any?) -> Unit,
) {
    private val engine get() = runtime.widgets
    private val watched = HashMap<String, Job>()
    private val trees = HashMap<String, WidgetTree>()

    /** The last tree sent for each watch: a page loaded again (hot reload) asks again and gets it at once. */
    private val sent = HashMap<String, String?>()

    /** Canvas sizes by "<widget key>#<element id>", in dp: state, so a new size redraws the widget. */
    private val canvasSizes = mutableStateMapOf<String, Pair<Double, Double>>()

    init {
        // A widget's screen opening or closing (its onTap's screen(), Back): the page draws it over home.
        scope.launch { snapshotFlow { screen().toString() }.collect { emit("widget.screen", JSONObject(it)) } }
    }

    /** The open screen: { key, terminal, title }, or key null. */
    fun screen(): JSONObject {
        val key = engine.openScreen ?: return JSONObject().put("key", JSONObject.NULL)
        val spec = engine.specs.firstOrNull { it.file.name == key }
        val inst = spec?.let(engine::instance) ?: return JSONObject().put("key", JSONObject.NULL)
        val title = inst.program.screenTitle?.let { inst.eval(it, inst.root, "title").text() } ?: spec.name
        return JSONObject().put("key", key).put("terminal", inst.program.terminal).put("title", title)
    }

    /** A tap on the tile itself, not on an element with its own onTap: the widget's onTap (screen(), say). */
    fun tap(key: String) {
        engine.specs.firstOrNull { it.file.name == key }?.let(engine::tap)
    }

    fun closeScreen() {
        engine.openScreen = null
    }

    private fun instance(key: String): WidgetInstance? = engine.specs.firstOrNull { it.file.name == key }?.let(engine::instance)

    /** Starts sending [key]'s tree ("widget.tree": { key, screen, tree }) now and whenever it changes. */
    fun watch(
        key: String,
        screen: Boolean,
    ) {
        val id = if (screen) "$key#screen" else key
        if (id in watched) {
            // Watched already - by this page before it reloaded: the flow only sends changes, so send it as it is.
            if (id in sent) send(key, screen, sent[id])
            return
        }
        watched[id] =
            scope.launch {
                launch { clock(key) }
                snapshotFlow {
                    // Re-read each time: a widget file saved again is a new instance.
                    val inst = instance(key) ?: return@snapshotFlow null
                    val sizes = canvasSizes.filterKeys { it.startsWith("$key#") }.mapKeys { it.key.substringAfter('#') }
                    val tree = WidgetTree(inst, sizes)
                    val json = tree.tree(screen).toString()
                    trees[id] = tree
                    json
                }.distinctUntilChanged()
                    .conflate()
                    .collect { json ->
                        sent[id] = json
                        send(key, screen, json)
                        // Every frame at most: a widget whose state changes faster is drawn at this rate.
                        delay(FRAME_MS)
                    }
            }
    }

    private fun send(
        key: String,
        screen: Boolean,
        json: String?,
    ) = emit("widget.tree", JSONObject().put("key", key).put("screen", screen).put("tree", json?.let(::JSONObject) ?: JSONObject.NULL))

    fun unwatch(
        key: String,
        screen: Boolean,
    ) {
        val id = if (screen) "$key#screen" else key
        watched.remove(id)?.cancel()
        sent.remove(id)
    }

    /** What the Compose launcher's FrameClock does: `time` advances while an animated widget is on screen. */
    private suspend fun clock(key: String) {
        val start = System.nanoTime()
        while (true) {
            val inst = instance(key)
            if (inst?.program?.animated == true) inst.time = (System.nanoTime() - start) / 1e9
            delay(FRAME_MS)
        }
    }

    fun fire(
        key: String,
        screen: Boolean,
        id: String,
        name: String,
        args: List<Double>,
    ) {
        trees[if (screen) "$key#screen" else key]?.fire(id, name, args)
    }

    /** The tile's size: cells for `cols`/`rows`, dp for `tileWidth`/`tileHeight`. */
    fun size(
        key: String,
        cols: Int,
        rows: Int,
        width: Double,
        height: Double,
    ) {
        instance(key)?.setTile(cols, rows, width, height)
    }

    fun canvas(
        key: String,
        id: String,
        width: Double,
        height: Double,
    ) {
        canvasSizes["$key#$id"] = width to height
    }

    /** The page on screen: widgets on it and beside it run their sources, the rest pause. */
    fun page(page: Int) {
        engine.activePage = page
    }

    private companion object {
        const val FRAME_MS = 33L
    }
}

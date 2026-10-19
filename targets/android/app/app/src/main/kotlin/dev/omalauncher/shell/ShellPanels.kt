package dev.omalauncher.shell

import android.content.Context
import dev.omalauncher.App
import dev.omalauncher.widgets.Cell
import org.json.JSONArray
import org.json.JSONObject

/**
 * Home items the shell draws itself, kind "panel" (shell/types.ts HomeItem): the Agents widget (shell/ui/agents.tsx).
 * Not an OWL widget - its data is the shell's already (AgentsSpool), and an OWL tree would be sent again on every
 * change. Each is a name and a page, kept here; its cell is the home layout's, as other apps' Android widgets' are
 * (AppWidgets), and the home's own placement steps around it. Keys "panel:<name>", one of each.
 */
class ShellPanels private constructor(
    private val context: Context,
) {
    private val prefs = context.getSharedPreferences("shell_panels", Context.MODE_PRIVATE)
    private val layout get() = (context as App).runtime.widgets.layout
    private val entries = LinkedHashMap<String, Int>()

    init {
        runCatching { JSONObject(prefs.getString(ENTRIES, "{}")!!) }.getOrNull()?.let { o -> o.keys().forEach { entries[it] = o.getInt(it) } }
        // The home's placement steps around these too (after the Android widgets', which set it first).
        val before = layout.occupied
        layout.occupied = { page -> before(page) + entries.filterValues { it == page }.keys.mapNotNull { layout.cell(key(it)) } }
    }

    /** [snapshot] (home.get) with the panels in it, their pages too. */
    fun merge(snapshot: JSONObject): JSONObject {
        val items = snapshot.getJSONArray("items")
        val pages = snapshot.getJSONArray("pages").let { a -> (0 until a.length()).map { a.getInt(it) } }.toMutableSet()
        for ((name, page) in entries) {
            val (w, h) = SIZES[name] ?: (4 to 2)
            items.put(
                JSONObject()
                    .put("key", key(name))
                    .put("kind", "panel")
                    .put("name", name)
                    .put("page", page)
                    .put("resizable", true)
                    .put("minSize", JSONArray(listOf(MIN[name]?.first ?: 2, MIN[name]?.second ?: 1)))
                    .put("size", JSONArray(listOf(w, h)))
                    .putOpt("cell", layout.cell(key(name))?.let { JSONObject().put("x", it.x).put("y", it.y).put("w", it.w).put("h", it.h) }),
            )
            pages += page
        }
        return snapshot.put("pages", JSONArray(pages.sorted()))
    }

    fun owns(key: String) = key.startsWith(PREFIX)

    /** Puts panel [name] on [page] at [cell] (the page found the spot: grid.tsx placeNew); there already: moved there. */
    fun add(
        name: String,
        page: Int,
        cell: JSONObject,
    ): String {
        require(name in SIZES) { "no panel $name" }
        entries[name] = page
        save()
        layout.set(key(name), cell(cell))
        layout.save()
        return key(name)
    }

    /** Moves or resizes one (home.place). */
    fun place(
        key: String,
        cell: JSONObject,
        page: Int,
    ) {
        val name = key.removePrefix(PREFIX)
        require(name in entries) { "no home item $key" }
        layout.set(key, cell(cell))
        layout.save()
        if (entries[name] != page) {
            entries[name] = page
            save()
        }
    }

    fun remove(key: String) {
        if (entries.remove(key.removePrefix(PREFIX)) == null) return
        save()
        layout.remove(key)
    }

    private fun cell(c: JSONObject) = Cell(c.getInt("x"), c.getInt("y"), c.getInt("w"), c.getInt("h"))

    private fun save() = prefs.edit().putString(ENTRIES, JSONObject(entries as Map<*, *>).toString()).apply()

    companion object {
        private const val ENTRIES = "entries"
        const val PREFIX = "panel:"

        /** The panels there are, and the size each starts at; the smallest each may be made. */
        private val SIZES = mapOf("agents" to (4 to 2))
        private val MIN = mapOf("agents" to (2 to 1))

        fun key(name: String) = "$PREFIX$name"

        @Volatile private var instance: ShellPanels? = null

        @Synchronized
        fun get(context: Context): ShellPanels {
            // After the Android widgets: their layout.occupied is set first, then chained here.
            AppWidgets.get(context)
            return instance ?: ShellPanels(context.applicationContext).also { instance = it }
        }
    }
}

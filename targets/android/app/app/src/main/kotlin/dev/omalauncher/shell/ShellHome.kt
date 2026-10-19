package dev.omalauncher.shell

import dev.omalauncher.Runtime
import dev.omalauncher.widgets.Cell
import dev.omalauncher.widgets.Folder
import dev.omalauncher.widgets.GRID_COLUMNS
import dev.omalauncher.widgets.HomeItem
import dev.omalauncher.widgets.Shortcut
import dev.omalauncher.widgets.WidgetItem
import org.json.JSONArray
import org.json.JSONObject

/**
 * The home screen for the web shell (the bridge's home.* calls): the same pages, widgets, pinned apps, folders and
 * cells as the Compose launcher - its WidgetLayout and Shortcuts - so the two show one home while both exist.
 *
 * Pinned apps carry the page's app keys ("a:…" / "l:…") beside their own ("app:…" / "linux:…"), so the page can
 * launch them and match them with the drawer.
 */
class ShellHome(
    private val runtime: Runtime,
) {
    private val engine get() = runtime.widgets

    /** Everything the home screen shows: the grid's columns, its pages and their items with their cells. */
    fun snapshot(): JSONObject {
        val pages = engine.pages
        val items = JSONArray()
        for (page in pages) for (item in engine.itemsOn(page)) items.put(item(item))
        return JSONObject().put("columns", GRID_COLUMNS).put("pages", JSONArray(pages)).put("items", items)
    }

    /**
     * Gives the items that have no cell yet (a widget from the store, an app pinned from a menu) one: the first free
     * spot at their size on a grid of [cols] x [rows], as the Compose home does when it lays a page out
     * (HomeGrid.kt); one that doesn't fit goes to a page with room. The page asks once it knows its grid.
     */
    fun arrange(
        cols: Int,
        rows: Int,
    ) {
        for (page in engine.pages) engine.layout.place(engine.itemsOn(page), cols, rows).forEach { engine.moveToFreePage(it) }
    }

    /** What changes the home screen: read inside snapshotFlow, so any of it changing sends home.changed. */
    fun fingerprint(): String = snapshot().toString()

    private fun item(item: HomeItem): JSONObject {
        val o =
            JSONObject()
                .put("key", item.key)
                .put("page", item.page)
                .put("resizable", item.resizable)
                .put("minSize", JSONArray(listOf(item.minSize.first, item.minSize.second)))
                .putOpt("size", item.size?.let { JSONArray(listOf(it.first, it.second)) })
                .putOpt("cell", engine.layout.cell(item.key)?.let(::cell))
        when (item) {
            is WidgetItem ->
                o
                    .put("kind", "widget")
                    .put("name", item.spec.name)
                    .putOpt("error", item.spec.error)
            is Shortcut -> o.put("kind", "app").put("label", item.label).put("app", appKey(item))
            is Folder ->
                o
                    .put("kind", "folder")
                    .put("apps", JSONArray(item.apps.map { JSONObject().put("key", it.key).put("label", it.label).put("app", appKey(it)) }))
        }
        return o
    }

    private fun cell(c: Cell) = JSONObject().put("x", c.x).put("y", c.y).put("w", c.w).put("h", c.h)

    private fun appKey(s: Shortcut) =
        when {
            s.key.startsWith("app:") -> "a:" + s.key.removePrefix("app:")
            s.key.startsWith("linux:") -> "l:" + s.key.removePrefix("linux:")
            else -> s.key
        }

    private fun find(key: String): HomeItem? = engine.pages.asSequence().flatMap { engine.itemsOn(it) }.firstOrNull { it.key == key }

    /** Moves or resizes [key] to [cell] on [page] (a move across pages too), and saves. */
    fun place(
        key: String,
        cell: JSONObject,
        page: Int,
    ) {
        val item = find(key) ?: error("no home item $key")
        engine.layout.set(key, Cell(cell.getInt("x"), cell.getInt("y"), cell.getInt("w"), cell.getInt("h")))
        if (page != item.page) engine.moveToPage(item, page)
        engine.layout.save()
    }

    /** Pins the app [appKey] to [page], at [cell] if given (dropped there from the drawer), else in the first free spot. */
    fun add(
        appKey: String,
        page: Int,
        cell: JSONObject?,
    ): String {
        val key =
            when {
                appKey.startsWith("a:") -> {
                    val app = runtime.androidApps.apps.firstOrNull { "a:${it.key}" == appKey } ?: error("no app $appKey")
                    engine.shortcuts.addAndroid(app, page)
                    "app:${app.key}"
                }
                appKey.startsWith("l:") -> {
                    val app = runtime.linuxApps.firstOrNull { "l:${it.id}" == appKey } ?: error("no app $appKey")
                    engine.shortcuts.addLinux(app, page)
                    "linux:${app.id}"
                }
                else -> error("bad app key $appKey")
            }
        if (cell != null) engine.layout.set(key, Cell(cell.getInt("x"), cell.getInt("y"), 1, 1))
        engine.layout.save()
        return key
    }

    /** Takes [key] off the home screen, as the Compose home's remove does (a widget's file goes too). */
    fun remove(key: String) {
        when (val item = find(key) ?: return) {
            is WidgetItem -> engine.removeWidget(item.spec)
            is Shortcut, is Folder -> engine.shortcuts.remove(item.key)
        }
        engine.layout.remove(key)
    }

    /** Drops the app [key] on [target]: into its folder, or both into a new one. */
    fun group(
        key: String,
        target: String,
    ): String? {
        val app = find(key) as? Shortcut ?: return null
        return engine.shortcuts.group(app, find(target) ?: return null)
    }
}

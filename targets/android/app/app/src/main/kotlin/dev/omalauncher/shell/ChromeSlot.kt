package dev.omalauncher.shell

import org.json.JSONArray
import org.json.JSONObject

/** Scoped to a chrome page: the host supplies state and performs actions; all visible chrome is web UI. */
interface ChromeSlot {
    fun state(): JSONObject
    fun ready() {}
    fun action(name: String)
    fun regions(regions: JSONArray) {}
}

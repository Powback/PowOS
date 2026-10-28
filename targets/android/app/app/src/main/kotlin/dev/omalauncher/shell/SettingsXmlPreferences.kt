package dev.omalauncher.shell

import android.content.res.Resources
import android.content.res.XmlResourceParser
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser

/** Resolve preference resources in the provider's own package, including localized titles and option entries. */
internal class SettingsXmlPreferences(private val resources: Resources, private val excluded: Set<String>) {
    private var screen = ""
    private var hiddenPage = false

    fun read(id: Int): List<JSONObject> = resources.getXml(id).use { xml ->
        val rows = mutableListOf<JSONObject>()
        while (xml.next() != XmlPullParser.END_DOCUMENT) {
            val row = preference(xml) ?: continue
            if (hiddenPage) return emptyList()
            rows.add(row)
        }
        rows
    }

    private fun preference(xml: XmlResourceParser): JSONObject? {
        if (xml.eventType != XmlPullParser.START_TAG || !xml.name.contains("Preference")) return null
        val title = attribute(xml, "title")
        val key = attribute(xml, "key")
        if (xml.depth == 1) {
            screen = title
            hiddenPage = key.isNotBlank() && key in excluded
        }
        if (xml.name.endsWith("PreferenceCategory")) return null
        return JSONObject().put("title", title).put("key", key).put("screenTitle", screen)
            .put("summaryOn", attribute(xml, "summary").ifBlank { attribute(xml, "summaryOn") })
            .put("summaryOff", attribute(xml, "summaryOff")).put("keywords", attribute(xml, "keywords"))
            .put("entries", attribute(xml, "entries"))
    }

    private fun attribute(xml: XmlResourceParser, name: String): String {
        val index = (0 until xml.attributeCount).firstOrNull { xml.getAttributeName(it) == name } ?: return ""
        val res = xml.getAttributeResourceValue(index, 0)
        if (res == 0) return xml.getAttributeValue(index).orEmpty()
        return runCatching { resourceText(res) }.getOrDefault("")
    }

    private fun resourceText(id: Int): String = when (resources.getResourceTypeName(id)) {
        "array" -> resources.getTextArray(id).joinToString(" ")
        else -> resources.getText(id).toString()
    }
}

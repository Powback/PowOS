package dev.omalauncher.system.gesture

import org.json.JSONObject

/**
 * The edge gestures' settings ([EdgeGestures]): the shell's settings page (shell/ui/edge.tsx) keeps them in the page
 * store as `edgeGestures` (files/shell-data/edgeGestures.json); anything missing is the default. Shared shape with the
 * page's: keep the two in step.
 *
 * Actions: "none", "quicktools", "back", "home", "recents", "notifications", "control", "assistant", "drawer",
 * "previous", "playpause", or "app:<package>".
 */
data class EdgeConfig(
    val on: Boolean = true,
    /** The thin handles drawn on the edges where the gestures are. */
    val handles: Boolean = true,
    /** The travel that makes a swipe: "high" (short), "normal", "low" (long). */
    val sensitivity: String = "normal",
    val left: Side = Side(on = false, actions = LEFT),
    val right: Side = Side(on = true, actions = RIGHT),
) {
    data class Side(
        val on: Boolean,
        /** The handle's span, as fractions of the screen's height from the top (default the lower half). */
        val top: Float = 0.5f,
        val bottom: Float = 1f,
        /** How far in from the edge a finger down is the handle's (dp). */
        val width: Float = 18f,
        /** "short.straight" ... "long.down" -> action. */
        val actions: Map<String, String>,
    ) {
        fun action(key: String) = actions[key] ?: "none"
    }

    fun triggerDp() =
        when (sensitivity) {
            "high" -> 18f
            "low" -> 44f
            else -> 28f
        }

    companion object {
        val KEYS = listOf("short.straight", "short.up", "short.down", "long.straight", "long.up", "long.down")

        /**
         * The right edge: in and up is Quick Tools (the user's favourite, from Good Lock); straight in stays Back, as the
         * system's edge swipe was there - so the lower half keeps Back.
         */
        val RIGHT =
            mapOf(
                "short.straight" to "back",
                "short.up" to "quicktools",
                "short.down" to "notifications",
                "long.straight" to "previous",
                "long.up" to "quicktools",
                "long.down" to "control",
            )

        /** The left edge (off until it's turned on): every short swipe Back, as the system's was. */
        val LEFT =
            mapOf(
                "short.straight" to "back",
                "short.up" to "back",
                "short.down" to "back",
                "long.straight" to "previous",
                "long.up" to "home",
                "long.down" to "recents",
            )

        fun parse(text: String?): EdgeConfig {
            val j = text?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return EdgeConfig()
            val d = EdgeConfig()
            return EdgeConfig(
                on = j.optBoolean("on", d.on),
                handles = j.optBoolean("handles", d.handles),
                sensitivity = j.optString("sensitivity", d.sensitivity),
                left = side(j.optJSONObject("left"), d.left),
                right = side(j.optJSONObject("right"), d.right),
            )
        }

        private fun side(
            j: JSONObject?,
            d: Side,
        ): Side {
            if (j == null) return d
            val a = j.optJSONObject("actions")
            val top = j.optDouble("top", d.top.toDouble()).toFloat().coerceIn(0f, 0.95f)
            return Side(
                on = j.optBoolean("on", d.on),
                top = top,
                bottom = j.optDouble("bottom", d.bottom.toDouble()).toFloat().coerceIn(top + 0.05f, 1f),
                width = j.optDouble("width", d.width.toDouble()).toFloat().coerceIn(8f, 40f),
                actions = KEYS.associateWith { k -> a?.optString(k)?.takeIf { it.isNotEmpty() } ?: d.action(k) },
            )
        }
    }
}

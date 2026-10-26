package dev.omalauncher.shell

import java.net.URI

/**
 * Who may talk to the app through the shell page's native objects (PowosHost, PowosNative, PowosBoot): the page's own
 * top frame at its own origin - nothing else.
 *
 * Why: the objects were JavaScript interfaces (WebView.addJavascriptInterface), which Android puts into EVERY frame of
 * the page and which can't see who calls them. Any iframe running script - a presentation, web content, a third-party
 * app's frame - could have used the whole host API (fetch with the user's secrets, launching/uninstalling apps,
 * settings). Now they are web message listeners (androidx.webkit addWebMessageListener), injected only into frames at
 * [rules]' origins, and each message is checked again here with what the WebView says about its sender ([allowed]):
 *
 *  - another origin, or an opaque one ("null": a sandboxed frame, a data: URL) is never the shell;
 *  - a frame that isn't the top one is refused even at the shell's origin: an about:blank or srcdoc iframe without a
 *    sandbox inherits its parent's origin, so the origin alone can't tell it from the page. Nothing legitimate calls
 *    from a subframe: PowOS apps' UIs (./_app/<id>/) are modules imported into the page's own frame, and the answers
 *    go to the top frame anyway (ShellBridge.respond).
 */
object ShellOrigin {
    /** The shell's origin: a name that never reaches the network (ShellHost serves every request). */
    const val SHELL = "https://shell.powos"

    /** The origins whose top frame gets the objects: the shell's, and a dev server's when one is set ([devUrl]). */
    fun rules(devUrl: String?): Set<String> = setOfNotNull(SHELL, devUrl?.let(::of))

    /** "scheme://host[:port]" of an http(s) URL; null for anything else (no host, another scheme, unparsable). */
    fun of(url: String): String? {
        val u = runCatching { URI(url.trim()) }.getOrNull() ?: return null
        val scheme = u.scheme?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        val host = u.host?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        val port = u.port.takeIf { it != -1 && it != (if (scheme == "https") 443 else 80) }
        return "$scheme://$host${port?.let { ":$it" } ?: ""}"
    }

    /**
     * Whether a message from a frame at [sourceOrigin] (the WebView's word for it: "null" when opaque) may use the
     * objects: the top frame, at one of [rules] exactly.
     */
    fun allowed(
        sourceOrigin: String?,
        isMainFrame: Boolean,
        rules: Set<String>,
    ): Boolean {
        if (!isMainFrame || sourceOrigin == null) return false
        val origin = sourceOrigin.trim().trimEnd('/')
        if (origin.isEmpty() || origin == "null") return false
        return origin in rules
    }
}

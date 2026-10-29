package dev.omalauncher.system

import dev.omalauncher.shell.ShellBridge

/**
 * Which shell panel is open (the launcher drawer "apps", PowOS AI's "ai" - home's, the one launcher), as the
 * page tells it ("panels.open" / "panels.closed"). The bottom-edge home gesture ([dev.omalauncher.system.gesture.NavGesture])
 * then closes THAT panel: it follows the finger ("panel.close.begin" / ".drag" { p } / ".end" { shut }) instead of
 * going home or raising the switcher. Only this gesture closes panels - a swipe inside the content never does.
 */
object Panels {
    @Volatile var kind: String? = null
        private set

    @Volatile private var bridge: ShellBridge? = null

    fun set(
        kind: String?,
        from: ShellBridge,
    ) {
        if (kind == null && bridge !== from) return
        this.kind = kind
        bridge = if (kind == null) null else from
    }

    /** The page that has a panel open and can be seen (home started), else null. */
    fun live(): ShellBridge? = bridge.takeIf { kind != null && Switcher.homeVisible }

    fun begin(b: ShellBridge) = b.emit("panel.close.begin", org.json.JSONObject().put("kind", kind))

    fun drag(
        b: ShellBridge,
        p: Float,
    ) = b.emit("panel.close.drag", org.json.JSONObject().put("p", p.coerceIn(0f, 1f).toDouble()))

    fun end(
        b: ShellBridge,
        shut: Boolean,
    ) = b.emit("panel.close.end", org.json.JSONObject().put("shut", shut))
}

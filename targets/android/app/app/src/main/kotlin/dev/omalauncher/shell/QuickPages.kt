package dev.omalauncher.shell

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Quick pages, the host side ([QuickPageRoute] is the rule; ui/quickpage.tsx the card): one settings page launched with
 * the quick flags onto its own trusted display under home's compact card. Every settings page PowOS opens - search
 * results, quickpage.open from the side launcher / control center - comes through [launch]. A route failure is full
 * screen and logged, never a freeform window.
 */
object QuickPages {
    private const val TAG = "PowosQuickPages"

    /** A quick page's launch: what its display shows ([component]), its label, and how it pops out. */
    class Entry(val token: String, val component: ComponentName, val label: String, val popOut: () -> Unit)

    private val entries = ConcurrentHashMap<String, Entry>()
    private val next = AtomicInteger()

    fun entry(token: String): Entry? = entries[token]

    /**
     * quickpage.open({action | component | fragment | id, anchorRect, label}): [id] a settings search result's
     * ("settings:<ACTION>", "indexed:..."), [action] a settings action, [component] an exported activity, [fragment]
     * a com.android.settings fragment (root SubSettings). The side launcher / control center store a stable ACTION.
     */
    fun open(
        context: Context,
        spec: JSONObject,
    ): Boolean {
        val anchor = spec.optJSONObject("anchorRect")
        val label = spec.optString("label")
        val id = spec.optString("id")
        if (id.isNotEmpty()) return true.also { SettingsSearch(context).open(id, anchor) }
        val fragment = spec.optString("fragment")
        if (fragment.isNotEmpty()) return true.also { NativeSettingsIndex.openFragmentPage(context, fragment, label, anchor) }
        val action = spec.optString("action")
        val component = spec.optString("component")
        val intent =
            when {
                action.isNotEmpty() -> Intent(action)
                component.isNotEmpty() -> Intent().setComponent(checkNotNull(ComponentName.unflattenFromString(component)) { "quickpage.open: bad component $component" })
                else -> error("quickpage.open: no action, component, fragment or id")
            }
        launch(context, intent, label.ifEmpty { action.substringAfterLast('.') }, anchor)
        return true
    }

    /**
     * One settings page to open: [intent], its [label], what it springs out of ([anchor], CSS px). [start] starts it
     * with given options (null: startActivity of [intent]; a root fragment launch passes its own); [popOut] relaunches
     * it in its app's normal window (null: [intent] without the quick flags).
     */
    class Page(
        val intent: Intent,
        val label: String,
        val anchor: JSONObject?,
        val start: ((Bundle?) -> Unit)? = null,
        val popOut: (() -> Unit)? = null,
    )

    /** [intent] as [launch] of a plain [Page]. */
    fun launch(
        context: Context,
        intent: Intent,
        label: String,
        anchor: JSONObject?,
    ) = launch(context, Page(intent, label, anchor))

    /**
     * [page] as a quick page on the web desktop; a native panel as Android's own sheet; elsewhere (folded, web windows
     * off) as any launch.
     */
    fun launch(
        context: Context,
        page: Page,
    ) {
        val intent = page.intent
        val start = page.start ?: { b: Bundle? -> context.startActivity(intent, b) }
        val info = runCatching { context.packageManager.resolveActivity(intent, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo }.getOrNull()
        val component = intent.component ?: info?.let { ComponentName(it.packageName, it.name) }
        val pkg = component?.packageName
        val web = dev.omalauncher.system.AppWindows.webDesktop(context)
        when (QuickPageRoute.decide(QuickPageRoute.kind(pkg, intent.action, component?.className, asApp = false), web)) {
            QuickPageRoute.Route.NATIVE_SHEET -> start(null.also { intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
            QuickPageRoute.Route.QUICK_WINDOW -> quick(context, page, component!!, start)
            else -> dev.omalauncher.system.AppWindows.launch(context, pkg) { start(it.also { intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }) }
        }
    }

    private fun quick(
        context: Context,
        page: Page,
        component: ComponentName,
        start: (Bundle?) -> Unit,
    ) {
        val intent = page.intent
        intent.addFlags(QuickPageRoute.flags(component.packageName))
        val token = next.incrementAndGet().toString()
        entries[token] = Entry(token, component, page.label, page.popOut ?: { dev.omalauncher.system.AppWindows.startActivity(context, poppedOut(intent)) })
        // The safety net (QuickPageRoute.afterFailure): full screen, logged - never Tasks.freeformOptions.
        val failed = { why: String ->
            entries.remove(token)
            WindowLog.w(TAG, "quick page $token (${component.flattenToShortString()}): $why: opened full screen, never a freeform window")
            runCatching { start(dev.omalauncher.system.Tasks.fullScreenOptions().toBundle()) }.onFailure { WindowLog.w(TAG, "quick page $token full screen failed", it) }
            Unit
        }
        val show = JSONObject().put("token", token).put("pkg", component.packageName).put("label", page.label).put("anchor", page.anchor ?: JSONObject.NULL)
        val pending = WebWindowLaunch.Pending(null, start) { failed("no quick page display") }
        if (!WebWindowLaunch.routeQuick(context, QuickPageRoute.key(token), pending, show)) failed("no home page")
        else WindowLog.i(TAG, "quick page $token (${component.flattenToShortString()}, flags 0x${Integer.toHexString(intent.flags)}): card asked of home")
    }

    /** Pop-out: [close] the card (its task with it), then the same page in its app's normal window. */
    fun popOut(
        token: String,
        close: () -> Unit,
    ): Boolean {
        val e = entries.remove(token) ?: return false
        close()
        WindowLog.i(TAG, "quick page $token (${e.component.flattenToShortString()}): popped out into its app's window")
        e.popOut()
        return true
    }

    /** [intent] without the quick flags: the app's normal window (recents, dock). */
    fun poppedOut(intent: Intent): Intent = Intent(intent).setFlags(QuickPageRoute.poppedOut(intent.flags))
}

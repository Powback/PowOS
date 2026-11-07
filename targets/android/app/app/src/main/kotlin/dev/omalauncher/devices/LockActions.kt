package dev.omalauncher.devices

import org.json.JSONObject

/**
 * How a phone WITHOUT root locks itself: Android's own lock (LockAccess.kt - a device admin holding only the force-lock
 * policy, turned on by the person from the Devices app). Pure Kotlin so the advertising rule is tested on the JVM.
 */
interface Locker {
    /** The person allowed it (the admin is active right now - they can turn it off in Android's Settings any time). */
    fun allowed(): Boolean

    /** Locks the screen now; the screen goes off with it. */
    fun lock()
}

/**
 * lock and screen_off, advertised exactly while the person allows them: read live on every info/status/action, so a
 * grant or a revoke (in the Devices app or Android's Settings) is in the next answer - nothing cached, nothing taken
 * without asking. screen_off is a lock here: without root there is no screen-off that leaves the phone unlocked.
 */
class LockActions(
    private val locker: Locker,
) {
    fun caps(): List<String> = if (locker.allowed()) CAPS else emptyList()

    fun handles(action: String) = action in CAPS

    fun act(action: String): JSONObject {
        if (!locker.allowed()) throw DeviceActionError(NOT_ALLOWED, "unsupported")
        locker.lock()
        return JSONObject().put("done", true).put("locked", true).put("screen", "off").also { if (action == "screen_off") it.put("as", "lock") }
    }

    companion object {
        val CAPS = listOf("lock", "screen_off")
        const val NOT_ALLOWED = "not allowed on this phone yet - its owner turns it on with \"Allow lock\" in the phone's Devices app"
    }
}

/**
 * A backend plus this phone's lock: [inner]'s caps with lock/screen_off added while allowed, those two actions done by
 * [lock], the rest by [inner]. The no-root agent's real backend (DeviceAgentHost) is wrapped in it.
 */
class WithLock(
    private val inner: DeviceBackend,
    private val lock: LockActions,
) : DeviceBackend {
    override fun caps() = inner.caps() + lock.caps()

    override fun refusal(action: String) = if (lock.handles(action)) LockActions.NOT_ALLOWED else inner.refusal(action)

    override fun status(): JSONObject = inner.status()

    override fun act(
        action: String,
        args: JSONObject,
        force: Boolean,
    ): JSONObject = if (lock.handles(action)) lock.act(action) else inner.act(action, args, force)
}

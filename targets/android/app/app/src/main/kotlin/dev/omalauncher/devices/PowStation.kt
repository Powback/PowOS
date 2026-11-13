package dev.omalauncher.devices

import android.content.Context
import android.provider.Settings
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.omalauncher.ClaudeSignIn
import dev.omalauncher.linux.Guest
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.URL

/**
 * "Join your PowStation" - the first-run setup step and Settings' PowStation tile (shell/ui/joinscreen.tsx; the user,
 * 11-09: "proper device management and onboarding so I can use all of my devices", "we just need to give it a tenant
 * URL"). Two ways after the image installs: use PowOS on its own, or join the owner's hub.
 *
 * Joining is the realm's device flow (PowStation enroll/powos-enroll.py, RFC 8628's shape, LAN/VPN only):
 *  1. the address: `powstation.pow` (the hub's name on every PowOS LAN/VPN, "Your PowStation"), prefilled when its
 *     GET /v1/realm answers here, editable;
 *  2. POST /v1/device/code with this phone's identity (its device agent's id, DeviceAgentHost) -> the code, shown big
 *     with this phone's name, to approve on any enrolled device (the Devices app's "New device wants to join" card).
 *     No password on the phone;
 *  3. POST /v1/device/token every interval until approved -> {device_token, endpoints, ai?, owner}: kept 0600 in
 *     files/devices/enrollment.json, the owner bundle written as the owner config (files/run/owner.conf, the format
 *     lib/devices/powos-deviced owner_apply writes, [OwnerConfig]), and handed to PowOS's Linux when it's there
 *     (`powos devices adopt -`: its owner config, units.d record and, with the Claude subscription the approver picked,
 *     its AI endpoint = the hub's claude-auth - no Claude login on the phone).
 *  4. Leave: the realm revokes this phone's tokens (/v1/devices/self/unenroll), the files go, standalone again.
 *
 * The page sees no token: [json] is the state only.
 */
object PowStation {
    private const val TAG = "powstation"

    /** The hub's name on any PowOS LAN/VPN (Pi-hole record from its Traefik route; .pow is LAN/VPN-only fleet-wide). */
    const val DEFAULT_ADDRESS = "powstation.pow"

    /** "choose" (never decided), "standalone", "finding", "ready" (the address field), "asking", "code", "joined", "leaving". */
    var phase by mutableStateOf("")
        private set
    var address by mutableStateOf(DEFAULT_ADDRESS)
        private set

    /** The hub answered at [address] (GET /v1/realm): the field is prefilled with it. */
    var found by mutableStateOf(false)
        private set
    var hub by mutableStateOf("")
        private set
    var owner by mutableStateOf("")
        private set
    var code by mutableStateOf("")
        private set
    var tenant by mutableStateOf("")
        private set
    var error by mutableStateOf("")
        private set

    /** What PowOS's Linux said when it took the enrollment ("" = not handed over: no image yet, or not joined). */
    var linux by mutableStateOf("")
        private set

    private var app: Context? = null

    @Volatile private var run = 0

    fun json(c: Context): JSONObject {
        load(c)
        return JSONObject()
            .put("phase", phase)
            .put("address", address)
            .put("found", found)
            .put("hub", hub.ifBlank { "Your PowStation" })
            .put("owner", owner)
            .put("code", code)
            .put("name", deviceName(c))
            .put("tenant", tenant)
            .put("error", error)
            .put("linux", linux)
    }

    /** The saved choice, read once: joined (the enrollment file), standalone, or not decided yet. */
    private fun load(c: Context) {
        if (app != null) return
        app = c.applicationContext
        val e = enrollment(c)
        when {
            e != null -> joined(e)
            choiceFile(c).exists() -> phase = "standalone"
            else -> phase = "choose"
        }
    }

    fun act(
        c: Context,
        action: String,
        arg: String,
    ) {
        load(c)
        when (action) {
            "standalone" -> {
                cancelRun()
                runCatching { choiceFile(c).apply { parentFile?.mkdirs() }.writeText("standalone\n") }
                set("standalone")
            }
            "start", "find" -> find(c)
            "address" -> address = arg.trim()
            "ask" -> ask(c, arg.ifBlank { address })
            "cancel" -> {
                cancelRun()
                set(if (choiceFile(c).exists()) "standalone" else "choose")
            }
            "leave" -> leave(c)
            else -> throw IllegalArgumentException("no such action: join.$action")
        }
    }

    private fun set(
        p: String,
        why: String = "",
    ) {
        phase = p
        error = why
    }

    private fun cancelRun() {
        run++
    }

    /** The address field, prefilled with the hub when it answers on this network. */
    private fun find(c: Context) {
        val mine = ++run
        set("finding")
        Thread({
            val info = realmInfo(urlOf(DEFAULT_ADDRESS))
            if (mine != run) return@Thread
            found = info != null
            if (info != null) {
                address = DEFAULT_ADDRESS
                hub = info.optString("hub")
                owner = info.optString("owner")
            }
            set("ready")
        }, "powstation-find").start()
    }

    private fun ask(
        c: Context,
        typed: String,
    ) {
        val realm = urlOf(typed)
        if (realm.isEmpty()) return set("ready", "type the address of your PowStation, like powstation.pow")
        address = typed.trim()
        val mine = ++run
        set("asking")
        Thread({
            runCatching { flow(c, realm, mine) }.onFailure {
                if (mine == run) set("ready", it.message ?: "couldn't reach $address")
            }
        }, "powstation-join").start()
    }

    /** Steps 2-3 (the class comment): the code, then poll until the realm answers once. */
    private fun flow(
        c: Context,
        realm: String,
        mine: Int,
    ) {
        realmInfo(realm)?.let {
            hub = it.optString("hub")
            owner = it.optString("owner")
        }
        val (st, r) = post("$realm/v1/device/code", request(c))
        if (st != 200) throw IllegalStateException(refusal(r, "$address didn't take the request ($st)"))
        if (mine != run) return
        code = r.optString("user_code")
        set("code")
        poll(c, realm, r, mine)
    }

    /** Step 3: the token, every interval, until the realm answers once (or refuses, or the code runs out). */
    private fun poll(
        c: Context,
        realm: String,
        r: JSONObject,
        mine: Int,
    ) {
        interval = r.optInt("interval", 5).coerceAtLeast(1)
        val deadline = System.currentTimeMillis() + r.optInt("expires_in", 600) * 1000L
        val dc = JSONObject().put("device_code", r.optString("device_code"))
        while (System.currentTimeMillis() < deadline && mine == run) {
            Thread.sleep(interval * 1000L)
            if (!pollOnce(c, realm, dc, mine)) return
        }
        if (mine == run) set("ready", "nobody approved it in time - ask again")
    }

    /** One poll: true = keep waiting ([interval] grows on slow_down); false = done (joined, refused or cancelled). */
    private fun pollOnce(
        c: Context,
        realm: String,
        dc: JSONObject,
        mine: Int,
    ): Boolean {
        val (st, t) = runCatching { post("$realm/v1/device/token", dc) }.getOrElse { 0 to JSONObject() }
        val err = t.optString("error")
        when {
            mine != run -> return false
            st == 200 -> took(c, realm, t).let { return false }
            err == "slow_down" -> interval += 5
            err !in WAITING -> set("ready", why(err, t)).let { return false }
        }
        return true
    }

    /** Seconds between polls: the realm's interval, longer after each slow_down. */
    @Volatile private var interval = 5

    private val WAITING = setOf("authorization_pending", "slow_down", "")

    private fun why(
        err: String,
        t: JSONObject,
    ) = if (err == "access_denied") "not approved - ask again to try once more" else refusal(t, "the code ran out - ask again")

    /** Approved: keep it (0600), the owner config, PowOS's Linux. */
    private fun took(
        c: Context,
        realm: String,
        t: JSONObject,
    ) {
        val e = enrollmentOf(realm, t)
        val f = enrollmentFile(c)
        f.parentFile?.mkdirs()
        f.writeText(e.toString())
        f.setReadable(false, false)
        f.setReadable(true, true)
        f.setWritable(false, false)
        f.setWritable(true, true)
        writeOwnerConf(c, ownerBundle(e))
        runCatching { choiceFile(c).apply { parentFile?.mkdirs() }.writeText("joined\n") }
        joined(e)
        adopt(e)
    }

    private fun joined(e: JSONObject) {
        owner = e.optString("owner")
        hub = e.optString("hub")
        tenant = e.optJSONObject("ai")?.optString("tenant") ?: ""
        address = hostOf(e.optString("realm"))
        code = ""
        set("joined")
    }

    /** PowOS's Linux takes the same enrollment (powos-deviced adopt): its owner config, units.d and AI endpoint. */
    private fun adopt(e: JSONObject) {
        if (!Guest.enabled) {
            linux = ""
            return
        }
        val out = StringBuilder()
        val rc =
            runCatching {
                val p = Guest.process("exec powos devices adopt -", mergeErrors = true).start()
                p.outputStream.use { it.write(e.toString().toByteArray()) }
                p.inputStream.bufferedReader().forEachLine { out.append(it).append('\n') }
                p.waitFor()
            }.getOrElse { -1 }
        linux = if (rc == 0) "PowOS Linux joined too" else "PowOS Linux didn't take it: ${out.lines().lastOrNull { it.isNotBlank() } ?: rc}"
        Log.i(TAG, "adopt rc=$rc")
        app?.let { ClaudeSignIn.refresh(it) }
    }

    private fun leave(c: Context) {
        val e = enrollment(c) ?: return set("standalone")
        cancelRun()
        set("leaving")
        Thread({
            val (st, r) =
                runCatching {
                    post(e.optString("realm") + "/v1/devices/self/unenroll", JSONObject(), e.optString("device_token"))
                }.getOrElse { 0 to JSONObject().put("error_description", "couldn't reach ${address.ifBlank { "the hub" }}") }
            if (st != 200 && st != 401) return@Thread set("joined", "couldn't leave: ${refusal(r, "the hub answered $st")}")
            // The realm said no more (or never knew it): this Linux's copy goes too (its own call then gets 401, fine).
            if (Guest.enabled) runCatching { Guest.runOwn("exec powos devices unenroll 2>&1") }
            enrollmentFile(c).delete()
            writeOwnerConf(c, emptyMap())
            runCatching { choiceFile(c).writeText("standalone\n") }
            owner = ""
            tenant = ""
            linux = ""
            set("standalone")
            app?.let { ClaudeSignIn.refresh(it) }
        }, "powstation-leave").start()
    }

    // --- approving other devices (this phone joined as an approver)

    /**
     * The Devices app's realm calls (bridge "devices.realm", off the main thread): this phone approves and revokes with
     * its own enrollment, as powos-deviced does on a desktop (its /v1/enroll calls) - the token never reaches a page. "state"
     * -> {enrolled, approver}; "pending" / "devices" / "approve" {code, decision, tenant?} / "revoke" {id} -> the
     * realm's answer; a refusal throws with the realm's words (the bridge rejects with them).
     */
    fun realm(
        c: Context,
        op: String,
        body: JSONObject?,
    ): JSONObject {
        val e = enrollment(c)
        val approver = e?.optJSONObject("device")?.optBoolean("approver") == true
        if (op == "state") return JSONObject().put("enrolled", e != null).put("approver", approver)
        val call = realmCall(op, body ?: JSONObject())
        checkNotNull(e) { "this phone hasn't joined a PowStation - Settings > powstation" }
        check(approver) { "this phone joined without the right to approve devices" }
        val realm = e.optString("realm")
        val (st, r) =
            runCatching { http(call.first, realm + call.second, call.third, e.optString("device_token")) }
                .getOrElse { throw IllegalStateException("the hub (${hostOf(realm)}) isn't reachable") }
        // a realm 401 is about this phone's enrollment (revoked or left), never a pairing
        check(st == 200) { refusal(r, "the hub answered $st") }
        return r
    }

    /** [op]'s method, realm path and body (pure: PowStationTest); only the fields the realm takes are passed on. */
    fun realmCall(
        op: String,
        b: JSONObject,
    ): Triple<String, String, JSONObject?> =
        when (op) {
            "pending" -> Triple("GET", "/v1/devices/pending", null)
            "devices" -> Triple("GET", "/v1/devices", null)
            "approve" -> {
                val decision = b.optString("decision", "approve")
                require(decision == "approve" || decision == "deny") { "decision is approve or deny" }
                val code = b.optString("code").trim().take(16)
                require(code.isNotEmpty()) { "which code?" }
                val out = JSONObject().put("code", code).put("decision", decision).put("approver", b.optBoolean("approver", true))
                b.optString("tenant").takeIf { it.isNotBlank() }?.let { out.put("tenant", it.take(64)) }
                Triple("POST", "/v1/devices/approve", out)
            }
            "revoke" -> {
                val id = b.optString("id").trim().take(64)
                require(id.isNotEmpty()) { "which device?" }
                Triple("POST", "/v1/devices/revoke", JSONObject().put("id", id))
            }
            else -> throw IllegalArgumentException("no such realm call: $op")
        }

    // --- what this phone tells the realm

    private fun deviceName(c: Context) = Settings.Global.getString(c.contentResolver, Settings.Global.DEVICE_NAME) ?: android.os.Build.MODEL

    /** Its device agent's identity (DeviceAgentCore's files/deviced/identity.json), so the realm and pairing agree. */
    private fun request(c: Context): JSONObject {
        val id =
            runCatching { JSONObject(File(c.filesDir, "deviced/identity.json").readText()).optString("id") }.getOrNull()
                ?.takeIf { it.isNotBlank() } ?: ("android-" + (Settings.Secure.getString(c.contentResolver, Settings.Secure.ANDROID_ID) ?: "phone"))
        val ip = lanAddress()
        return JSONObject()
            .put("id", id)
            .put("name", deviceName(c))
            .put("kind", "phone")
            .put("platform", "android ${android.os.Build.VERSION.RELEASE} (${android.os.Build.MODEL})")
            .put("caps", JSONArray(listOf("status", "screen_on", "ring")))
            .put("agent", if (ip != null) "https://$ip:${DeviceAgentCore.PORT}" else "")
    }

    private fun lanAddress(): String? =
        runCatching {
            NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList() }.firstOrNull { it is Inet4Address && it.isSiteLocalAddress }?.hostAddress
        }.getOrNull()

    // --- files

    private fun enrollmentFile(c: Context) = File(c.filesDir, "devices/enrollment.json")

    private fun choiceFile(c: Context) = File(c.filesDir, "devices/powstation-choice")

    private fun enrollment(c: Context): JSONObject? =
        runCatching { JSONObject(enrollmentFile(c).readText()) }.getOrNull()?.takeIf { it.optString("device_token").isNotBlank() }

    /** The launcher's owner config (the one [OwnerConfig] reads); empty removes it. */
    private fun writeOwnerConf(
        c: Context,
        keys: Map<String, String>,
    ) {
        val f = File(c.filesDir, "run/owner.conf")
        if (keys.isEmpty()) {
            f.delete()
            return
        }
        f.parentFile?.mkdirs()
        val tmp = File(f.path + ".tmp")
        tmp.writeText(ownerConfText(keys))
        tmp.renameTo(f)
    }

    // --- pure (PowStationTest)

    private val OWNER_KEY = Regex("^POWOS_[A-Z0-9_]{1,48}$")

    /** "powstation.pow", "192.168.50.100:8080", "http://x/" -> the realm's base URL; "" for nothing usable. */
    fun urlOf(text: String): String {
        val t = text.trim().removeSuffix("/")
        if (t.isEmpty() || t.any { it.isWhitespace() }) return ""
        val withScheme = if (t.startsWith("http://") || t.startsWith("https://")) t else "http://$t"
        val host = withScheme.substringAfter("://").substringBefore('/')
        return if (host.isEmpty()) "" else withScheme.substringBefore("://") + "://" + host
    }

    fun hostOf(url: String) = url.substringAfter("://").substringBefore('/')

    /** What is kept of the realm's one answer (no more than powos-deviced keeps). */
    fun enrollmentOf(
        realm: String,
        t: JSONObject,
    ): JSONObject =
        JSONObject()
            .put("realm", realm)
            .put("device", t.optJSONObject("device") ?: JSONObject())
            .put("device_token", t.optString("device_token"))
            .put("ai", t.optJSONObject("ai") ?: JSONObject.NULL)
            .put("endpoints", t.optJSONObject("endpoints") ?: JSONObject())
            .put("owner", t.optString("owner"))
            .put("hub", t.optString("hub"))
            .put("at", System.currentTimeMillis() / 1000)

    /** The realm's owner bundle (endpoints.owner): only POWOS_* keys, one line each - as owner_apply keeps it. */
    fun ownerBundle(e: JSONObject): Map<String, String> {
        val o = e.optJSONObject("endpoints")?.optJSONObject("owner") ?: return emptyMap()
        return o.keys().asSequence().filter { OWNER_KEY.matches(it) }
            .mapNotNull { k -> o.opt(k)?.toString()?.takeIf { '\n' !in it }?.let { k to it } }.toMap().toSortedMap()
    }

    fun ownerConfText(keys: Map<String, String>) =
        "# The owner's settings for this device, from its realm enrollment (PowOS setup: Join your PowStation); removed\n" +
            "# on Leave. Not a secret. PowStation.kt / lib/devices/powos-deviced owner_apply.\n" +
            keys.toSortedMap().entries.joinToString("") { "${it.key}=${it.value}\n" }

    private fun refusal(
        r: JSONObject,
        fallback: String,
    ) = r.optString("error_description").ifBlank { r.optString("error").ifBlank { fallback } }

    // --- HTTP
    // HACK: plain HTTP to powstation.pow on the LAN/VPN, as the realm itself serves it (enroll/docker-compose.yml): the
    // device token crosses the LAN/VPN leg unencrypted, and the AI token it hands PowOS's Linux is one the deployed
    // claude-auth doesn't know yet, so the authority serves it as its default subscription. Real fix: the realm CA / a
    // .pow certificate (device-ecosystem.md P4) and claude-rate-limiter's enrolled-devices map deployed.

    private fun realmInfo(realm: String): JSONObject? =
        runCatching {
            val (st, r) = http("GET", "$realm/v1/realm", null, null)
            r.takeIf { st == 200 && it.optString("powos").startsWith("realm/") }
        }.getOrNull()

    private fun post(
        url: String,
        body: JSONObject,
        token: String? = null,
    ) = http("POST", url, body, token)

    private fun http(
        method: String,
        url: String,
        body: JSONObject?,
        token: String?,
    ): Pair<Int, JSONObject> {
        // finding the hub is quick or not at all; asking it may wait on a slow LAN
        val timeout = if (method == "GET") 2500 else 10_000
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = timeout
        conn.readTimeout = timeout
        conn.setRequestProperty("Content-Type", "application/json")
        if (token != null) conn.setRequestProperty("Authorization", "Bearer $token")
        try {
            if (body != null) {
                conn.doOutput = true
                conn.outputStream.use { it.write(body.toString().toByteArray()) }
            }
            val st = conn.responseCode
            val text = (if (st < 400) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            return st to (runCatching { JSONObject(text) }.getOrNull() ?: JSONObject())
        } finally {
            conn.disconnect()
        }
    }
}

package dev.omalauncher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.FileObserver
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import dev.omalauncher.shell.ShellActivity
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CopyOnWriteArraySet

/**
 * The Agents view on the phone (docs/AGENTS-VIEW-DESIGN.md, Phase 1): which agents run, their subagents, tasks and
 * steps, as PowOS's powos-agentsd writes them into the run dir -
 *   agents/state.json, messages.json, events/<agent>.json   this phone's agents (/run/powos-app/agents in PowOS)
 *   agents/mirror/<host>.json                               another host's, folded (the Mac's; HACK, see powos-agentsd)
 * - merged by agent id (ids are host-prefixed, so hosts never collide).
 *
 * Nothing polls: one FileObserver per folder (HotReload's rule: one per path in a process), the files read on a thread
 * of their own. Pages get "agents.delta" with only the rows that changed, and only while they're subscribed
 * (agents.snapshot, until agents.unsubscribe: a hidden page gets nothing and takes a snapshot when it shows again);
 * an agent's events only for the one a page watches (agents.events). The ongoing notification follows the working
 * agents (at most every 5 s, only when its text changes).
 */
object AgentsSpool {
    private const val TAG = "PowosAgents"

    /** One page's subscription: its bridge's emit, whether it's on, and the agent whose events it shows. */
    class Viewer(
        val emit: (String, Any?) -> Unit,
    ) {
        @Volatile var on = false

        @Volatile var watching: String? = null
    }

    private val viewers = CopyOnWriteArraySet<Viewer>()
    private val main = Handler(Looper.getMainLooper())
    private val worker by lazy { Handler(HandlerThread("agents").apply { start() }.looper) }
    private val observers = ArrayList<FileObserver>()
    private var dir: File? = null
    private lateinit var app: Context

    /** What each source holds: "local" (state.json + messages.json) and "mirror:<host>". Worker thread only. */
    private class Source(
        val agents: List<JSONObject> = emptyList(),
        val tasks: List<JSONObject> = emptyList(),
        val messages: List<JSONObject> = emptyList(),
        val asks: List<JSONObject> = emptyList(),
        /** A mirror carries its agents' recent events; the local ones are files of their own. */
        val events: Map<String, JSONArray> = emptyMap(),
    )

    private val sources = HashMap<String, Source>()
    private var localState = Source()
    private var localMessages = emptyList<JSONObject>()

    // The last merge, as sent: rows by id (their JSON), each agent's tasks, the messages' ids.
    private var agentRows = HashMap<String, String>()
    private var taskRows = HashMap<String, String>()
    private var askRows = HashMap<String, String>()
    private var messageIds = HashSet<String>()
    private val eventRows = HashMap<String, String>()

    /** The whole merged state, what agents.snapshot answers (replaced, never changed in place). */
    @Volatile private var full: JSONObject = JSONObject().put("full", true)

    /** The notification's "Open": the page opens the Agents screen when it's next asked (agents.takeOpen). */
    @Volatile private var openPending = false

    private var pendingRead = false
    private val dirtySources = HashSet<String>()

    /** Watches [runDir]/agents (the PowOS session's /run/powos-app/agents); made here, so the session and root can write. */
    fun start(
        context: Context,
        runDir: File,
    ) {
        if (dir != null) return
        app = context.applicationContext
        val d = File(runDir, "agents")
        dir = d
        for (f in listOf(d, File(d, "events"), File(d, "mirror"), File(d, "asks"))) {
            f.mkdirs()
            f.setReadable(true, false)
            f.setExecutable(true, false)
        }
        // The approval notification's Allow / Deny / Reply (registered here: they only mean something while this runs).
        app.registerReceiver(Asker.Receiver(), android.content.IntentFilter(Asker.ACTION), Context.RECEIVER_NOT_EXPORTED)
        watch(d) { name -> if (name == "state.json" || name == "messages.json") changed("local") }
        watch(File(d, "mirror")) { name -> if (name.endsWith(".json") && !name.startsWith(".")) changed("mirror:${name.removeSuffix(".json")}") }
        watch(File(d, "events")) { name -> if (name.endsWith(".json") && !name.startsWith(".")) ringChanged(name.removeSuffix(".json")) }
        // What's there already (this phone's last state, a mirror pushed while the app wasn't running).
        changed("local")
        File(d, "mirror").listFiles { f -> f.name.endsWith(".json") && !f.name.startsWith(".") }?.forEach { changed("mirror:${it.name.removeSuffix(".json")}") }
        Log.i(TAG, "watching $d")
    }

    private fun watch(
        d: File,
        onFile: (String) -> Unit,
    ) {
        val o =
            object : FileObserver(d, CLOSE_WRITE or MOVED_TO) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    if (path != null) onFile(path)
                }
            }
        o.startWatching()
        observers += o
    }

    // The bridge (ShellBridge: agents.*).

    fun subscribe(viewer: Viewer): JSONObject {
        viewers += viewer
        viewer.on = true
        return full
    }

    fun unsubscribe(viewer: Viewer) {
        viewer.on = false
        viewer.watching = null
    }

    fun forget(viewer: Viewer) {
        viewers -= viewer
    }

    /** [viewer] shows [agent]'s events (null: none): they come as "agents.delta" ({ eventsOf, events }), now and on change. */
    fun watchEvents(
        viewer: Viewer,
        agent: String?,
    ) {
        viewer.watching = agent
        if (agent != null) worker.post { sendEvents(agent, force = viewer) }
    }

    fun takeOpen(): Boolean = openPending.also { openPending = false }

    /**
     * The user's answer to an ask (the Agents screen, the approval notification): "allow" or "deny" ([reason]: what
     * the agent is told). powos-agent-ask, waiting on asks/, takes it. HACK: see powos-agent-ask (§7: the agents' uid is
     * the app's on the phone, so the file's owner can't prove the user wrote it; real fix = Phase 2's answer reducer).
     */
    fun answer(
        ask: String,
        behavior: String,
        reason: String?,
    ) {
        require(behavior == "allow" || behavior == "deny") { "bad answer $behavior" }
        require(ask.matches(Regex("ask-[0-9a-f]{1,32}"))) { "bad ask $ask" }
        val d = File(dir ?: return, "asks")
        worker.post {
            runCatching {
                val tmp = File(d, ".$ask.tmp")
                tmp.writeText(JSONObject().put("answer", behavior).put("reason", reason ?: JSONObject.NULL).put("by", "user").toString())
                tmp.renameTo(File(d, "$ask.json"))
                Asker.answered(ask)
            }.onFailure { Log.w(TAG, "can't answer $ask", it) }
        }
    }

    /** Mail to an agent's comms inbox, as the user (AgentMail's reply): the manager is woken by it, others read it next. */
    fun message(
        role: String,
        text: String,
    ) {
        require(role.matches(Regex("[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}"))) { "bad role $role" }
        Thread({
            runCatching { dev.omalauncher.linux.RootedGuest.run("powos comms send ${dev.omalauncher.linux.shellQuote(role)} ${dev.omalauncher.linux.shellQuote(text)} --from user") }
                .onFailure { Log.w(TAG, "can't send to $role", it) }
        }, "agents-message").start()
    }

    /**
     * Ends [agent]'s current turn (SIGINT, as Esc or Ctrl-C at its terminal; the session stays). This phone's agents
     * only: a pid means something on its own host alone.
     */
    fun interrupt(agent: String) {
        worker.post {
            val a = sources["local"]?.agents?.firstOrNull { it.optString("id") == agent } ?: return@post
            val pid = a.optInt("pid")
            if (pid <= 1 || '/' in agent) return@post
            Thread({ runCatching { dev.omalauncher.linux.RootedGuest.run("kill -INT $pid") } }, "agents-interrupt").start()
        }
    }

    /** The ongoing notification tapped (ShellActivity's intent): the page opens the Agents screen. */
    fun opened(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_OPEN, false) != true) return
        intent.removeExtra(EXTRA_OPEN)
        openPending = true
        for (v in viewers) v.emit("agents.open", null)
    }

    // Reading and merging (the worker thread).

    private fun changed(source: String) {
        worker.post {
            dirtySources += source
            if (pendingRead) return@post
            pendingRead = true
            // Files written together (state, then messages) are read together.
            worker.postDelayed({
                pendingRead = false
                val todo = dirtySources.toList()
                dirtySources.clear()
                for (s in todo) read(s)
                merge()
            }, 50)
        }
    }

    private fun read(source: String) {
        val d = dir ?: return
        if (source == "local") {
            readJson(File(d, "state.json"))?.let { localState = Source(rows(it, "agents"), rows(it, "tasks"), asks = rows(it, "asks")) }
            readJson(File(d, "messages.json"))?.let { localMessages = rows(it, "messages") }
            sources["local"] = Source(localState.agents, localState.tasks, localMessages, localState.asks)
        } else {
            val host = source.removePrefix("mirror:")
            val o = readJson(File(d, "mirror/$host.json"))
            if (o == null) {
                sources.remove(source)
                return
            }
            val ev = o.optJSONObject("events")
            val events = HashMap<String, JSONArray>()
            ev?.keys()?.forEach { k -> ev.optJSONArray(k)?.let { events[k] = it } }
            sources[source] = Source(rows(o, "agents"), rows(o, "tasks"), rows(o, "messages"), rows(o, "asks"), events)
        }
    }

    private fun readJson(f: File): JSONObject? = runCatching { JSONObject(f.readText()) }.getOrNull()

    private fun rows(
        o: JSONObject,
        key: String,
    ): List<JSONObject> {
        val a = o.optJSONArray(key) ?: return emptyList()
        return List(a.length()) { a.optJSONObject(it) }.filterNotNull()
    }

    private fun merge() {
        val agents = LinkedHashMap<String, JSONObject>()
        val tasks = HashMap<String, JSONArray>()
        val asks = LinkedHashMap<String, JSONObject>()
        val messages = ArrayList<JSONObject>()
        for (s in sources.values) {
            for (a in s.agents) agents[a.optString("id")] = a
            for (t in s.tasks) tasks.getOrPut(t.optString("agent")) { JSONArray() }.put(t)
            for (a in s.asks) asks[a.optString("id")] = a
            messages += s.messages
        }
        // The comms feed: newest last, the last 50 (§1.3), each message once (one can be on two hosts' feeds).
        val feed = messages.distinctBy { it.optString("id") }.sortedBy { it.optLong("ts") }.takeLast(50)

        val delta = JSONObject()
        val changedAgents = JSONArray()
        val rows = HashMap<String, String>()
        for ((id, a) in agents) {
            val s = a.toString()
            rows[id] = s
            if (agentRows[id] != s) changedAgents.put(a)
        }
        val gone = JSONArray(agentRows.keys.filter { it !in rows })
        val tRows = tasks.mapValues { it.value.toString() }
        val tasksOf = (tRows.keys + taskRows.keys).filter { tRows[it] != taskRows[it] }
        val aRows = asks.mapValues { it.value.toString() }
        val newMessages = feed.filter { it.optString("id") !in messageIds }
        if (changedAgents.length() > 0) delta.put("agents", changedAgents)
        if (gone.length() > 0) delta.put("gone", gone)
        if (tasksOf.isNotEmpty()) {
            delta.put("tasksOf", JSONArray(tasksOf))
            delta.put("tasks", JSONArray().also { out -> tasksOf.forEach { id -> tasks[id]?.let { l -> for (i in 0 until l.length()) out.put(l.get(i)) } } })
        }
        if (aRows != askRows) {
            delta.put("asks", JSONArray(asks.values))
            Asker.update(app, asks.values.filter { it.isNull("answer") }, agents)
        }
        if (newMessages.isNotEmpty()) delta.put("messages", JSONArray(newMessages))
        agentRows = rows
        taskRows = HashMap(tRows)
        askRows = HashMap(aRows)
        messageIds = feed.mapTo(HashSet()) { it.optString("id") }

        full =
            JSONObject()
                .put("full", true)
                .put("agents", JSONArray(agents.values))
                .put("tasks", JSONArray().also { out -> tasks.values.forEach { l -> for (i in 0 until l.length()) out.put(l.get(i)) } })
                .put("asks", JSONArray(asks.values))
                .put("messages", JSONArray(feed))
        if (delta.length() > 0) for (v in viewers) if (v.on) v.emit("agents.delta", delta)
        // A mirrored host's events come with its state: a watched agent's, if they changed.
        val mirrored = sources.filterKeys { it != "local" }.values.flatMapTo(HashSet()) { it.events.keys }
        for (v in viewers) v.watching?.let { if (it in mirrored) sendEvents(it) }
        AgentsNotifier.update(app, agents.values.toList())
    }

    private fun ringChanged(file: String) {
        worker.post {
            for (v in viewers) v.watching?.let { if (safeFile(it) == file) sendEvents(it) }
        }
    }

    /** [agent]'s events to the pages that watch it, when they changed ([force]: to that page anyway). */
    private fun sendEvents(
        agent: String,
        force: Viewer? = null,
    ) {
        val d = dir ?: return
        val events =
            sources.values.firstNotNullOfOrNull { it.events[agent] }
                ?: readJson(File(d, "events/${safeFile(agent)}.json"))?.optJSONArray("events")
                ?: JSONArray()
        val s = events.toString()
        val same = eventRows[agent] == s
        eventRows[agent] = s
        if (eventRows.size > 32) eventRows.keys.filter { k -> viewers.none { it.watching == k } }.forEach { eventRows.remove(it) }
        val payload = JSONObject().put("eventsOf", agent).put("events", events)
        for (v in viewers) if (v.watching == agent && (v === force || !same)) v.emit("agents.delta", payload)
    }

    /**
     * The approval notifications (AgentMail's urgent channel: heads-up, heard on silent and through Do not disturb), one per ask: "devops wants to run Bash", its
     * command, Allow / Deny / Reply… (a deny with the reply as its reason). An ask that goes without an answer from
     * here expired: its agent asks at its terminal now, and the notification says so.
     */
    private object Asker {
        const val ACTION = "dev.omalauncher.AGENTS_ANSWER"
        private const val TAG_N = "agents-ask"
        private const val KEY_TEXT = "text"
        private val shown = HashSet<String>()
        private val mine = HashSet<String>()

        fun answered(ask: String) {
            mine += ask
            app.getSystemService(NotificationManager::class.java).cancel(TAG_N, ask.hashCode())
        }

        fun update(
            context: Context,
            open: List<JSONObject>,
            agents: Map<String, JSONObject>,
        ) {
            val nm = context.getSystemService(NotificationManager::class.java)
            val ids = open.map { it.optString("id") }.toSet()
            for (gone in shown - ids) {
                if (gone !in mine) {
                    nm.notify(
                        TAG_N,
                        gone.hashCode(),
                        Notification.Builder(context, AgentMail.channel(context, "low"))
                            .setSmallIcon(R.drawable.ic_notification)
                            .setContentTitle("PowOS agents")
                            .setContentText("expired · decided at the terminal")
                            .setTimeoutAfter(15_000)
                            .build(),
                    )
                }
                shown -= gone
                mine -= gone
            }
            for (ask in open) {
                val id = ask.optString("id")
                if (id in shown) continue
                shown += id
                val who = agents[ask.optString("agent")]?.optString("role") ?: "an agent"
                val n = id.hashCode()
                fun action(
                    label: String,
                    behavior: String,
                    reply: Boolean = false,
                ): Notification.Action {
                    val i = Intent(ACTION).setPackage(context.packageName).putExtra("ask", id).putExtra("behavior", behavior)
                    val flags = if (reply) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE
                    val pi = PendingIntent.getBroadcast(context, n * 3 + label.length, i, flags or PendingIntent.FLAG_UPDATE_CURRENT)
                    val b = Notification.Action.Builder(null, label, pi)
                    if (reply) b.addRemoteInput(android.app.RemoteInput.Builder(KEY_TEXT).setLabel("Tell $who instead").build())
                    return b.build()
                }
                val open =
                    PendingIntent.getActivity(
                        context,
                        n,
                        Intent(context, ShellActivity::class.java).putExtra(EXTRA_OPEN, true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    )
                val left = (ask.optLong("expires") - System.currentTimeMillis()).coerceAtLeast(1_000)
                nm.notify(
                    TAG_N,
                    n,
                    // An agent blocked on the user: AgentMail's urgent channel (heard on silent, through Do not disturb).
                    Notification.Builder(context, AgentMail.channel(context, "urgent"))
                        .setSmallIcon(R.drawable.ic_notification)
                        .setContentTitle("$who wants to run ${ask.optString("tool")}")
                        .setContentText(ask.optString("summary"))
                        .setStyle(Notification.BigTextStyle().bigText(ask.optString("summary")))
                        .setCategory(Notification.CATEGORY_MESSAGE)
                        .setContentIntent(open)
                        .setAutoCancel(true)
                        .setTimeoutAfter(left + 15_000)
                        .addAction(action("Allow", "allow"))
                        .addAction(action("Deny", "deny"))
                        .addAction(action("Reply…", "deny", reply = true))
                        .build(),
                )
            }
        }

        class Receiver : android.content.BroadcastReceiver() {
            override fun onReceive(
                context: Context,
                intent: Intent,
            ) {
                val ask = intent.getStringExtra("ask") ?: return
                val behavior = intent.getStringExtra("behavior") ?: return
                val reason = android.app.RemoteInput.getResultsFromIntent(intent)?.getCharSequence(KEY_TEXT)?.toString()?.trim()
                runCatching { answer(ask, behavior, reason?.takeIf { it.isNotEmpty() }) }
            }
        }
    }

    /** powos-agentsd's file name for an agent's ring. */
    private fun safeFile(agent: String) = agent.replace(Regex("[^A-Za-z0-9._-]"), "_").take(150)

    const val EXTRA_OPEN = "powos.agents.open"

    /**
     * The ongoing notification (channel powos-agents-live, silent): there only while an agent works, "PowOS agents ·
     * N working", the busiest one and its subagents, a line each when expanded. Updated at most every 5 s and only
     * when its text changes; gone once everything has been idle for 30 s.
     */
    private object AgentsNotifier {
        private const val CHANNEL = "powos-agents-live"
        private const val ID = 0x41474e54
        private const val EVERY_MS = 5_000L
        private const val CANCEL_AFTER_MS = 30_000L

        /** A working agent with no news for this long: its host went away (a mirror that stopped), not working. */
        private const val STALE_MS = 30 * 60_000L

        private var shown: String? = null
        private var lastPost = 0L
        private var next: Notification? = null
        private var nextText: String? = null
        private val post = Runnable { flush() }
        private val cancel = Runnable { cancelNow() }
        private lateinit var ctx: Context

        fun update(
            context: Context,
            agents: List<JSONObject>,
        ) {
            ctx = context
            val now = System.currentTimeMillis()
            val working =
                agents
                    .filter { it.optString("state") == "working" && '/' !in it.optString("id") && now - it.optLong("last") < STALE_MS }
                    .sortedByDescending { it.optLong("last") }
            if (working.isEmpty()) {
                worker.removeCallbacks(post)
                next = null
                if (shown != null && !worker.hasCallbacks(cancel)) worker.postDelayed(cancel, CANCEL_AFTER_MS)
                return
            }
            worker.removeCallbacks(cancel)
            val line = { a: JSONObject ->
                val subs = a.optInt("subs")
                val what = a.optString("title").ifBlank { a.optString("step") }.ifBlank { a.optString("cwd") }
                "${a.optString("role")} (${a.optString("host")})${if (what.isNotBlank()) ": $what" else ""}${if (subs > 0) " · $subs sub" else ""}"
            }
            val title = "PowOS agents · ${working.size} working"
            val text = line(working.first())
            val lines = working.take(6).map(line)
            val key = "$title\n${lines.joinToString("\n")}"
            if (key == shown) {
                next = null
                return
            }
            val open =
                PendingIntent.getActivity(
                    context,
                    ID,
                    Intent(context, ShellActivity::class.java).putExtra(EXTRA_OPEN, true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            val style = Notification.InboxStyle().setBigContentTitle(title)
            lines.forEach { style.addLine(it) }
            next =
                Notification.Builder(context, CHANNEL)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setStyle(style)
                    .setContentIntent(open)
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)
                    .setShowWhen(false)
                    .setCategory(Notification.CATEGORY_PROGRESS)
                    .addAction(Notification.Action.Builder(null, "Open", open).build())
                    .build()
            nextText = key
            if (!worker.hasCallbacks(post)) worker.postDelayed(post, (lastPost + EVERY_MS - now).coerceAtLeast(0))
        }

        private fun flush() {
            val n = next ?: return
            val nm = ctx.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "PowOS agents at work", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while PowOS AI's agents work: how many, and what"
                    setShowBadge(false)
                },
            )
            runCatching { nm.notify(ID, n) }.onFailure { Log.w(TAG, "can't post the agents notification", it) }
            shown = nextText
            next = null
            lastPost = System.currentTimeMillis()
        }

        private fun cancelNow() {
            ctx.getSystemService(NotificationManager::class.java).cancel(ID)
            shown = null
        }
    }
}

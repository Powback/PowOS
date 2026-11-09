package dev.omalauncher.upgrade

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.omalauncher.R
import dev.omalauncher.linux.EngineGuest
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.shell.ShellSource
import dev.omalauncher.shell.WebWindows
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.DigestInputStream
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipInputStream
import org.json.JSONArray
import org.json.JSONObject

/**
 * What [PowosUpdates] decides, without Android: the store's answers parsed, whether a run is due, whether a shell
 * bundle applies, and the progress line for pacman's output. JVM-tested (PowosUpdatesTest).
 */
object UpdatePlan {
    /** The PowApps store (android-app-dev's output/): LAN, or the WireGuard VPN with Pi-hole's DNS; no public route. */
    const val STORE = "http://android.pow/apk"

    /** A run on its own (the launcher in front) at most this often; Settings' "check" runs at once. */
    const val INTERVAL_MS = 6 * 60 * 60 * 1000L

    /** After a run that couldn't reach the store (away from home, no VPN), the next automatic one waits this long. */
    const val RETRY_MS = 30 * 60 * 1000L

    /** One published shell (targets/android/publish-shell.sh's powos-shell.json). */
    data class ShellBundle(
        val time: Long,
        val commit: String,
        val file: String,
        val sha256: String,
        val size: Long,
        val apk: Long,
    )

    private fun field(
        json: String,
        name: String,
    ): String? =
        Regex("\"$name\"\\s*:\\s*(\"([^\"]*)\"|(-?[0-9]+))").find(json)?.let { it.groupValues[2].ifEmpty { it.groupValues[3] } }

    /** powos-shell.json, or null when it isn't one (a file outside powos-shell/, no checksum: never applied). */
    fun parseShell(json: String): ShellBundle? {
        val stamp = field(json, "stamp")?.trim()?.split(Regex("\\s+")) ?: return null
        val time = stamp.getOrNull(0)?.toLongOrNull() ?: return null
        val commit = stamp.getOrNull(1)?.takeIf { it.matches(Regex("[0-9a-f]{7,40}")) } ?: return null
        val file = field(json, "file")?.takeIf { it.matches(Regex("powos-shell/[0-9a-f]{7,40}\\.zip")) } ?: return null
        val sha = field(json, "sha256")?.lowercase()?.takeIf { it.matches(Regex("[0-9a-f]{64}")) } ?: return null
        val size = field(json, "size")?.toLongOrNull() ?: return null
        return ShellBundle(time, commit, file, sha, size, field(json, "apk")?.toLongOrNull() ?: 0L)
    }

    /** powos.ver (the store's APK version code, android-app-dev's `make build`). */
    fun parseVersion(text: String): Long? = text.trim().takeIf { it.matches(Regex("[0-9]{1,12}")) }?.toLong()

    fun due(
        now: Long,
        lastOk: Long,
        lastTry: Long,
        force: Boolean,
    ): Boolean = force || (now - lastOk >= INTERVAL_MS && now - lastTry >= RETRY_MS)

    fun apkNewer(
        store: Long?,
        installed: Long,
    ): Boolean = store != null && store > installed

    /**
     * The bundle applies when it's newer than the shell served now (the APK's own or the shipped layer's, whichever is
     * newer - ShellSource) and the installed APK is at least the one it was published with (it may call native parts
     * that APK brought: the APK update comes first).
     */
    fun shellWanted(
        b: ShellBundle,
        servedTime: Long,
        installedApk: Long,
    ): Boolean = b.time > servedTime && installedApk >= b.apk

    /** A path from a bundle that may be written under files/shell: relative, no "..", no empty parts. */
    fun safePath(p: String): Boolean = p.isNotEmpty() && !p.startsWith("/") && p.split('/').none { it.isEmpty() || it == "." || it == ".." }

    /** The notification's text for one line of lib/phone-update.sh's output, null: keep the last one. */
    fun progress(line: String): String? {
        val l = line.trim()
        if (l == "#step packages") return "Updating Linux packages"
        if (l == "#step powos") return "Updating PowOS"
        STEP.find(l)?.let {
            val n = if (it.groupValues[1].isEmpty()) "" else " (${it.groupValues[1]}/${it.groupValues[2]})"
            return "Updating ${it.groupValues[4]}$n"
        }
        if (l.startsWith(":: Retrieving packages") || l.startsWith("downloading ")) return "Downloading Linux packages"
        return null
    }

    /** How many packages a run changed: pacman's "(i/n) upgrading x" lines, each package once. */
    fun changed(lines: List<String>): Int =
        lines.mapNotNull { STEP.find(it.trim())?.groupValues?.get(4) }.toSet().size

    /** The run's notification at the end, null: none (an automatic run that found nothing, or couldn't look). */
    fun summary(
        reached: Boolean,
        done: List<String>,
        force: Boolean,
    ): String? =
        when {
            !reached -> if (force) "Couldn't reach the PowOS store (home network or VPN)" else null
            done.isEmpty() -> if (force) "PowOS is up to date" else null
            else -> "Updated: ${done.joinToString(", ")}"
        }

    /** "3 Linux packages", null: none changed (or no Linux run). */
    fun packages(n: Int?): String? = n?.takeIf { it > 0 }?.let { "$it Linux package${if (it == 1) "" else "s"}" }

    /** Settings' line for a run's trouble, null: none. */
    fun error(
        reached: Boolean,
        linuxFailed: Boolean,
    ): String? =
        when {
            !reached -> "couldn't reach the PowOS store (home network or VPN)"
            linuxFailed -> "the Linux update didn't finish (see run/powos-update.log)"
            else -> null
        }

    /** A download's percentage, null: its size isn't known. */
    fun percent(
        got: Long,
        total: Long,
    ): Int? = if (total > 0) (got * 100 / total).toInt() else null

    /** pacman's "(2/3) upgrading kwin  [###]" on a terminal, "upgrading kwin..." without one (the app's pipe). */
    private val STEP = Regex("^(?:\\((\\d+)/(\\d+)\\) )?(upgrading|installing|reinstalling) ([A-Za-z0-9@._+-]+?)(?:\\.\\.\\.)?(?:\\s|$)")
}

/**
 * Pull updates for a phone no adb reaches (docs/PHONE-UPDATES.md): the S25 and the razr run PowOS without root, as their
 * launcher, and must get every change without a reinstall. Three parts, in this order, from the PowApps store:
 *  1. the APK - powos.ver newer than this one: downloaded and handed to PackageInstaller; Android asks the person
 *     (a notification to tap) unless the app is the installer of record and may update itself;
 *  2. the web shell - powos-shell.json newer than the shell served now: the bundle (sha256-checked) applied to the
 *     override layer exactly as a push (shell/push.sh) is - .pushing marker, files/shell-prev, files/shell-push.json,
 *     the layer's stamp - so HotReload, ShellSource and ShellErrors' rollback treat it as one ([ShellBundleApply]);
 *  3. Linux - lib/phone-update.sh in the PowOS image: its packages from the [powos] repo, PowOS's own code
 *     (powos-core) among them.
 * On the launcher's start (at most every [UpdatePlan.INTERVAL_MS]) and from Settings ("check"), with a progress
 * notification; never while a game runs. Rooted phones get all three from the ship service (tools/phone/ship.sh).
 */
object PowosUpdates {
    internal const val TAG = "PowosUpdates"
    private const val STATE = "powos-updates.txt"
    private const val ACTION_INSTALLED = "com.powos.app.action.UPDATE_INSTALLED"
    private val running = AtomicBoolean()

    /** What Settings' "system updates" card shows (Compose state: the screen's state flow follows it). */
    class Status {
        var checking by mutableStateOf(false)
            internal set
        var checkedAt by mutableStateOf<Long?>(null)
            internal set
        var error by mutableStateOf<String?>(null)
            internal set
    }

    private val status = Status()

    @Volatile private var loaded = false

    fun status(context: Context): Status {
        if (!loaded) {
            loaded = true
            readState(context).first.takeIf { it > 0 }?.let { status.checkedAt = it }
        }
        return status
    }

    private fun readState(context: Context): Pair<Long, Long> =
        runCatching { File(context.filesDir, STATE).readText().trim().split(' ').map { it.toLong() } }.getOrNull()?.takeIf { it.size == 2 }?.let { it[0] to it[1] } ?: (0L to 0L)

    /** Not on a rooted phone (the ship service updates it), and only one run at a time. */
    fun maybeRun(
        context: Context,
        force: Boolean = false,
    ) {
        if (RootedGuest.enabled) return
        val app = context.applicationContext
        if (!running.compareAndSet(false, true)) return
        Thread({
            try {
                run(app, force)
            } catch (t: Throwable) {
                Log.w(TAG, "update run failed", t)
            } finally {
                running.set(false)
            }
        }, "powos-updates").start()
    }

    private fun run(
        context: Context,
        force: Boolean,
    ) {
        val (lastOk, lastTry) = readState(context)
        val now = System.currentTimeMillis()
        if (!UpdatePlan.due(now, lastOk, lastTry, force)) return
        if (gameRunning(context)) {
            Log.i(TAG, "a game is running - no update now")
            return
        }
        val state = File(context.filesDir, STATE)
        state.writeText("$lastOk $now")
        status(context).checking = true
        try {
            val (reached, done) = runSteps(context)
            if (reached) {
                val at = System.currentTimeMillis()
                state.writeText("$at $now")
                status.checkedAt = at
            }
            val summary = UpdatePlan.summary(reached, done, force)
            Log.i(TAG, "run done: ${summary ?: "nothing new"}")
            if (summary == null) UpdateNotes.cancel(context) else UpdateNotes.finished(context, summary)
        } finally {
            status.checking = false
        }
    }

    /** The three steps: whether the store answered, and what changed. */
    private fun runSteps(context: Context): Pair<Boolean, List<String>> {
        val done = mutableListOf<String>()
        UpdateNotes.progress(context, "Checking for updates")
        val apk = runCatching { apk(context) }.onFailure { Log.i(TAG, "apk: $it") }
        if (apk.getOrNull() == true) done += "the app (tap to install)"
        val shell = runCatching { ShellBundleApply.run(context, installedVersion(context)) }.onFailure { Log.i(TAG, "shell: $it") }
        shell.getOrNull()?.let { done += it }
        val linux = runCatching { linux(context) }.onFailure { Log.i(TAG, "linux: $it") }.getOrNull()
        UpdatePlan.packages(linux)?.let { done += it }
        val reached = apk.isSuccess || shell.isSuccess
        status.error = UpdatePlan.error(reached, linuxFailed = linux == null && EngineGuest.enabled)
        return reached to done
    }

    /** A game in front (a web window's, or launched in the last 2 minutes): updates wait. lib/phone-update.sh checks too. */
    private fun gameRunning(context: Context): Boolean {
        if (runCatching { WebWindows.frontGame() }.getOrNull() != null) return true
        val marks = File(context.filesDir, "run/game-launch").listFiles().orEmpty()
        return marks.any { System.currentTimeMillis() - it.lastModified() < 120_000L }
    }

    internal fun installedVersion(context: Context): Long = context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode

    // ── 1. The APK ──────────────────────────────────────────────────────────────────────────────────────────────────

    /** Answers whether a newer APK was handed to the installer. */
    private fun apk(context: Context): Boolean {
        val store = UpdatePlan.parseVersion(String(Store.get("${UpdatePlan.STORE}/powos.ver")))
        val installed = installedVersion(context)
        if (!UpdatePlan.apkNewer(store, installed)) return false
        val file = File(context.cacheDir, "powos-update.apk")
        Store.download("${UpdatePlan.STORE}/powos.apk", file) { UpdateNotes.progress(context, "Downloading the PowOS app", it) }
        val info = context.packageManager.getPackageArchiveInfo(file.path, 0)
        if (info?.packageName != context.packageName || info.longVersionCode != store) {
            file.delete()
            error("store APK is ${info?.packageName} ${info?.longVersionCode}, not ${context.packageName} $store")
        }
        val id = install(context, file)
        Log.i(TAG, "apk $installed -> $store handed to the installer (session $id)")
        return true
    }

    private fun install(
        context: Context,
        file: File,
    ): Int {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply { setAppPackageName(context.packageName) }
        // Without asking when Android lets the installer of record update itself (Android 12+); else it asks.
        if (android.os.Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        val id = installer.createSession(params)
        installer.openSession(id).use { s ->
            s.openWrite("powos.apk", 0, file.length()).use { out ->
                file.inputStream().use { it.copyTo(out) }
                s.fsync(out)
            }
            val result = Intent(context, InstallResult::class.java).setAction(ACTION_INSTALLED)
            val pi = PendingIntent.getBroadcast(context, id, result, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            s.commit(pi.intentSender)
        }
        return id
    }

    /** The installer's answer: "needs the person" becomes a notification to tap (an app can't start it from the back). */
    class InstallResult : BroadcastReceiver() {
        override fun onReceive(
            context: Context,
            intent: Intent,
        ) {
            val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
            Log.i(TAG, "install status $status ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty()}")
            if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                val tap = PendingIntent.getActivity(context, 1, confirm, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                UpdateNotes.finished(context, "PowOS update ready - tap to install", tap)
            } else if (status != PackageInstaller.STATUS_SUCCESS) {
                File(context.cacheDir, "powos-update.apk").delete()
            }
        }
    }

    // ── 3. Linux ────────────────────────────────────────────────────────────────────────────────────────────────────

    /** Packages the run changed, null: no PowOS image here. */
    private fun linux(context: Context): Int? {
        if (!EngineGuest.enabled) return null
        UpdateNotes.progress(context, "Updating Linux packages")
        // An image without the updater yet: the session's own bootstrap, which installs powos-core (and with it the updater).
        val boot = andro.marchy.SessionPlan.packagesCommand().replace("exec >", ": >")
        val p = EngineGuest.process("if [ -f /usr/lib/powos/phone-update.sh ]; then exec sh /usr/lib/powos/phone-update.sh; else $boot; fi").start()
        p.outputStream.close()
        val lines = mutableListOf<String>()
        p.inputStream.bufferedReader().useLines { seq ->
            seq.forEach { l ->
                lines += l
                UpdatePlan.progress(l)?.let { UpdateNotes.progress(context, it) }
            }
        }
        if (!p.waitFor(20, TimeUnit.MINUTES)) p.destroy()
        runCatching { File(context.filesDir, "run/powos-update.log").writeText(lines.takeLast(400).joinToString("\n")) }
        check(lines.none { it.trim() == "#done fail" }) { "phone-update failed: ${lines.takeLast(3)}" }
        return UpdatePlan.changed(lines)
    }
}

/**
 * Step 2: the store's shell bundle into the override layer, as shell/push.sh puts a push there (files/shell-push.json,
 * files/shell-prev, the layer's stamp, the .pushing marker HotReload holds changes behind), so a page that won't boot
 * on it is rolled back by ShellErrors like any push.
 */
internal object ShellBundleApply {
    /** Answers what was applied ("the home screen"), null: nothing newer. */
    fun run(
        context: Context,
        installedApk: Long,
    ): String? {
        val b = UpdatePlan.parseShell(String(Store.get("${UpdatePlan.STORE}/powos-shell.json"))) ?: return null
        if (!UpdatePlan.shellWanted(b, ShellSource.servedTime(context), installedApk)) return null
        val zip = File(context.cacheDir, "powos-shell.zip")
        Store.download("${UpdatePlan.STORE}/${b.file}", zip) { UpdateNotes.progress(context, "Downloading the PowOS home screen", it) }
        if (Store.sha256(zip) != b.sha256 || zip.length() != b.size) {
            zip.delete()
            error("shell bundle ${b.file}: checksum or size mismatch")
        }
        val staging = File(context.filesDir, "shell-staging-ota").apply { deleteRecursively() }
        val names = try { unpack(zip, staging) } finally { zip.delete() }
        val overrides = File(context.filesDir, "shell").apply { mkdirs() }
        // Only what differs from what the phone would serve once this layer wins (its override, else the APK's file);
        // an override the bundle doesn't have goes (it would shadow the new shell) - kept in shell-prev for the rollback.
        val changed = names.filter { differs(context, File(overrides, it), File(staging, it), it) }
        val stale = overrides.walkTopDown().filter { it.isFile }.map { it.relativeTo(overrides).path }.filter { it != ".pushing" && it !in names }.toList()
        try {
            apply(context, b, staging, Changes(changed, stale))
        } finally {
            staging.deleteRecursively()
        }
        Log.i(PowosUpdates.TAG, "shell ${b.commit.take(9)}: ${changed.size} file(s) changed, ${stale.size} stale override(s) removed")
        return if (changed.isEmpty() && stale.isEmpty()) null else "the home screen"
    }

    /** The bundle's files that differ from what's served ([changed]) and the overrides it doesn't have ([stale]). */
    private class Changes(
        val changed: List<String>,
        val stale: List<String>,
    ) {
        val touched get() = changed + stale
    }

    private fun unpack(
        zip: File,
        to: File,
    ): List<String> {
        to.mkdirs()
        val names = mutableListOf<String>()
        ZipInputStream(zip.inputStream().buffered()).use { z ->
            generateSequence { z.nextEntry }.filter { !it.isDirectory }.forEach { e ->
                val name = e.name.removePrefix("./")
                check(UpdatePlan.safePath(name)) { "shell bundle: refused path $name" }
                File(to, name).apply { parentFile?.mkdirs() }.outputStream().use { z.copyTo(it) }
                names += name
            }
        }
        return names
    }

    private fun differs(
        context: Context,
        override: File,
        incoming: File,
        name: String,
    ): Boolean {
        val now = override.takeIf { it.isFile }?.readBytes() ?: runCatching { context.assets.open("shell/$name").use { it.readBytes() } }.getOrNull()
        return now == null || !now.contentEquals(incoming.readBytes())
    }

    private fun apply(
        context: Context,
        b: UpdatePlan.ShellBundle,
        staging: File,
        c: Changes,
    ) {
        val (changed, stale, touched) = Triple(c.changed, c.stale, c.touched)
        val files = context.filesDir
        val overrides = File(files, "shell")
        val prev = File(files, "shell-prev").apply { deleteRecursively(); mkdirs() }
        val manifest = JSONObject().put("at", System.currentTimeMillis() / 1000).put("files", JSONArray(touched)).put("note", "PowOS update").put("from", "store").put("test", false).put("silent", true)
        File(files, "shell-push.json").writeText(manifest.toString())
        File(files, ShellSource.LAYER_STAMP).writeText("${b.time} ${b.commit}\n")
        val marker = File(overrides, ".pushing").apply { writeText("\n") }
        try {
            touched.forEach { n ->
                val target = File(overrides, n)
                if (target.isFile) target.copyTo(File(prev, n), overwrite = true)
                if (n in stale) target.delete() else moveIn(File(staging, n), target)
            }
        } finally {
            marker.delete()
        }
        // Each file's commit, as push.sh records it (its "newer than your base" check on the next push).
        File(files, "shell-commits.txt").appendText(changed.joinToString("") { "$it ${b.commit}\n" })
    }

    private fun moveIn(
        from: File,
        to: File,
    ) {
        to.parentFile?.mkdirs()
        if (!from.renameTo(to)) from.copyTo(to, overwrite = true)
    }
}

/** The store over HTTP (LAN/VPN only). */
internal object Store {
    fun get(url: String): ByteArray = dev.omalauncher.httpGet(url, connectTimeout = 4_000, readTimeout = 15_000)

    /** [url] into [to] (through a .part file), its percentage to [onPercent] every 5 %. */
    fun download(
        url: String,
        to: File,
        onPercent: (Int?) -> Unit,
    ) {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 4_000
        c.readTimeout = 30_000
        c.useCaches = false
        try {
            check(c.responseCode == 200) { "HTTP ${c.responseCode} for $url" }
            val total = c.contentLengthLong
            val part = File(to.path + ".part")
            val got = c.inputStream.use { input -> part.outputStream().use { out -> pump(input, out, total, onPercent) } }
            check(total <= 0 || got == total) { "short download: $got of $total bytes" }
            check(part.renameTo(to)) { "can't move $part" }
        } finally {
            c.disconnect()
        }
    }

    private fun pump(
        input: java.io.InputStream,
        out: java.io.OutputStream,
        total: Long,
        onPercent: (Int?) -> Unit,
    ): Long {
        val buf = ByteArray(65536)
        var got = 0L
        var shown = -5
        while (true) {
            val n = input.read(buf)
            if (n < 0) return got
            out.write(buf, 0, n)
            got += n
            val pct = UpdatePlan.percent(got, total) ?: continue
            if (pct - shown >= 5) {
                shown = pct
                onPercent(pct)
            }
        }
    }

    fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { s -> DigestInputStream(s, md).use { it.copyTo(java.io.OutputStream.nullOutputStream()) } }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}

/** The one "PowOS updates" notification: progress while a run works, its result after. */
internal object UpdateNotes {
    private const val CHANNEL = "powos-updates"
    private const val ID = 0x5057

    fun progress(
        context: Context,
        text: String,
        percent: Int? = null,
    ) = post(context, builder(context, text).setOngoing(true).setProgress(100, percent ?: 0, percent == null))

    fun finished(
        context: Context,
        text: String,
        tap: PendingIntent? = null,
    ) = post(context, builder(context, text).setAutoCancel(true).apply { tap?.let(::setContentIntent) })

    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(ID)
    }

    private fun builder(
        context: Context,
        text: String,
    ): Notification.Builder {
        context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(NotificationChannel(CHANNEL, "PowOS updates", NotificationManager.IMPORTANCE_LOW))
        return Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_notification).setContentTitle(text).setOnlyAlertOnce(true)
    }

    private fun post(
        context: Context,
        b: Notification.Builder,
    ) {
        runCatching { context.getSystemService(NotificationManager::class.java)?.notify(ID, b.build()) }
    }
}

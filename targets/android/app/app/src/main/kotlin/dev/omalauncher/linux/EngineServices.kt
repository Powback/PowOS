package dev.omalauncher.linux

import android.content.Context
import android.util.Log
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption

/**
 * PowOS's system services on a phone without root: SpacetimeDB (127.0.0.1:3410, every PowOS app's database) and the
 * App API runtime (127.0.0.1:3411), started in the PowOS image through [EngineGuest] - on a rooted phone the rooted
 * session's powos-supervisor runs them (rooted/powos-start.sh), and without root nothing did, so every island whose app
 * keeps its data in SpacetimeDB had none (docs/research/nonroot-parity.md #2). The starter is the APK's
 * assets/powos-noroot-services (lib/apps/powos-noroot-services, the same version as the APK): it reads the image's
 * service manifests, starts what isn't listening, and publishes the APK's apps' modules ([dev.omalauncher.shell.LocalApps]).
 *
 * Kicked by Runtime.onEngineReady and again by [state] while SpacetimeDB doesn't answer (at most every [RETRY_MS]).
 */
object EngineServices {
    private const val TAG = "EngineServices"
    private const val RETRY_MS = 30_000L
    private const val STDB_PORT = 3410

    @Volatile private var lastStart = 0L

    @Volatile private var running = false

    /**
     * Where SpacetimeDB stands without root (shell/apps/localapps.ts StdbState): "image" - the PowOS image isn't on the
     * phone; "missing" - it is, without SpacetimeDB; "up" - it answers; "starting" otherwise (and a start is kicked).
     * Blocking (a Unix socket connect): never on the main thread.
     */
    fun state(ctx: Context): String {
        val image = andro.marchy.SessionService.rootfsReady(ctx)
        val has = image && present(andro.marchy.SessionService.rootfs(ctx), "usr/bin/spacetimedb-standalone")
        // SpacetimeDB's socket (no TCP port without root: LoopbackGate), and the gate the page reaches it through.
        if (has) LoopbackGate.ensure(ctx)
        val up = has && LoopbackGate.up(ctx, STDB_PORT)
        val s = stateOf(image, has, up)
        if (s == "starting") start(ctx)
        return s
    }

    /** [state]'s rule, pure (EngineServicesTest). */
    fun stateOf(
        image: Boolean,
        hasStdb: Boolean,
        up: Boolean,
    ): String =
        when {
            !image -> "image"
            !hasStdb -> "missing"
            up -> "up"
            else -> "starting"
        }

    /** Starts the services in the image (a background thread; once at a time, at most every [RETRY_MS]). */
    fun start(ctx: Context) {
        if (!EngineGuest.enabled || running) return
        val now = System.currentTimeMillis()
        if (now - lastStart < RETRY_MS) return
        lastStart = now
        running = true
        val app = ctx.applicationContext
        Thread({
            try {
                run(app)
            } catch (e: Exception) {
                Log.w(TAG, "starting the services failed", e)
            } finally {
                running = false
            }
        }, "engine-services").start()
    }

    private fun run(ctx: Context) {
        // The modules where the guest sees them as they are: the session's run dir is passed through (ARCH_EXCLUDE_EXTRA).
        val bundled = File(andro.marchy.SessionService.runDir(ctx), "powos-bundled").apply { mkdirs() }
        val want = dev.omalauncher.shell.LocalApps.modules(ctx)
        bundled.listFiles()?.filter { it.name.removeSuffix(".wasm") !in want }?.forEach { it.delete() }
        for ((db, asset) in want) ctx.assets.open(asset).use { i -> File(bundled, "$db.wasm").outputStream().use { i.copyTo(it) } }
        val script = File(andro.marchy.SessionService.runDir(ctx), "powos-noroot-services")
        ctx.assets.open("powos-noroot-services").use { i -> script.outputStream().use { i.copyTo(it) } }
        val p = EngineGuest.process("PATH=/usr/bin:/usr/sbin:/bin exec /usr/bin/python3 '${script.path}' '${bundled.path}'").start()
        val out = p.inputStream.bufferedReader().readText()
        Log.i(TAG, "services (rc ${p.waitFor()}): ${out.trim().replace('\n', ';')}")
    }

    /** A file of the image, a symlink too (its target is absolute inside the image: not resolvable from here). */
    private fun present(
        root: File,
        path: String,
    ) = Files.exists(File(root, path).toPath(), LinkOption.NOFOLLOW_LINKS)
}

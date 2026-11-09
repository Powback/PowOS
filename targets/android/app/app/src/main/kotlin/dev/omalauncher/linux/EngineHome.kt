package dev.omalauncher.linux

import android.util.Log
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path

/**
 * The launcher's own dirs where a program of the no-root PowOS image looks for them (gh#13). The launcher reads
 * widgets from files/widgets and PowOS apps from files/apps ([dev.omalauncher.shell.LocalApps]); inside the image
 * (lotfix-run, fakechroot - no bind mounts without root) those were nowhere: `powos app install` wrote
 * ~/.local/share/powos/apps inside the rootfs, which the launcher never sees, and ~/.config/omalauncher/widgets (the
 * widget README's path, owl-check's) didn't exist. Rooted, powos-session.sh binds them; Omalauncher's proot binds
 * them too ([Proot] dataBinds). Here they are symlinks from the image's home to the app's files - SessionService
 * passes both dirs through fakechroot (ARCH_EXCLUDE_EXTRA), so a link's absolute target resolves for every program.
 *
 * Also the widget tools (owl-check, owl-send, owl-recon) in the image's /usr/local/bin, as [dev.omalauncher.widgets.WidgetEngine.guestManaged]
 * puts them in the proot guest, which PowOS never installs.
 *
 * Run by Runtime.onEngineReady, each time (idempotent; cheap).
 */
object EngineHome {
    private const val TAG = "EngineHome"

    /** The tools the widget README tells agents to run, from the APK's assets (`<name>.sh`). */
    val TOOLS = listOf("owl-check", "owl-send", "owl-recon")

    /** Guest path (relative to the rootfs) to the app's dir it must be. */
    fun links(filesDir: File): List<Pair<String, File>> =
        listOf(
            "root/.config/omalauncher/widgets" to File(filesDir, "widgets"),
            "root/.local/share/powos/apps" to File(filesDir, "apps"),
        )

    /** The links and tools in [rootfs]; what it did, for the log. */
    fun apply(
        rootfs: File,
        filesDir: File,
        tool: (String) -> ByteArray?,
    ): List<String> {
        val out = mutableListOf<String>()
        for ((rel, target) in links(filesDir)) runCatching { link(rootfs, rel, target)?.let(out::add) }.onFailure { out.add("$rel: ${it.message}") }
        for (name in TOOLS) {
            val bytes = tool(name) ?: continue
            val f = File(rootfs, "usr/local/bin/$name")
            if (f.isFile && f.readBytes().contentEquals(bytes)) continue
            f.parentFile?.mkdirs()
            f.writeBytes(bytes)
            f.setExecutable(true, false)
            out.add("usr/local/bin/$name")
        }
        if (out.isNotEmpty()) Log.i(TAG, out.joinToString("; "))
        return out
    }

    /**
     * [rootfs]/[rel] becomes a symlink to [target]. A real dir there (apps installed before this) has its entries moved
     * into [target] first - never deleted: one [target] already has stays where it was, the dir renamed aside.
     * Null when it was already right.
     */
    fun link(
        rootfs: File,
        rel: String,
        target: File,
    ): String? {
        val p: Path = File(rootfs, rel).toPath()
        target.mkdirs()
        if (Files.isSymbolicLink(p)) {
            if (Files.readSymbolicLink(p).toString() == target.path) return null
            Files.delete(p)
        } else if (Files.isDirectory(p, LinkOption.NOFOLLOW_LINKS)) {
            val dir = p.toFile()
            for (entry in dir.listFiles().orEmpty()) {
                val dest = File(target, entry.name)
                if (!dest.exists()) entry.renameTo(dest)
            }
            if (!dir.delete()) {
                val aside = File(dir.parentFile, "${dir.name}.before-link")
                if (!dir.renameTo(aside)) return "$rel: a dir in the way, kept"
            }
        } else if (Files.exists(p, LinkOption.NOFOLLOW_LINKS)) {
            Files.delete(p)
        }
        p.parent?.let { Files.createDirectories(it) }
        Files.createSymbolicLink(p, target.toPath())
        return "$rel -> ${target.path}"
    }
}

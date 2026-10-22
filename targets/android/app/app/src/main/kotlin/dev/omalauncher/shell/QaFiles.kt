package dev.omalauncher.shell

import java.io.File

/**
 * Review images for PowOS AI's page (the work board's --image: PowOS's /home/powos/design-qa), served by ShellHost at
 * /_qa/<name>. A security boundary: the page names a file, the app reads it - so only a bare name of one folder.
 *  - [resolve]: the name as the URL has it, never decoded (no %2F / %2e%2e variants): [NAME] and no "..", then the file
 *    canonicalized (symlinks followed) and kept only if it is directly inside the folder.
 *  - [SYNC]: PowOS's files carry a label the app's domain may not read, so the root shell refreshes a copy of the
 *    folder's PNG/JPG files (no symlinks, no subfolders) into the app's cache - one fixed command, no name in it.
 */
object QaFiles {
    const val DIR = "/data/powos/root/home/powos/design-qa"
    private val NAME = Regex("^[A-Za-z0-9._-]+\\.(png|jpg)$")

    /** The file [raw] names directly inside [dir], or null. */
    fun resolve(dir: File, raw: String): File? {
        if (!NAME.matches(raw) || raw.contains("..")) return null
        val base = runCatching { dir.canonicalFile }.getOrNull() ?: return null
        val file = runCatching { File(base, raw).canonicalFile }.getOrNull() ?: return null
        return file.takeIf { it.parentFile == base && it.isFile }
    }

    /** The root shell's copy of [DIR] into [cache]: fixed (only [cache], the app's own path, is put in, quoted). */
    fun sync(cache: File): String {
        val to = cache.path
        require(Regex("^[A-Za-z0-9/._-]+$").matches(to)) { "unexpected cache path" }
        return "mkdir -p '$to' && for f in $DIR/*.png $DIR/*.jpg; do [ -f \"\$f\" ] && [ ! -L \"\$f\" ] && " +
            "cp -p \"\$f\" '$to'/ ; done; chmod 644 '$to'/* 2>/dev/null; true"
    }
}

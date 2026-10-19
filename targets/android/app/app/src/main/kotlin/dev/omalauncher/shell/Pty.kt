package dev.omalauncher.shell

/** JNI bindings, see cpp/pty.c. */
object Pty {
    init {
        System.loadLibrary("pty")
    }

    /**
     * Starts [argv] (argv[0] a full path) in [cwd] with exactly [env] on a new pty of [rows] x [cols]: the master's fd,
     * or -errno; [pid] gets the process.
     */
    @JvmStatic external fun spawn(cwd: String, argv: Array<String>, env: Array<String>, rows: Int, cols: Int, pid: IntArray): Int

    @JvmStatic external fun resize(fd: Int, rows: Int, cols: Int)

    /** Blocks until [pid] ends: its exit status, or -signal. */
    @JvmStatic external fun waitFor(pid: Int): Int
}

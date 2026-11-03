package dev.omalauncher.linux

/**
 * The launcher's PowOS Linux, whichever way this phone has it - the one choice every PowOS call site makes (AI chat,
 * agent mail, comms, terminals, the app list, app and game launches), the same one widgets make ([guestProcess]):
 *
 *  - [Kind.ROOTED]: the PowOS session itself, through `su` ([RootedGuest]); every call delegates to it unchanged.
 *  - [Kind.ENGINE]: no root, the PowOS image the engine installed ([EngineGuest]: lotfix-run into the app's rootfs,
 *    the same way in as the engine's own session programs, andro.marchy.SessionService).
 *  - [Kind.NONE]: neither - [unavailable] says what's missing; callers show it instead of failing silently.
 *
 * Omalauncher's proot Arch (the widgets' third choice) is never installed under PowOS, so it isn't one here.
 * Things that need root by nature (Android settings, game boost, the system theme) keep [RootedGuest.enabled].
 */
object Guest {
    enum class Kind { ROOTED, ENGINE, NONE }

    /** Tests: the kind to report instead of the phone's. */
    @Volatile internal var override: Kind? = null

    /** The pick: root wins (the session is the real PowOS), else the installed image. */
    fun pick(
        rooted: Boolean,
        engine: Boolean,
    ): Kind =
        when {
            rooted -> Kind.ROOTED
            engine -> Kind.ENGINE
            else -> Kind.NONE
        }

    val kind: Kind get() = override ?: pick(RootedGuest.enabled, EngineGuest.enabled)

    /** PowOS Linux is there to run in, rooted or not. */
    val enabled: Boolean get() = kind != Kind.NONE

    /** Why PowOS Linux isn't there (null when it is): for a call site's "needs ..." state. */
    fun unavailable(): String? = if (enabled) null else NEEDS_IMAGE

    /** Shown wherever PowOS Linux is needed and neither root nor the image is there. */
    const val NEEDS_IMAGE = "needs the PowOS Linux image - open PowOS to download it (no root needed)"

    /** A shell command line in PowOS, stderr merged into stdout unless not [mergeErrors]. */
    fun process(
        command: String,
        mergeErrors: Boolean = true,
    ): ProcessBuilder =
        when (kind) {
            Kind.ROOTED -> RootedGuest.process(command, mergeErrors)
            else -> EngineGuest.process(command, mergeErrors)
        }

    /** Blocking, each output line to [onLine]; the exit code. Rooted: the app's one root shell ([RootedGuest.run]). */
    fun run(
        command: String,
        onLine: (String) -> Unit = {},
    ): Int =
        when (kind) {
            Kind.ROOTED -> RootedGuest.run(command, onLine)
            else -> own(command, onLine)
        }

    /** Like [run], in a process of its own (a command that runs a while and ends). */
    fun runOwn(
        command: String,
        onLine: (String) -> Unit = {},
    ): Int =
        when (kind) {
            Kind.ROOTED -> RootedGuest.runOwn(command, onLine)
            else -> own(command, onLine)
        }

    /** A program that runs on (an app, a game): off the app's pipes, see [RootedGuest.launch]. */
    fun launch(
        name: String,
        command: String,
        onLine: (String) -> Unit = {},
    ): Int =
        when (kind) {
            Kind.ROOTED -> RootedGuest.launch(name, command, onLine)
            else -> own(RootedGuest.launchCommand(name, command), onLine)
        }

    /** A PowOS app as its own Android task, or on the desktop ([showDesktop]); see [RootedGuest.openAsTask]. */
    fun openAsTask(
        appId: String,
        wmClass: String?,
        exec: String,
        showDesktop: () -> Unit,
        onLine: (String) -> Unit = {},
    ): Int =
        when (kind) {
            Kind.ROOTED -> RootedGuest.openAsTask(appId, wmClass, exec, showDesktop, onLine)
            else ->
                own(RootedGuest.openTaskCommand(appId, wmClass, exec)) { line ->
                    if (line == RootedGuest.OPEN_DESKTOP) showDesktop()
                    onLine(line)
                }
        }

    /** The terminal PowOS opens everywhere: its tmux picker (rooted: always deployed; the image: if it has it). */
    val terminalShell: String get() = if (kind == Kind.ROOTED) RootedGuest.TERMINAL_SHELL else ENGINE_TERMINAL_SHELL

    /** The image's terminal: PowOS's tmux picker where the image has it, else a login shell. */
    const val ENGINE_TERMINAL_SHELL =
        "if [ -x ${RootedGuest.TERMINAL_SHELL} ]; then exec ${RootedGuest.TERMINAL_SHELL}; else exec bash -l; fi"

    /** What a terminal's pty runs for [command] (null: [terminalShell]): executable, argv (argv[0] first), environment. */
    data class Terminal(
        val executable: String,
        val argv: List<String>,
        val env: Map<String, String>,
    )

    fun terminal(
        command: String?,
        extraEnv: Map<String, String>,
    ): Terminal {
        val cmd = command ?: terminalShell
        if (kind == Kind.ROOTED) {
            return Terminal("/system/bin/sh", listOf("sh", "-c", rootedTerminalLine(cmd)), System.getenv() + extraEnv)
        }
        val pb = EngineGuest.process(cmd)
        return Terminal(pb.command()[0], pb.command(), pb.environment() + extraEnv)
    }

    /** Rooted: the `sh -c` line a terminal's pty runs (su into the session). */
    fun rootedTerminalLine(command: String) = "exec su -c " + shellQuote(RootedGuest.rootCommand(command))

    private fun own(
        command: String,
        onLine: (String) -> Unit,
    ): Int {
        val process = EngineGuest.process(command).start()
        process.inputStream.bufferedReader().forEachLine(onLine)
        return process.waitFor()
    }
}

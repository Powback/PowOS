package dev.omalauncher.system

/**
 * The decisions behind [DefaultKeyboard], with no Android in them (KeyboardPlanTest): which published build to take,
 * whether a downloaded APK passes the gate, and what to do about the default keyboard.
 */
object KeyboardPlan {
    /** The version to install: the published one when it's newer than what's installed and hasn't failed before. */
    fun target(
        installed: Long?,
        published: Long?,
        failed: Set<Long>,
    ): Long? {
        if (published == null || published <= 0) return null
        if (published in failed) return null
        // Upgrades only: a store that went back (a stale publish) never downgrades the phone.
        if (installed != null && installed >= published) return null
        return published
    }

    /** The published version from the store's `<project>.ver` sidecar (one number), or null if it isn't one. */
    fun parseVersion(text: String?): Long? = text?.trim()?.toLongOrNull()?.takeIf { it > 0 }

    /**
     * Why a downloaded APK is refused, or null when it passes: it must be the keyboard's package at exactly the
     * advertised version, declare the input method service, and (when the keyboard is installed) be signed by the
     * same key - Android would refuse that update anyway, the gate just says why before trying.
     */
    fun gate(
        apk: Archive,
        expected: Long,
    ): String? =
        when {
            apk.packageName != DefaultKeyboard.PACKAGE -> "not the keyboard's package (${apk.packageName})"
            apk.versionCode != expected -> "version ${apk.versionCode}, the store advertised $expected"
            !apk.hasImeService -> "no input method service in it"
            apk.signerMatches == false -> "signed by another key than the installed keyboard"
            else -> null
        }

    /** What [gate] reads of a downloaded APK; [signerMatches] null when the keyboard isn't installed yet. */
    data class Archive(val packageName: String?, val versionCode: Long, val hasImeService: Boolean, val signerMatches: Boolean?)

    /**
     * The phone's keyboard state: installed or not, Settings.Secure.ENABLED_INPUT_METHODS ([enabled], `a/.X:b/.Y;subtype`)
     * and DEFAULT_INPUT_METHOD ([current]), whether the default was handled once already ([done]) and whether PowOS may
     * write secure settings ([canWrite]).
     */
    data class State(val installed: Boolean, val enabled: String?, val current: String?, val done: Boolean, val canWrite: Boolean)

    sealed interface Default {
        /** Nothing to do: already the default, not installed yet, or done once before (the user's choice since). */
        data object None : Default

        /** Write these secure settings (PowOS holds WRITE_SECURE_SETTINGS: the rooted phone's priv-app, or granted). */
        data class Write(val enabled: String, val default: String) : Default

        /** No permission to write them: ask the user once, through Android's keyboard settings. */
        data object Ask : Default
    }

    /** What to do about the default keyboard. Once per phone (done): after that a different keyboard is the user's choice and stays. */
    fun default(s: State): Default {
        if (!s.installed || s.done) return Default.None
        if (isIme(s.current)) return Default.None
        return if (s.canWrite) Default.Write(withIme(s.enabled), DefaultKeyboard.IME) else Default.Ask
    }

    /** ENABLED_INPUT_METHODS with the keyboard in it (kept as is when it already is). */
    fun withIme(enabled: String?): String {
        val entries = enabled.orEmpty().split(':').filter { it.isNotBlank() }
        if (entries.any { isIme(it.substringBefore(';')) }) return entries.joinToString(":")
        return (entries + DefaultKeyboard.IME).joinToString(":")
    }

    /** Whether an input method id is the keyboard's (the short `pkg/.Cls` or the full `pkg/pkg.Cls` form). */
    fun isIme(id: String?): Boolean =
        id == DefaultKeyboard.IME || id == "${DefaultKeyboard.PACKAGE}/${DefaultKeyboard.PACKAGE}${DefaultKeyboard.IME.substringAfter('/')}"
}

package dev.omalauncher.shell

import org.json.JSONObject

/**
 * Whether a saved fps-meter trace (perf.save's JSON) is mailed to the coordinator: a user's recording yes, a check's
 * (source "verify": tools/phone/verify/perf-scenarios.sh marks its recordings, shell/ui/fpsmeter.tsx takeSource) no -
 * f428: the check's recordings came in as the user's perf reports and the manager filed follow-up work on them.
 * Unreadable JSON or no source = a user's (as before the mark existed).
 */
internal fun perfMailWanted(json: String): Boolean =
    runCatching { JSONObject(json).optString("source") != "verify" }.getOrDefault(true)

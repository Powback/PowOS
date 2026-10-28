package dev.omalauncher.shell

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.changes.Change
import androidx.health.connect.client.changes.DeletionChange
import androidx.health.connect.client.changes.UpsertionChange
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.request.ChangesTokenRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import kotlin.reflect.KClass

/**
 * The health central's Android side ("health.*" bridge calls; docs/app-to-widget.md, apps/health): Health Connect, the
 * aggregator most wearable apps write to, read-only. Nothing is written back and nothing leaves the phone from here.
 *
 *  - `health.status`  -> { state: "ok" | "update" | "none", granted: [type], missing: [type] }
 *  - `health.grant`   -> status, after Health Connect's own permission dialog (shown over PowOS; once per grant)
 *  - `health.read` (types, sinceMs, untilMs?) -> [ { id, type, start, end, value, unit, source } ] - times Unix ms,
 *    [source] the package of the app that wrote it (the wearable's), [id] stable for upserts
 *  - `health.token` (types) -> { token } to start polling from; `health.changes` (types, token) ->
 *    { token, records, deleted: [id], expired } - only what changed since, so polling is cheap
 *
 * Types: steps, heart_rate, sleep, exercise, weight, active_calories. Values: count, bpm, min (a session's length),
 * min, kg, kcal. Heart rate is one record per sample (start = end).
 */
class HealthConnectBridge(
    private val context: Context,
    private val activity: Activity?,
    private val scope: CoroutineScope,
) {
    private val types: Map<String, KClass<out Record>> =
        linkedMapOf(
            "steps" to StepsRecord::class,
            "heart_rate" to HeartRateRecord::class,
            "sleep" to SleepSessionRecord::class,
            "exercise" to ExerciseSessionRecord::class,
            "weight" to WeightRecord::class,
            "active_calories" to ActiveCaloriesBurnedRecord::class,
        )

    /** A grant waiting for Health Connect's dialog to close ([onActivityResult]). */
    private var pendingGrant: ((Any?, String?) -> Unit)? = null

    /** Runs one "health.*" call; [done] gets the answer or the reason, on any thread. */
    fun call(
        method: String,
        a: JSONArray,
        done: (Any?, String?) -> Unit,
    ) {
        scope.launch {
            try {
                when (method) {
                    "health.status" -> done(status(), null)
                    "health.grant" -> grant(done)
                    "health.read" -> done(read(typesOf(a.optJSONArray(0)), a.getLong(1), if (a.isNull(2)) System.currentTimeMillis() else a.getLong(2)), null)
                    "health.token" -> done(JSONObject().put("token", client().getChangesToken(ChangesTokenRequest(classesOf(typesOf(a.optJSONArray(0)))))), null)
                    "health.changes" -> done(changes(typesOf(a.optJSONArray(0)), a.getString(1)), null)
                    else -> done(null, "no such call: $method")
                }
            } catch (e: Exception) {
                Log.w(TAG, "$method failed", e)
                done(null, e.message ?: e.toString())
            }
        }
    }

    private fun typesOf(list: JSONArray?): List<String> {
        val wanted = if (list == null || list.length() == 0) types.keys.toList() else (0 until list.length()).map { list.getString(it) }
        wanted.firstOrNull { it !in types }?.let { throw IllegalArgumentException("unknown health type $it (${types.keys.joinToString()})") }
        return wanted
    }

    private fun classesOf(wanted: List<String>): Set<KClass<out Record>> = wanted.map { types.getValue(it) }.toSet()

    private fun client(): HealthConnectClient {
        check(HealthConnectClient.getSdkStatus(context) == HealthConnectClient.SDK_AVAILABLE) { "Health Connect isn't available on this phone" }
        return HealthConnectClient.getOrCreate(context)
    }

    private suspend fun status(): JSONObject {
        val sdk =
            when (HealthConnectClient.getSdkStatus(context)) {
                HealthConnectClient.SDK_AVAILABLE -> "ok"
                HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> "update"
                else -> "none"
            }
        val granted = JSONArray()
        val missing = JSONArray()
        val have = if (sdk == "ok") client().permissionController.getGrantedPermissions() else emptySet()
        for ((name, cls) in types) (if (HealthPermission.getReadPermission(cls) in have) granted else missing).put(name)
        return JSONObject().put("state", sdk).put("granted", granted).put("missing", missing)
    }

    /** Shows Health Connect's permission dialog over PowOS when something is missing; answers the status after it. */
    private suspend fun grant(done: (Any?, String?) -> Unit) {
        val s = status()
        if (s.getString("state") != "ok" || s.getJSONArray("missing").length() == 0) return done(s, null)
        val asker = activity ?: return done(null, "Health Connect can only be asked from the PowOS app's own window")
        val want = types.values.map { HealthPermission.getReadPermission(it) }.toSet()
        pendingGrant?.invoke(null, "another request replaced this one")
        pendingGrant = done
        @Suppress("DEPRECATION")
        asker.startActivityForResult(PermissionController.createRequestPermissionResultContract().createIntent(context, want), REQUEST)
    }

    /** The dialog closed ([ShellActivity.onActivityResult]): what is granted now, whatever the user chose. */
    fun onActivityResult(
        requestCode: Int,
        @Suppress("UNUSED_PARAMETER") resultCode: Int,
        @Suppress("UNUSED_PARAMETER") data: Intent?,
    ) {
        if (requestCode != REQUEST) return
        val waiting = pendingGrant ?: return
        pendingGrant = null
        scope.launch { runCatching { status() }.fold({ waiting(it, null) }, { waiting(null, it.message ?: it.toString()) }) }
    }

    private suspend fun read(
        wanted: List<String>,
        since: Long,
        until: Long,
    ): JSONArray {
        val c = client()
        val out = JSONArray()
        val range = TimeRangeFilter.between(Instant.ofEpochMilli(since), Instant.ofEpochMilli(until))
        for (name in wanted) readType(c, types.getValue(name), range, out)
        return out
    }

    private suspend fun readType(
        c: HealthConnectClient,
        type: KClass<out Record>,
        range: TimeRangeFilter,
        out: JSONArray,
    ) {
        var page: String? = null
        do {
            val r = c.readRecords(ReadRecordsRequest(type, range, pageSize = PAGE, pageToken = page, ascendingOrder = true))
            r.records.forEach { rec -> normalise(rec).forEach { out.put(it) } }
            page = r.pageToken?.takeIf { it.isNotEmpty() && r.records.isNotEmpty() }
        } while (page != null)
    }

    private suspend fun changes(
        wanted: List<String>,
        start: String,
    ): JSONObject {
        val c = client()
        val records = JSONArray()
        val deleted = JSONArray()
        var token = start
        do {
            val r = c.getChanges(token)
            if (r.changesTokenExpired) {
                // Older than Health Connect keeps (about 30 days): the caller reads since its last sample, then goes on from this.
                val fresh = c.getChangesToken(ChangesTokenRequest(classesOf(wanted)))
                return JSONObject().put("token", fresh).put("records", JSONArray()).put("deleted", JSONArray()).put("expired", true)
            }
            r.changes.forEach { take(it, records, deleted) }
            token = r.nextChangesToken
        } while (r.hasMore)
        return JSONObject().put("token", token).put("records", records).put("deleted", deleted).put("expired", false)
    }

    private fun take(
        ch: Change,
        records: JSONArray,
        deleted: JSONArray,
    ) {
        when (ch) {
            is UpsertionChange -> normalise(ch.record).forEach { records.put(it) }
            is DeletionChange -> deleted.put(ch.recordId)
        }
    }

    private fun base(
        rec: Record,
        id: String,
        type: String,
        unit: String,
    ) = JSONObject().put("id", id).put("type", type).put("unit", unit).put("source", rec.metadata.dataOrigin.packageName)

    private fun JSONObject.span(
        start: Instant,
        end: Instant,
        value: Double,
    ): JSONObject = put("start", start.toEpochMilli()).put("end", end.toEpochMilli()).put("value", value)

    private fun minutes(
        a: Instant,
        b: Instant,
    ) = (b.toEpochMilli() - a.toEpochMilli()) / 60_000.0

    private fun normalise(rec: Record): List<JSONObject> {
        val id = rec.metadata.id
        return when (rec) {
            is StepsRecord -> listOf(base(rec, id, "steps", "count").span(rec.startTime, rec.endTime, rec.count.toDouble()))
            is HeartRateRecord -> rec.samples.mapIndexed { i, s -> base(rec, "$id:$i", "heart_rate", "bpm").span(s.time, s.time, s.beatsPerMinute.toDouble()) }
            is SleepSessionRecord -> listOf(base(rec, id, "sleep", "min").span(rec.startTime, rec.endTime, minutes(rec.startTime, rec.endTime)))
            is ExerciseSessionRecord ->
                listOf(
                    base(rec, id, "exercise", "min")
                        .span(rec.startTime, rec.endTime, minutes(rec.startTime, rec.endTime))
                        .put("detail", rec.title ?: rec.exerciseType.toString()),
                )
            is WeightRecord -> listOf(base(rec, id, "weight", "kg").span(rec.time, rec.time, rec.weight.inKilograms))
            is ActiveCaloriesBurnedRecord -> listOf(base(rec, id, "active_calories", "kcal").span(rec.startTime, rec.endTime, rec.energy.inKilocalories))
            else -> emptyList()
        }
    }

    companion object {
        const val REQUEST = 42
        private const val PAGE = 2000
        private const val TAG = "PowosHealth"
    }
}

package com.blainemiller.blip.core

import org.json.JSONArray
import org.json.JSONObject

// Typed views of the JSON the native core returns. Field names follow blip-core's serde names
// (snake_case) for results it persists, and the bridge's camelCase for live state.

private fun JSONObject.optDoubleOrNull(key: String): Double? =
    if (isNull(key) || !has(key)) null else optDouble(key).takeIf { !it.isNaN() }

private fun JSONObject.optStringOrNull(key: String): String? =
    if (isNull(key) || !has(key)) null else optString(key)

private fun JSONArray?.doubles(): List<Double> =
    if (this == null) emptyList() else List(length()) { optDouble(it) }

private inline fun <T> JSONArray?.mapObjects(f: (JSONObject) -> T): List<T> =
    if (this == null) emptyList() else List(length()) { f(getJSONObject(it)) }

data class Category(val name: String, val score: Double)

data class BenchResult(
    val date: Long,
    val profile: String,
    val composite: Double,
    val singleCore: Category,
    val multiCore: Category,
    val memory: Category,
    val gpu: Category?,
    val throttleFactor: Double?,
    val deviceModel: String,
) {
    val throttlePercentLost: Int? get() = throttleFactor?.let { ((1 - it) * 100).toInt().coerceAtLeast(0) }

    companion object {
        private fun cat(o: JSONObject?) = o?.let { Category(it.optString("name"), it.optDouble("score")) }
        fun parse(o: JSONObject) = BenchResult(
            date = o.optLong("date"),
            profile = o.optString("profile"),
            composite = o.optDouble("composite"),
            singleCore = cat(o.optJSONObject("single_core"))!!,
            multiCore = cat(o.optJSONObject("multi_core"))!!,
            memory = cat(o.optJSONObject("memory"))!!,
            gpu = cat(o.optJSONObject("gpu")),
            throttleFactor = o.optDoubleOrNull("throttle_factor"),
            deviceModel = o.optString("device_model"),
        )
    }
}

data class Leg(val id: String, val name: String, val score: Double)

data class BenchState(
    val running: Boolean = false,
    val phase: String = "idle",
    val phaseLabel: String = "",
    val progress: Double = 0.0,
    val legs: List<Leg> = emptyList(),
    val last: BenchResult? = null,
    val history: List<BenchResult> = emptyList(),
    val best: Double? = null,
) {
    companion object {
        fun parse(text: String): BenchState {
            val o = JSONObject(text)
            return BenchState(
                running = o.optBoolean("running"),
                phase = o.optString("phase"),
                phaseLabel = o.optString("phaseLabel"),
                progress = o.optDouble("progress", 0.0),
                legs = o.optJSONArray("legs").mapObjects { Leg(it.optString("id"), it.optString("name"), it.optDouble("score")) },
                last = o.optJSONObject("last")?.let(BenchResult::parse),
                history = o.optJSONArray("history").mapObjects(BenchResult::parse),
                best = o.optDoubleOrNull("best"),
            )
        }
    }
}

data class SpeedResult(
    val downMbps: Double,
    val upMbps: Double?,
    val timestamp: Long,
    val pingMs: Double?,
    val loadedPingMs: Double?,
    val server: String,
) {
    companion object {
        fun parse(o: JSONObject) = SpeedResult(
            downMbps = o.optDouble("down_mbps"),
            upMbps = o.optDoubleOrNull("up_mbps"),
            timestamp = o.optLong("timestamp"),
            pingMs = o.optDoubleOrNull("ping_ms"),
            loadedPingMs = o.optDoubleOrNull("loaded_ping_ms"),
            server = o.optString("server"),
        )
    }
}

data class SpeedState(
    val phase: String = "idle",
    val error: String? = null,
    val running: Boolean = false,
    val liveMbps: Double = 0.0,
    val down: List<Double> = emptyList(),
    val up: List<Double> = emptyList(),
    val last: SpeedResult? = null,
    val history: List<SpeedResult> = emptyList(),
) {
    companion object {
        fun parse(text: String): SpeedState {
            val o = JSONObject(text)
            return SpeedState(
                phase = o.optString("phase"),
                error = o.optStringOrNull("error"),
                running = o.optBoolean("running"),
                liveMbps = o.optDouble("liveMbps", 0.0),
                down = o.optJSONArray("down").doubles(),
                up = o.optJSONArray("up").doubles(),
                last = o.optJSONObject("last")?.let(SpeedResult::parse),
                history = o.optJSONArray("history").mapObjects(SpeedResult::parse),
            )
        }
    }
}

data class DiskResult(val writeMbps: Double, val readMbps: Double, val iops: Double?, val timestamp: Long, val target: String, val sizeMb: Int) {
    companion object {
        fun parse(o: JSONObject) = DiskResult(
            o.optDouble("write_mbps"), o.optDouble("read_mbps"), o.optDoubleOrNull("random_read_iops"),
            o.optLong("timestamp"), o.optString("target"), o.optInt("size_mb"),
        )
    }
}

data class DiskState(
    val running: Boolean = false,
    val phase: String = "idle",
    val progress: Double = 0.0,
    val last: DiskResult? = null,
    val history: List<DiskResult> = emptyList(),
    val error: String? = null,
    val target: String = "",
) {
    companion object {
        fun parse(text: String): DiskState {
            val o = JSONObject(text)
            return DiskState(
                running = o.optBoolean("running"),
                phase = o.optString("phase"),
                progress = o.optDouble("progress", 0.0),
                last = o.optJSONObject("last")?.let(DiskResult::parse),
                history = o.optJSONArray("history").mapObjects(DiskResult::parse),
                error = o.optStringOrNull("error"),
                target = o.optString("target"),
            )
        }
    }
}

data class Geo(val lat: Double, val lon: Double, val city: String?, val country: String?) {
    val place: String? get() = listOfNotNull(city, country).joinToString(", ").ifEmpty { null }
}

data class Hop(
    val hop: Int,
    val host: String,
    val sent: Int,
    val recv: Int,
    val loss: Double,
    val last: Double?,
    val avg: Double?,
    val best: Double?,
    val worst: Double?,
    val geo: Geo?,
)

data class TraceState(
    val host: String = "",
    val running: Boolean = false,
    val passes: Int = 0,
    val error: String? = null,
    val hops: List<Hop> = emptyList(),
) {
    companion object {
        fun parse(text: String): TraceState {
            val o = JSONObject(text)
            return TraceState(
                host = o.optString("host"),
                running = o.optBoolean("running"),
                passes = o.optInt("passes"),
                error = o.optStringOrNull("error"),
                hops = o.optJSONArray("hops").mapObjects { h ->
                    Hop(
                        hop = h.optInt("hop"),
                        host = h.optString("host"),
                        sent = h.optInt("sent"),
                        recv = h.optInt("recv"),
                        loss = h.optDouble("loss", 0.0),
                        last = h.optDoubleOrNull("last"),
                        avg = h.optDoubleOrNull("avg"),
                        best = h.optDoubleOrNull("best"),
                        worst = h.optDoubleOrNull("worst"),
                        geo = h.optJSONObject("geo")?.let {
                            Geo(it.optDouble("lat"), it.optDouble("lon"), it.optStringOrNull("city"), it.optStringOrNull("country"))
                        },
                    )
                },
            )
        }
    }
}

data class GeoStatus(val state: String, val progress: Double = 0.0, val built: Long = 0, val error: String? = null) {
    companion object {
        fun parse(text: String): GeoStatus {
            val o = JSONObject(text)
            return GeoStatus(o.optString("state"), o.optDouble("progress", 0.0), o.optLong("built"), o.optStringOrNull("error"))
        }
    }
}
